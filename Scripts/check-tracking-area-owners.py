#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold every tracking area's owner to a type that answers AppKit's rollover.

An NSTrackingArea names an owner, and AppKit sends that owner the callbacks the
area's options imply -- `mouseEntered:` for `.mouseEnteredAndExited`,
`cursorUpdate:` for `.cursorUpdate`. The send is dynamic and guarded: an owner
that does not answer the selector is skipped, in silence, with no exception and
nothing in any log.

## The failure this exists for

Swift decides on its own whether a method gets an Objective-C selector at all.
A plain NSObject spelling

    func mouseEntered(with event: NSEvent) { ... }

compiles clean, reads exactly like a working callback, and answers no selector,
so the pointer is never heard from. Marking it `@objc` does not fix it either --
Swift then mints `mouseEnteredWith:`, which AppKit does not send. Only
`@objc(mouseEntered:)`, or an `override` on a type that already inherits the
selector, produces the name AppKit looks for.

That is a defect no reviewer catches by reading, because the reading is correct;
only the runtime disagrees, and it disagrees quietly. A hover lifecycle written
on a plain NSObject never fires, and what the user sees is not "the hover is
broken" but an empty gap where an icon should be.

## The rule

For every NSTrackingArea built in Swift, the owner's type must inherit from
NSResponder -- the class that declares these callbacks -- and must carry, as
`override`, every callback its own options ask for. `override` is the part that
cannot rot: a misspelling stops being a silent no-op and becomes a build error,
and the inherited selector is emitted whether or not anyone remembers why.

`@objc(mouseEntered:)` on a non-responder is accepted too, because it produces
the same selector; the risk is that the selector name is handwritten, so a
misspelling compiles and the owner goes quiet.

## The bounds

    an owner that is not an NSResponder      -> FAIL, its selectors are Swift's
                                                to withhold
    an option with no matching override      -> FAIL, that callback is skipped
    an owner whose type cannot be resolved   -> FAIL, an unreadable owner is not
                                                a checked one
    no tracking area found in the tree       -> REFUSE, a clean verdict would
                                                belong to the search

Stdlib only.

    python3 Scripts/check-tracking-area-owners.py
    python3 Scripts/check-tracking-area-owners.py --self-test
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate_report  # noqa: E402

GATE = "check-tracking-area-owners"

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "Source"

# The AppKit classes that already inherit the rollover callbacks. A local type
# deriving from any of them is a responder; a local type deriving from another
# local type is resolved one link at a time until it reaches this set or runs
# out, which is what makes an unresolvable base a finding rather than a pass.
APPKIT_RESPONDERS = {
    "NSResponder", "NSView", "NSWindow", "NSViewController", "NSWindowController",
    "NSApplication", "NSScrollView", "NSClipView", "NSControl", "NSButton",
    "NSTextField", "NSTextView", "NSTableView", "NSOutlineView", "NSStackView",
    "NSBox", "NSSplitView", "NSVisualEffectView", "NSCollectionView", "NSImageView",
    "NSSlider", "NSPopUpButton", "NSSegmentedControl", "NSSearchField", "NSTabView",
    "NSOpenGLView", "MTKView", "NSHostingView",
}

# Which callback each tracking option makes AppKit send. Keyed on the option as
# it is spelled at the call site, valued by (Swift method name, ObjC selector).
OPTION_CALLBACKS = {
    "mouseEnteredAndExited": [("mouseEntered", "mouseEntered:"),
                              ("mouseExited", "mouseExited:")],
    "mouseMoved": [("mouseMoved", "mouseMoved:")],
    "cursorUpdate": [("cursorUpdate", "cursorUpdate:")],
}


