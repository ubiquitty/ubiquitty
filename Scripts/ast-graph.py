#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""
Scripts/ast-graph.py — class/method graph + WebKit naming audit.

Usage:
    python3 Scripts/ast-graph.py [--dot]

Reads the macOS build's compile_commands.json, through the link
Scripts/build-macos.sh makes in the checkout's root or from the build root's
macos/ tree, parses every source file under Source/Platform/macOS/ with
libclang, and emits:

  1. A structured class/method/property listing.
  2. Naming-convention violations (WebKit style: lowerCamelCase methods,
     is*/has*/needs* booleans, m_ ivars, UB prefix for ObjC classes, etc.)
  3. With --dot: a DOT graph of class hierarchy + protocol conformances
     (pipe to `dot -Tsvg -o graph.svg`).
"""

import sys
import json
import re
import os
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_root

try:
    import clang.cindex as cx
except ImportError:
    sys.exit("libclang not found — run: pip3 install libclang")

ROOT = Path(__file__).resolve().parent.parent
# The build writes the database under the build root, outside the checkout.
BUILD_DBS = (ROOT / "compile_commands.json",
             Path(build_root.build_root(str(ROOT))) / "macos" / "compile_commands.json")
PLATFORM_DIR = ROOT / "Source" / "Platform" / "macOS"

# ── Naming rules ──────────────────────────────────────────────────────────────

# ObjC class names must be UpperCamelCase; macOS-frontend classes carry UB prefix.
RE_CLASS_UB   = re.compile(r'^UB[A-Z][A-Za-z0-9]*$')
RE_CLASS_UPPER = re.compile(r'^[A-Z][A-Za-z0-9]*$')

# Methods must be lowerCamelCase (first segment all-lower is fine: "init", "dealloc").
RE_METHOD_LC  = re.compile(r'^[a-z_][A-Za-z0-9_:]*$')

# Boolean methods/properties must start with is/has/needs/can/should/accepts/validates.
BOOL_PREFIXES = ('is', 'has', 'needs', 'can', 'should', 'accepts', 'validates')

# C++ member variables must use m_ prefix.
RE_IVAR_M = re.compile(r'^m_[a-zA-Z]')
# ObjC auto-synth ivars carry _ prefix (fine).
RE_IVAR_UNDER = re.compile(r'^_[a-zA-Z]')

# File-scope C++ constants: kLowerCamelCase.
RE_CONST_K = re.compile(r'^k[A-Z][A-Za-z0-9]*$')

def check_method_name(name: str, returns_bool: bool) -> list[str]:
    issues = []
    bare = name.rstrip(':').split(':')[0]  # first selector segment
    if not RE_METHOD_LC.match(bare):
        issues.append(f"method '{name}': not lowerCamelCase")
    if returns_bool:
        if not any(bare.startswith(p) for p in BOOL_PREFIXES):
            issues.append(f"method '{name}': returns BOOL but missing is/has/needs/can/should prefix")
    return issues

def check_property_name(name: str, type_spelling: str) -> list[str]:
    issues = []
    # libclang resolves BOOL to its underlying C type; catch both.
    is_bool_type = type_spelling in ('BOOL', '_Bool', 'bool', 'signed char')
    if is_bool_type:
        if not any(name.startswith(p) for p in BOOL_PREFIXES):
            issues.append(f"property '{name}': BOOL type but missing is/has/needs/can/should prefix")
    return issues

def check_ivar_name(name: str, lang: str) -> list[str]:
    issues = []
    if lang == 'cpp':
        if not (RE_IVAR_M.match(name) or name.startswith('_')):
            issues.append(f"field '{name}': C++ member should use m_ prefix")
    else:
        if not (RE_IVAR_UNDER.match(name) or RE_IVAR_M.match(name)):
            issues.append(f"ivar '{name}': ObjC ivar should use _ or m_ prefix")
    return issues

# ── compile_commands index ────────────────────────────────────────────────────

def load_flags(db_path: Path) -> dict[str, list[str]]:
    """Map file path → compiler flags (without the compiler itself and -o/-c)."""
    with open(db_path) as f:
        db = json.load(f)
    skip = {'-o', '-c', '-MF', '-MT', '-MQ'}
    result = {}
    for entry in db:
        args = entry.get('arguments') or entry.get('command', '').split()
        clean = []
        i = 1  # skip compiler binary
        while i < len(args):
            a = args[i]
            if a in skip:
                i += 2
                continue
            if a.startswith('-o') or a.startswith('-MF') or a.startswith('-MT'):
                i += 1 if len(a) > 2 else 2
                continue
            clean.append(a)
            i += 1
        result[entry['file']] = clean
    return result

# ── AST traversal ─────────────────────────────────────────────────────────────

class ClassInfo:
    def __init__(self, name, kind, location):
        self.name = name
        self.kind = kind          # 'objc_interface', 'objc_category', 'cpp_class', 'objc_protocol'
        self.location = location
        self.superclass = None
        self.protocols = []
        self.methods = []         # list of (selector, is_class_method, returns_bool, location)
        self.properties = []      # list of (name, type_str, location)
        self.ivars = []           # list of (name, type_str, location)
        self.issues = []

def returns_bool_type(cursor) -> bool:
    t = cursor.result_type.spelling if hasattr(cursor, 'result_type') else ''
    return t in ('BOOL', '_Bool', 'bool')

def parse_file(path: str, flags: list[str], index: cx.Index) -> list[ClassInfo]:
    tu = index.parse(path, args=flags,
                     options=cx.TranslationUnit.PARSE_SKIP_FUNCTION_BODIES)
    if not tu:
        return []

    classes: dict[str, ClassInfo] = {}

    def visit(cursor, parent=None):
        loc = cursor.location
        # Only care about nodes defined in this file (skip system headers).
        if loc.file and loc.file.name != path:
            return

        k = cursor.kind

        if k == cx.CursorKind.OBJC_INTERFACE_DECL:
            ci = ClassInfo(cursor.spelling, 'objc_interface',
                           f"{Path(loc.file.name).name}:{loc.line}")
            for child in cursor.get_children():
                if child.kind == cx.CursorKind.OBJC_SUPER_CLASS_REF:
                    ci.superclass = child.spelling
                elif child.kind == cx.CursorKind.OBJC_PROTOCOL_REF:
                    ci.protocols.append(child.spelling)
            classes[cursor.spelling] = ci

        elif k == cx.CursorKind.OBJC_CATEGORY_DECL:
            # Anonymous categories (class extensions) have an empty displayname;
            # skip them — they're implementation detail, not public interface.
            if not cursor.displayname:
                for child in cursor.get_children():
                    visit(child, cursor)
                return
            cat_name = f"{cursor.spelling}({cursor.displayname})"
            ci = ClassInfo(cat_name, 'objc_category',
                           f"{Path(loc.file.name).name}:{loc.line}")
            classes[cat_name] = ci

        elif k == cx.CursorKind.OBJC_PROTOCOL_DECL:
            ci = ClassInfo(cursor.spelling, 'objc_protocol',
                           f"{Path(loc.file.name).name}:{loc.line}")
            classes[cursor.spelling] = ci

        elif k == cx.CursorKind.CLASS_DECL and cursor.is_definition():
            ci = ClassInfo(cursor.spelling, 'cpp_class',
                           f"{Path(loc.file.name).name}:{loc.line}")
            for child in cursor.get_children():
                if child.kind == cx.CursorKind.CXX_BASE_SPECIFIER:
                    ci.superclass = child.spelling
            classes[cursor.spelling] = ci

        # Methods (attach to the most recently opened class in scope)
        elif k in (cx.CursorKind.OBJC_INSTANCE_METHOD_DECL,
                   cx.CursorKind.OBJC_CLASS_METHOD_DECL):
            owner = _find_owner(cursor, classes)
            if owner:
                rb = returns_bool_type(cursor)
                owner.methods.append((
                    cursor.spelling,
                    k == cx.CursorKind.OBJC_CLASS_METHOD_DECL,
                    rb,
                    f"{Path(loc.file.name).name}:{loc.line}"
                ))
                owner.issues += check_method_name(cursor.spelling, rb)

        elif k == cx.CursorKind.CXX_METHOD and cursor.is_definition() is False:
            owner = _find_owner(cursor, classes)
            if owner:
                rb = returns_bool_type(cursor)
                owner.methods.append((
                    cursor.spelling, False, rb,
                    f"{Path(loc.file.name).name}:{loc.line}"
                ))
                owner.issues += check_method_name(cursor.spelling, rb)

        elif k == cx.CursorKind.OBJC_PROPERTY_DECL:
            owner = _find_owner(cursor, classes)
            if owner:
                type_str = cursor.type.spelling
                owner.properties.append((
                    cursor.spelling,
                    type_str,
                    f"{Path(loc.file.name).name}:{loc.line}"
                ))
                owner.issues += check_property_name(cursor.spelling, type_str)

        elif k == cx.CursorKind.OBJC_IVAR_DECL:
            owner = _find_owner(cursor, classes)
            if owner:
                owner.ivars.append((cursor.spelling, cursor.type.spelling,
                                    f"{Path(loc.file.name).name}:{loc.line}"))
                owner.issues += check_ivar_name(cursor.spelling, 'objc')

        elif k == cx.CursorKind.FIELD_DECL:
            owner = _find_owner(cursor, classes)
            if owner and owner.kind == 'cpp_class':
                owner.ivars.append((cursor.spelling, cursor.type.spelling,
                                    f"{Path(loc.file.name).name}:{loc.line}"))
                owner.issues += check_ivar_name(cursor.spelling, 'cpp')

        for child in cursor.get_children():
            visit(child, cursor)

    visit(tu.cursor)
    return list(classes.values())

def _find_owner(cursor, classes: dict) -> ClassInfo | None:
    """Walk up the semantic parent chain to find the enclosing class."""
    p = cursor.semantic_parent
    while p:
        if p.spelling in classes:
            return classes[p.spelling]
        p = p.semantic_parent
    return None

# ── Output ────────────────────────────────────────────────────────────────────

def print_report(all_classes: list[ClassInfo]):
    total_issues = 0
    for ci in sorted(all_classes, key=lambda c: c.name):
        tag = {'objc_interface': '[ObjC]', 'objc_category': '[Cat]',
               'cpp_class': '[C++]', 'objc_protocol': '[Proto]'}.get(ci.kind, '')
        base = f" : {ci.superclass}" if ci.superclass else ''
        protos = f" <{', '.join(ci.protocols)}>" if ci.protocols else ''
        print(f"\n{'='*60}")
        print(f"{tag} {ci.name}{base}{protos}  ({ci.location})")

        if ci.properties:
            print("  Properties:")
            for name, typ, loc in ci.properties:
                print(f"    @property {typ} {name}  ({loc})")

        if ci.methods:
            print("  Methods:")
            for sel, is_cls, rb, loc in ci.methods:
                prefix = '+' if is_cls else '-'
                bool_tag = ' → BOOL' if rb else ''
                print(f"    {prefix} {sel}{bool_tag}  ({loc})")

        if ci.ivars:
            print("  Ivars/Fields:")
            for name, typ, loc in ci.ivars:
                print(f"    {typ} {name}  ({loc})")

        if ci.issues:
            print("  ⚠ Naming issues:")
            for issue in ci.issues:
                print(f"    • {issue}")
            total_issues += len(ci.issues)

    print(f"\n{'='*60}")
    print(f"Total classes/interfaces: {len(all_classes)}")
    print(f"Total naming issues: {total_issues}")

def print_dot(all_classes: list[ClassInfo]):
    print("digraph Ubiquitty {")
    print('  rankdir=BT; node [shape=record fontname="Helvetica" fontsize=10];')
    for ci in all_classes:
        label = ci.name.replace('<', '\\<').replace('>', '\\>')
        color = {'objc_interface': 'lightblue', 'cpp_class': 'lightyellow',
                 'objc_protocol': 'lightgreen', 'objc_category': 'lightsalmon'}.get(ci.kind, 'white')
        methods_label = '\\l'.join(
            ('+' if cls else '-') + ' ' + s for s, cls, _, _ in ci.methods[:12]
        )
        if len(ci.methods) > 12:
            methods_label += f'\\l... +{len(ci.methods)-12} more'
        full_label = f"{{{label}|{methods_label}\\l}}" if methods_label else label
        node_id = ci.name.replace('(', '_').replace(')', '_').replace(' ', '_').replace(':', '_').replace('<', '_').replace('>', '_').replace(',', '_')
        print(f'  {node_id!r} [label={full_label!r} style=filled fillcolor={color!r}];')
        if ci.superclass:
            parent_id = ci.superclass.replace('(', '_').replace(')', '_').replace(' ', '_')
            print(f'  {node_id!r} -> {parent_id!r} [label="extends"];')
        for proto in ci.protocols:
            proto_id = proto.replace('(', '_').replace(')', '_').replace(' ', '_').replace('<', '_').replace('>', '_')
            print(f'  {node_id!r} -> {proto_id!r} [label="conforms" style=dashed];')
    print("}")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    dot_mode = '--dot' in sys.argv

    database = next((path for path in BUILD_DBS if path.is_file()), None)
    if database is None:
        sys.exit("compile_commands.json not found at " + " or ".join(map(str, BUILD_DBS))
                 + "\nRun: ./Scripts/build-macos.sh")

    flags_map = load_flags(database)
    index = cx.Index.create()

    # Find all .h and .cpp files in the macOS platform directory.
    sources = sorted(PLATFORM_DIR.glob('*.h')) + sorted(PLATFORM_DIR.glob('*.cpp'))

    all_classes: list[ClassInfo] = []
    for src in sources:
        flags = flags_map.get(str(src), [])
        # Headers don't appear in compile_commands; borrow flags from the
        # matching .cpp if available, otherwise use a minimal set.
        if not flags:
            implementation = src.with_suffix('.cpp')
            flags = flags_map.get(str(implementation), [
                '-x', 'c++-header',
                '-std=c++23',
                f'-isysroot', '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk',
            ])
        parsed = parse_file(str(src), flags, index)
        all_classes.extend(parsed)

    # Deduplicate by name (headers + implementation files both declare the same interface).
    seen: dict[str, ClassInfo] = {}
    for ci in all_classes:
        if ci.name not in seen:
            seen[ci.name] = ci
        else:
            # Merge: prefer the richer definition (more methods/properties).
            existing = seen[ci.name]
            if len(ci.methods) + len(ci.properties) > len(existing.methods) + len(existing.properties):
                seen[ci.name] = ci
            else:
                existing.issues += ci.issues

    merged = list(seen.values())

    if dot_mode:
        print_dot(merged)
    else:
        print_report(merged)

if __name__ == '__main__':
    main()
