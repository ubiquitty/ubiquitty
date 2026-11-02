<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Swift ↔ C++ interop — recipes

Portable behavior belongs in C++ Core; the Apple frontend calls it through
Swift interoperability. `-cxx-interoperability-mode=default` is enabled for the
target, so a Swift file imports a Core header as a Clang module and uses its
C++ types directly. Do not add an Objective-C++ facade merely to flatten those
types into scalars.

Configuration changes must use the configuration owner, which persists the
choice and applies it to affected sessions. Direct access to an imported value
does not replace that transaction; see [the configuration contract](configuration-seam.md).

The command-palette adapter is a working example in
`Source/Platform/macOS/App/Beam/PaletteBridge.swift` and
`Source/Platform/macOS/App/CxxInterop.swift`.

## Exposing a Core header to Swift

Add a Clang module to `Source/Platform/Apple/module.modulemap`, one per
logical surface (paths are relative to the modulemap):

```
module UbiquittyCommandPalette {
    header "../../../Core/CommandPalette/PaletteScope.h"
    header "../../../Core/CommandPalette/PaletteEngine.h"
    // …all headers the Swift call sites touch…
    requires cplusplus
    export *
}
```

Then `import UbiquittyCommandPalette` (plus `import CxxStdlib` for `std.*`) in
the Swift file. A header that transitively pulls in `Preferences/Preferences.h` imports
fine — don't pre-emptively narrow the surface.

## The type map (what interop gives you)

| C++ | Swift | Notes |
|---|---|---|
| `enum class E : uint8_t` | `E` — a Swift enum, **NON-frozen by default** | Cases keep their C++ names (`.Actions`, not `.actions`). A bare scoped enum imports non-frozen, so an exhaustive `switch` **requires `@unknown default`** — a **hard error in the Swift 6 language mode**. To import it FROZEN (exhaustive `switch`, no `@unknown default`), tag it `UBIQUITTY_CLOSED_ENUM` (see the row below). |
| `enum class UBIQUITTY_CLOSED_ENUM E : uint8_t` | `E` — a **`@frozen`** Swift enum | The annotation you almost always want: our enums are fixed closed sets. Frozen ⇒ an exhaustive `switch` needs **no `@unknown default`**. **Use the `UBIQUITTY_CLOSED_ENUM` macro** (defined in `Base/Compiler.h`), placed between `enum class` and the name — **never the raw `[[clang::enum_extensibility(closed)]]`**: that attribute is clang-only and trips `-Werror=attributes` on the GCC (Linux) build. The macro guards it via `__has_cpp_attribute` and expands to nothing off clang. Verified vs `swiftlang/swift` `HowSwiftImportsCAPIs`: for a C++ `enum class`, `enum_extensibility(closed)` ⇒ `@frozen`, unmarked ⇒ non-frozen (always requires `@unknown default`). This C++-interop rule is distinct from the C-enum mapping in that doc, where an *unmarked C enum* instead imports as a **struct** (not a non-frozen Swift enum). |
| free / static fn | `Namespace.fn(...)` / `Type.fn(...)` | `Ubiquitty.CommandPalette.Engine.interpretInput(...)` |
| `T&` return (e.g. `Preferences::values()`) | `UnsafeMutablePointer<T>` | read through `.pointee` — a **last resort**, see below; fine for a singleton handle, wrong for element access |
| `const char*` out | `UnsafePointer<CChar>?` | **optional** — unwrap; `String(cString:)` |
| a value `struct` | a Swift value type | build with `var x = T(); x.field = …` |
| a class with `std::vector`/`std::string` members | a Swift value type you can hold as a stored `var` and call mutating methods on | Swift manages copy/move/destroy. For a single owner, consider importing it `~Copyable` to forbid a silent deep-copy. |

## Prefer value types and collections — never expose `.pointee` for element access

The `T&`-return → `.pointee` row above is a **last resort**, not a pattern to
copy. A trivially-copyable C++ `struct` already imports as a Swift **value type**
(Swift uses its copy constructor / destructor), so the fix for a `.pointee` at a
call site is almost always to change the C++ API shape, not to reach for the
pointer:

- **Return by value.** `const Match* matchAt(int)` imports as
  `UnsafePointer<Match>?`, forcing `m.pointee.field`. Return `Match` **by value**
  → Swift gets `Match?` and reads `m.field`. `SWIFT_RETURNS_INDEPENDENT_VALUE`
  marks a member whose returned value has no borrowed lifetime, so Swift treats
  it as safe rather than importing it `Unsafe`-suffixed.
- **Expose a collection, not index + accessor.** A C++ container with
  random-access iterators (or a `std::span`) **auto-conforms** to Swift
  `RandomAccessCollection` / `CxxConvertibleToCollection` — no macro needed. Swift
  writes `for match in scrollSearch.matches(term) { … match.absoluteRow … }`
  instead of a `searchAll` + `matchAt(i)` + `.pointee` index dance.

A raw pointer + `.pointee` for **element access** does not pass conventions review
in a new seam — reshape the C++ API. (`Preferences::values()` returning `T&` for a
mutable singleton handle is the one tolerated pointer case: a handle, not
iteration.)

## Annotating a C++ type for Swift — `#include <swift/bridging>`

For control over how a type crosses the boundary, annotate it in the Core header
(authoritative catalog: swift.org ▸ *Mixing Swift and C++*). These are additive
in C++ (they compile to nothing without the Swift compiler):