class TypeDeclaration:
    """One Swift type declaration and the text of its body."""

    def __init__(self, name, bases, body):
        self.name = name
        self.bases = bases
        self.body = body

    def declares(self, method, selector):
        """Whether this type carries a callback AppKit can actually reach.

        Two spellings qualify: an `override`, which inherits the selector and
        cannot be misspelled without failing the build, and an explicit
        `@objc(selector)`, which states the exact name by hand.

        - Parameters:
          - method: the Swift method name, e.g. `mouseEntered`.
          - selector: the Objective-C selector AppKit sends, e.g. `mouseEntered:`.
        - Returns: True when the type answers that selector.
        """
        # Modifiers may sit on either side of `override` — `override public
        # func` and `public override func` are both ordinary Swift, and a
        # pattern demanding `override func` adjacently reports a handler that
        # is right there as missing.
        if re.search(rf"\boverride\b(?:\s+\w+)*\s+func\s+{method}\s*\(", self.body):
            return True
        pattern = rf"@objc\(\s*{re.escape(selector)}\s*\)[\s\S]{{0,200}}?\bfunc\s+{method}\s*\("
        return re.search(pattern, self.body) is not None


class Site:
    """One NSTrackingArea construction and everything judged about it."""

    def __init__(self, path, line, options, owner, ownerType, declarations):
        self.path = path
        self.line = line
        self.options = options
        self.owner = owner
        self.ownerType = ownerType
        self.declarations = declarations

    @property
    def location(self):
        return f"{self.path}:{self.line}"


def stripped(text):
    """Returns Swift source with line comments and string bodies blanked.

    Braces and colons inside a comment or a literal would otherwise be read as
    structure. Lengths are preserved so offsets still address the original.

    - Parameter text: the file's contents.
    - Returns: the same text with those spans replaced by spaces.
    """
    out = list(text)
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = length if end < 0 else end
            for position in range(index, end):
                out[position] = " "
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end < 0 else end + 2
            for position in range(index, end):
                if out[position] != "\n":
                    out[position] = " "
            index = end
        elif text[index] == '"':
            index += 1
            while index < length and text[index] != '"':
                if text[index] == "\\":
                    out[index] = " "
                    index += 1
                if index < length:
                    if out[index] != "\n":
                        out[index] = " "
                    index += 1
            if index < length:
                out[index] = " "
                index += 1
        else:
            index += 1
    return "".join(out)


DECLARATION = re.compile(
    r"\b(?:final\s+|public\s+|private\s+|fileprivate\s+|internal\s+|package\s+|open\s+|@\w+(?:\([^)]*\))?\s+)*"
    r"(class|extension)\s+(\w+)\s*(?::\s*([^{]+?))?\s*\{"
)


def declarationsIn(text):
    """Returns every type declaration in a file, keyed by name.

    Bodies are matched by brace depth over comment- and literal-blanked source,
    so a nested type does not end its parent and an `extension` merges into the
    type it extends -- a callback declared in an extension is still the type's.

    - Parameter text: the file's contents.
    - Returns: a dict of name -> TypeDeclaration.
    """
    blank = stripped(text)
    found = {}
    for match in DECLARATION.finditer(blank):
        kind, name, bases = match.group(1), match.group(2), match.group(3) or ""
        depth = 0
        end = len(blank)
        for position in range(match.end() - 1, len(blank)):
            if blank[position] == "{":
                depth += 1
            elif blank[position] == "}":
                depth -= 1
                if depth == 0:
                    end = position
                    break
        body = text[match.end():end]
        baseNames = [part.strip() for part in bases.split(",") if part.strip()]
        if name in found:
            found[name].body += "\n" + body
            if kind == "class":
                found[name].bases = baseNames or found[name].bases
        else:
            found[name] = TypeDeclaration(name, baseNames if kind == "class" else [], body)
    return found


def enclosingTypeName(text, offset):
    """Returns the innermost type declaration containing an offset.

    - Parameters:
      - text: the file's contents.
      - offset: a character offset into it.
    - Returns: the type's name, or None when the offset sits at file scope.
    """
    blank = stripped(text)
    best = None
    for match in DECLARATION.finditer(blank):
        if match.end() > offset:
            break
        depth = 0
        end = len(blank)
        for position in range(match.end() - 1, len(blank)):
            if blank[position] == "{":
                depth += 1
            elif blank[position] == "}":
                depth -= 1
                if depth == 0:
                    end = position
                    break
        if match.end() <= offset < end:
            best = match.group(2)
    return best


PROPERTY = re.compile(
    r"\b(?:let|var)\s+(\w+)\s*(?::\s*([\w.]+)|=\s*([\w.]+)\s*\()"
)


def ownerTypeName(text, owner, offset):
    """Resolves the owner expression at a call site to a type name.

    `self` resolves to the enclosing type; a bare identifier resolves through a
    stored property's declared or inferred type. Anything else is unresolved,
    which this gate reports rather than passes.

    - Parameters:
      - text: the file's contents.
      - owner: the owner argument as written.
      - offset: the call site's offset, for the `self` case.
    - Returns: a type name, or None.
    """
    owner = owner.strip()
    if owner == "self":
        return enclosingTypeName(text, offset)
    if re.fullmatch(r"\w+", owner):
        for match in PROPERTY.finditer(stripped(text)):
            if match.group(1) == owner:
                return (match.group(2) or match.group(3) or "").split(".")[-1] or None
    return None


def isResponder(name, declarations, seen=None):
    """Whether a type inherits AppKit's rollover callbacks.

    Walks local superclasses until an AppKit responder is reached or the chain
    leaves the file, so a type deriving from a local view still counts.

    - Parameters:
      - name: the type's name.
      - declarations: the file's declarations, by name.
      - seen: cycle guard.
    - Returns: True when the chain reaches a known responder.
    """
    seen = seen or set()
    if not name or name in seen:
        return False
    if name in APPKIT_RESPONDERS:
        return True
    seen.add(name)
    # A base can be a typealias for a responder, and the alias is declared in
    # another file — resolve it before giving up on the chain.
    alias = ALIASES.get(name)
    if alias and isResponder(alias, declarations, seen):
        return True
    declaration = declarations.get(name)
    localBases = declaration.bases if declaration else []
    # An extension declares none, and the file holding the construction is
    # usually an extension: fall back to wherever the type was declared.
    for base in localBases or DECLARED_BASES.get(name, []):
        if isResponder(base, declarations, seen):
            return True
    return False


CONSTRUCTION = re.compile(r"\bNSTrackingArea\s*\(")


def sitesIn(path, text):
    """Returns every NSTrackingArea construction in one file.

    - Parameters:
      - path: the repository-relative path, for reporting.
      - text: the file's contents.
    - Returns: a list of Site.
    """
    blank = stripped(text)
    declarations = declarationsIn(text)
    sites = []
    for match in CONSTRUCTION.finditer(blank):
        depth = 0
        end = len(blank)
        for position in range(match.end() - 1, len(blank)):
            if blank[position] == "(":
                depth += 1
            elif blank[position] == ")":
                depth -= 1
                if depth == 0:
                    end = position
                    break
        arguments = text[match.end():end]
        options = set(re.findall(r"\.(\w+)", re.search(r"options\s*:\s*\[([^\]]*)\]",
                                                       arguments).group(1))
                      if re.search(r"options\s*:\s*\[([^\]]*)\]", arguments) else [])
        ownerMatch = re.search(r"owner\s*:\s*([^,\n)]+)", arguments)
        owner = ownerMatch.group(1).strip() if ownerMatch else ""
        sites.append(Site(path, text[:match.start()].count("\n") + 1, options, owner,
                          ownerTypeName(text, owner, match.start()), declarations))
    return sites