| Goal | Annotation |
|---|---|
| Refcounted class → Swift `class` under ARC | `SWIFT_SHARED_REFERENCE(retain, release)` |
| Immortal / never-freed handle → unmanaged `class` | `SWIFT_IMMORTAL_REFERENCE` |
| Non-view value type — its returns are assumed safe | `SWIFT_SELF_CONTAINED` |
| Import a copyable C++ type as `~Copyable` (single owner) | `SWIFT_NONCOPYABLE` |
| Rename in Swift | `SWIFT_NAME("newName(_:)")` |
| Getter/setter pair → a computed property | `SWIFT_COMPUTED_PROPERTY` |
| `const` method that mutates → `mutating` | `SWIFT_MUTATING` |
| Member returns an independent (non-borrowed) value | `SWIFT_RETURNS_INDEPENDENT_VALUE` |

**Lifetime-bounded views** — a type with a pointer/length whose validity depends
on another object (a `string_view`/`span`-shaped field) — must be marked, or the
compiler will not synthesise the safe overload:

- `struct SWIFT_NONESCAPABLE Ref { const char* p; size_t n; };` — has a borrowed
  lifetime. `SWIFT_ESCAPABLE` is the opposite (self-owned, safe);
  `SWIFT_ESCAPABLE_IF(T)` for templates.
- `T fn(const std::string& s [[clang::lifetimebound]])` — the return borrows `s`.
- `int sum(const int* v __counted_by(len) __noescape, int len)` → Swift gets a
  safe `sum(_ v: Span<Int32>)` overload instead of an unsafe pointer.

Prefer a **self-contained value type** (no borrowed pointers) so none of the
lifetime machinery is needed; reach for these only when a view genuinely must
cross the boundary. Existing raw-pointer loops are not a model for new APIs.

## The two friction points, and the fixes

**1. `std::string_view` parameters.** Swift `String` bridges to `std::string`,
**not** `std::string_view`. Don't reach for `__c_strUnsafe()`. Use a scoped
`withCString` — a `CxxInterop.swift` extension makes it clean:

```swift
extension String {
    @inline(__always)
    func withCxxStringView<R>(_ body: (std.string_view) -> R) -> R {
        withCString { body(std.string_view($0)) }   // NUL-terminated UTF-8; outlives the call
    }
    var cxxString: std.string { std.string(self) }
}
// call site:
query.withCxxStringView { view in engine.rankedResults(view) }
```

Never let the `string_view` escape the closure — the backing buffer is only
valid inside it.

**2. `std::vector<T>` / `std::unordered_map<K,V>` can't be spelled bare.** Swift
can't name `std.vector<T>` (it wants the allocator param too). Add a **named
typealias in the Core header** (harmless in C++, Apple's recommended pattern):

```cpp
using PaletteCommandList = std::vector<PaletteCommand>;   // in PaletteCommand.h
using UsageScoreMap = std::unordered_map<std::string, double>;
```

Then `var list = CP.PaletteCommandList(); list.reserve(n); list.push_back(x)`
and `map[key.cxxString] = value` work from Swift.

**Reading `std::string` back:** `String(cxxString)` — but the `for x in vec`
element type doesn't always infer, so annotate: `let s: std.string = elem.field`.

## The layering rule

### Owned callbacks on Swift 6.3

Core callback APIs take an owned `std::function`, rather than a borrowed
`void*` context and a C function pointer. The Apple adapter
`Platform/Apple/OwnedCallback.h` converts a Swift closure to that type using
an ARC-owned block capture. The Core does not depend on blocks or ARC.

```swift
client.setChangeCallback(Ubiquitty.Apple.ownedCallback { [weak self] in
    MainActor.assumeIsolated { self?.refreshFromCore() }
})
```

The actor check is valid only when the Core owner guarantees delivery through
the main-loop dispatcher. A callback with a different executor must explicitly
hop to the correct actor. Use weak captures when the Swift object owns the Core
client, preventing a retain cycle. Replacing the callback or destroying its final
C++ owner releases its captures.

The installed Swift 6.3 compiler type-checks direct captured-closure construction
of `std::function`, but rejects it during code generation. Verify interop changes
with a compiled and executed lifetime test, not type checking alone. Never erase
a pointer into an integer to bypass Swift's concurrency diagnostics.

Put **all** `std.*` bridging in one Swift adapter per seam (e.g.
`PaletteBridge.swift`): it exposes Swift-native types (`String`, `[T]`,
`IndexSet`) so the rest of the frontend never touches `std.string` /
`.withCxxStringView`. The adapter is the seam; the callers stay clean Swift.
The command-palette effect closures stay on the Swift side; Core returns effect
identifiers. Event subscriptions use the owned callback contract above.

## Checklist for the next seam

1. Modulemap module for the Core headers; `import` it + `CxxStdlib`.
2. Named typealiases in Core for every `std::vector`/`std::unordered_map` the
   Swift API touches.
3. One `*Bridge.swift` adapter: Swift-native in/out, `std.*` only inside.
4. `UBIQUITTY_CLOSED_ENUM` C++ enums replace `NS_ENUM` mirrors — delete the
   mirror and the `@unknown default`s. The macro is REQUIRED: a bare scoped enum
   imports non-frozen and re-introduces the `@unknown default` requirement (a
   hard error under the Swift 6 language mode). Use the macro (from
   `Base/Compiler.h`), never the raw `[[clang::enum_extensibility(closed)]]`
   (clang-only → `-Werror=attributes` on GCC).
5. Full suite (interop mode is target-wide — a change here can touch every
   Swift↔C++ consumer) + perflog any hot boundary.