def judge(sites):
    """Compares each site against the rule.

    - Parameter sites: the constructions measured from the tree.
    - Returns: a list of (location, message), empty when every owner answers.
    """
    findings = []
    for site in sites:
        if not site.ownerType:
            findings.append((site.location,
                             f"the tracking area's owner `{site.owner}` resolves to no "
                             "type here — an owner whose type cannot be read is an owner "
                             "whose callbacks cannot be checked, and AppKit skips the "
                             "ones that are missing without a word"))
            continue
        declaration = site.declarations.get(site.ownerType)
        if not declaration:
            findings.append((site.location,
                             f"`{site.ownerType}` owns a tracking area and is declared "
                             "outside this file — the callbacks it does or does not "
                             "answer cannot be read from here. Own the area from a type "
                             "declared alongside it"))
            continue
        # Whether the owner is a responder decides which spelling is even
        # available, but not whether the callback is present: an @objc selector
        # names the same method AppKit sends to. So the miss is measured first
        # and the inheritance only chooses how to say what is wrong.
        missing = [(option, method, selector)
                   for option in sorted(site.options)
                   for method, selector in OPTION_CALLBACKS.get(option, [])
                   if not declaration.declares(method, selector)]
        if not missing:
            continue
        if not isResponder(site.ownerType, site.declarations):
            names = ", ".join(f"`{selector}`" for _, _, selector in missing)
            findings.append((site.location,
                             f"`{site.ownerType}` owns a tracking area, does not inherit "
                             f"NSResponder, and answers neither {names} — Swift emits no "
                             "selector for a method it was not told to, so AppKit skips "
                             "this owner in silence. Derive it from NSResponder and mark "
                             "the callbacks `override`, or spell the selectors out with "
                             "`@objc(mouseEntered:)`"))
            continue
        for option, method, selector in missing:
            findings.append((site.location,
                             f"the area asks for .{option} and `{site.ownerType}` "
                             f"has no `override func {method}` — AppKit sends "
                             f"`{selector}` to an owner that does not answer it, "
                             "and nothing reports the miss"))
    return findings


TYPEALIAS = re.compile(r"^\s*(?:public\s+|package\s+|internal\s+)?typealias\s+(\w+)\s*=\s*([\w.]+)", re.M)


def platformAliases():
    """Returns every Swift typealias under Source/, keyed by the alias.

    Collected across the whole source set rather than per file, because the
    alias that matters here is declared in one file and used in another: a view
    written once for both platforms derives from `PlatformView`, and the class
    that name stands for is `NSView` in a file the owner's own does not include.
    Resolved per file, such a base leaves the chain and the owner reads as no
    responder at all — which is a finding against a view AppKit will happily
    send to.

    Ambiguity is refused rather than guessed: an alias declared twice with
    different right-hand sides — which is exactly how a cross-platform alias is
    written, `NSView` under one `#if` and `UIView` under the other — resolves to
    the AppKit spelling when one of them is a known responder, since this gate
    only reasons about AppKit delivery.

    - Returns: a dict of alias -> underlying type name.
    """
    aliases = {}
    for path in sorted(SOURCE.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for name, target in TYPEALIAS.findall(stripped(text)):
            target = target.split(".")[-1]
            if name in aliases and aliases[name] != target:
                # Keep whichever side this gate can reason about.
                if aliases[name] in APPKIT_RESPONDERS:
                    continue
            aliases[name] = target
    return aliases


def declaredBases():
    """Returns every Swift type's declared bases, keyed by name, across Source/.

    A tracking area is usually built in an EXTENSION, and an extension declares
    no bases — so the file holding the construction says nothing about what the
    owner derives from, and the chain ends before it starts. The class itself is
    in another file. Collected once so the owner can be resolved from wherever
    it was actually declared.

    Only non-empty base lists are kept, so an extension never masks the
    declaration it extends whichever order the files are read in.

    - Returns: a dict of type name -> list of base names.
    """
    bases = {}
    for path in sorted(SOURCE.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for name, declaration in declarationsIn(text).items():
            if declaration.bases:
                bases.setdefault(name, declaration.bases)
    return bases


def swiftSites():
    """Returns every NSTrackingArea construction under Source/.

    - Returns: a list of Site.
    """
    sites = []
    for path in sorted(SOURCE.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if "NSTrackingArea" not in text:
            continue
        sites.extend(sitesIn(str(path.relative_to(REPO)), text))
    return sites


# The shape that shipped: a plain NSObject spelling the callbacks with no
# selector. Held here as source so the self-test proves the gate fires on the
# real defect rather than on a description of it.
SILENT_OWNER = """
final class QuietOwner: NSObject {
    private var trackingArea: NSTrackingArea?
    func install(on strip: NSView) {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        strip.addTrackingArea(area)
    }
    func mouseEntered(with event: NSEvent) {}
    func mouseExited(with event: NSEvent) {}
}
"""

SOUND_OWNER = """
private final class LoudOwner: NSResponder {
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
}
final class Host: NSObject {
    private let hoverOwner = LoudOwner()
    func install(on strip: NSView) {
        strip.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: hoverOwner,
            userInfo: nil
        ))
    }
}
"""

HALF_OWNER = """
final class HalfView: NSView {
    override func updateTrackingAreas() {
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
}
"""

NAMED_OWNER = """
final class NamedOwner: NSObject {
    func install(on strip: NSView) {
        strip.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited], owner: self, userInfo: nil))
    }
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {}
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {}
}
"""


def selfTest():
    ALIASES.update(platformAliases())
    DECLARED_BASES.update(declaredBases())
    """Proves each bound fires, and that the tree search is not the zero.

    - Returns: 0 when the gate behaves as stated, 1 otherwise.
    """
    failures = []

    if not judge(sitesIn("silent-fixture", SILENT_OWNER)):
        failures.append("a plain-NSObject owner — the shape that shipped — was not flagged")
    if judge(sitesIn("sound-fixture", SOUND_OWNER)):
        failures.append("an NSResponder owner overriding both callbacks was flagged")
    if not judge(sitesIn("half-fixture", HALF_OWNER)):
        failures.append("an option with no matching override was not flagged")
    if judge(sitesIn("named-fixture", NAMED_OWNER)):
        failures.append("an explicit @objc(mouseEntered:) owner was flagged")

    # The named-owner arm is only meaningful if the gate would otherwise object
    # to that type, so state the half of it that must fail.
    withoutSelectors = NAMED_OWNER.replace("@objc(mouseEntered:) ", "").replace(
        "@objc(mouseExited:) ", "")
    if not judge(sitesIn("stripped-fixture", withoutSelectors)):
        failures.append("the @objc arm passes for a reason other than its selectors")

    sites = swiftSites()
    if not sites:
        failures.append("no NSTrackingArea is built anywhere under Source/ — a clean "
                        "verdict here would be the search's and not the tree's")
    unresolved = [site for site in sites if not site.ownerType]
    if unresolved:
        failures.append(f"{len(unresolved)} tree site(s) resolve to no owner type, so the "
                        "resolver is not reading this tree")

    for failure in failures:
        print(f"{GATE} --self-test: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"{GATE} --self-test: ok (each bound fires, and the tree has {len(sites)} "
          "tracking area(s), every owner resolved — so a clean verdict is the tree's)")
    return 0


# Filled by `main` before any site is judged; empty in a unit context, where a
# test naming a real alias fills it itself.
ALIASES = {}
# Every type's bases, from wherever it was declared; see `declaredBases`.
DECLARED_BASES = {}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="prove each bound fires, and that the search is not the zero")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    ALIASES.update(platformAliases())
    DECLARED_BASES.update(declaredBases())
    sites = swiftSites()
    if not sites:
        print(f"{GATE}: REFUSED — no NSTrackingArea is built in any Swift file under "
              "Source/. A tree that stopped building them and a tree where every owner "
              "answers print the same verdict, so this is not a pass.", file=sys.stderr)
        return 2

    findings = judge(sites)
    if findings:
        gate_report.failed(GATE, "tracking area owner(s) AppKit would skip in silence",
                           [location for location, _ in findings])
        for location, message in findings:
            gate_report.finding(location, GATE, message)
        return 1

    owners = len({(site.path, site.ownerType) for site in sites})
    print(f"{GATE}: ok ({len(sites)} tracking area(s) across {owners} owner(s), each a "
          "responder answering every callback its options ask for)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
