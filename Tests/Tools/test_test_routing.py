#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Checks the GTK gate's actual App/Core/Kit inputs and verdict cache."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE_ROOT = Path(os.environ.get("UBQ_CORE_ROOT") or ROOT / "Libraries/ubiquitty-core")
KIT_ROOT = Path(os.environ.get("UBQ_KIT_ROOT") or ROOT / "Libraries/ubiquitty-kit")
INPUTS = {
    "Scripts/library-scripts.sh": "app",
    "cmake/LicenseNotices.cmake": "core",
    "cmake/BundleLicenseNotices.cmake": "kit",
    "cmake/BundleResources.cmake": "kit",
    "cmake/SwiftInteropStamp.cmake": "kit",
}


class GTKGateInputs(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("gate_scopes", CORE_ROOT / "Scripts/check-gate-scopes.py")
        checker = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(CORE_ROOT / "Scripts"))
        try:
            spec.loader.exec_module(checker)
        finally:
            sys.path.pop(0)
        matches = [match for match in checker.INVOCATION.finditer((ROOT / "Scripts/pre-push-gates.sh").read_text())
                   if match.group("name") == "GTK frontend compiles on Linux ($UBQ_LINUX_HOST)"]
        self.assertEqual(len(matches), 1)
        self.scope = matches[0].group("scope").split()
        self.scratch = tempfile.TemporaryDirectory(prefix="ubiquitty-app-gate-inputs-")
        self.addCleanup(self.scratch.cleanup)
        base = Path(self.scratch.name).resolve()
        self.roots = {role: base / role for role in ("app", "core", "kit")}
        for role, root in self.roots.items():
            (root / "Scripts").mkdir(parents=True)
            (root / "Scripts/repository.txt").write_text(role + "\n")
        self.environment = {name: value for name, value in os.environ.items()
                            if not name.startswith("GIT_")}
        self.environment.update(UBQ_CORE_ROOT=str(self.roots["core"]), UBQ_KIT_ROOT=str(self.roots["kit"]))
        owners = {"app": ROOT, "core": CORE_ROOT, "kit": KIT_ROOT}
        for relative, owner in INPUTS.items():
            source = owners[owner] / relative
            self.assertTrue(source.is_file(), source)
            target = self.roots[owner] / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)

    def test_app_bootstrap_binds_the_actual_external_cache_owners(self):
        app = self.roots["app"]
        canonical = {role: app / "Libraries" / f"ubiquitty-{role}" for role in ("core", "kit")}
        for root in canonical.values():
            (root / "Scripts").mkdir(parents=True)
        shutil.copyfile(ROOT / "Scripts/pre-push-gates.sh", app / "Scripts/pre-push-gates.sh")
        # Stop before any gates, after the actual shared root bootstrap has
        # resolved its owners. The canonical mounts must not win over
        # the CMake-form external roots selected by the app's loader.
        bootstrap = (
            '. "$COMMON_ROOT_BOOTSTRAP"\n'
            'printf \'%s\\n\' "$UBQ_CORE_ROOT" "$UBQ_KIT_ROOT" "$CORE_ROOT" "$KIT_ROOT" "$UBQ_SUBJECT_ROOT"\n'
            'declare -p UBQ_CORE_ROOT UBQ_KIT_ROOT\n'
            'exit 0\n')
        for root in (self.roots["core"], canonical["core"]):
            (root / "Scripts/pre-push-gates-lib.sh").write_text(bootstrap)
        for mode in ("canonical", "explicit", "cmake"):
            with self.subTest(mode=mode):
                environment = self.environment.copy()
                for name in ("UBQ_CORE_ROOT", "UBQ_KIT_ROOT", "UBIQUITTY_CORE_SOURCE_DIR", "UBIQUITTY_KIT_SOURCE_DIR"):
                    environment.pop(name, None)
                selected = canonical if mode == "canonical" else self.roots
                if mode == "explicit":
                    environment.update(UBQ_CORE_ROOT=str(selected["core"]), UBQ_KIT_ROOT=str(selected["kit"]),
                                       UBIQUITTY_CORE_SOURCE_DIR=str(canonical["core"]),
                                       UBIQUITTY_KIT_SOURCE_DIR=str(canonical["kit"]))
                elif mode == "cmake":
                    environment.update(UBIQUITTY_CORE_SOURCE_DIR=str(selected["core"]),
                                       UBIQUITTY_KIT_SOURCE_DIR=str(selected["kit"]))
                environment["COMMON_ROOT_BOOTSTRAP"] = str(CORE_ROOT / "Scripts/ubq-roots.sh")
                checked = subprocess.run(["bash", str(app / "Scripts/pre-push-gates.sh")], cwd=app,
                                         env=environment, text=True, capture_output=True, timeout=20)
                self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                lines = checked.stdout.splitlines()
                self.assertEqual(lines[:5], [str(selected["core"]), str(selected["kit"])] * 2 + [str(app)])
                self.assertEqual(len(lines), 7)
                for declaration in lines[5:]:
                    self.assertEqual(declaration.startswith("declare -x "), mode == "explicit", declaration)

    def test_each_input_is_required_by_the_unchanged_scope_checker(self):
        app = self.roots["app"]
        for relative in self.scope:
            if relative in INPUTS:
                continue
            path = app / relative
            if path.suffix or path.name == "CMakeLists.txt":
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            else:
                path.mkdir(parents=True, exist_ok=True)
        (app / "Scripts/linux-host.sh").write_text('. "$ROOT/Scripts/library-scripts.sh"\n')
        (app / "CMakeLists.txt").write_text("".join(
            f'include("${{UBIQUITTY_{owner.upper()}_SOURCE_DIR}}/{relative}")\n'
            for relative, owner in INPUTS.items() if owner != "app"))
        # Module contents are irrelevant to this narrow include graph. Their
        # actual source bytes and owners are exercised by the cache test below.
        for relative, owner in INPUTS.items():
            if owner != "app":
                (self.roots[owner] / relative).write_text("")
        gate = app / "Scripts/pre-push-gates.sh"
        for omitted in (None, *INPUTS):
            with self.subTest(omitted=omitted):
                scope = " ".join(path for path in self.scope if path != omitted)
                gate.write_text(f'run_scoped "GTK fixture" "{scope}" ./Scripts/linux-host.sh\n')
                checked = subprocess.run([sys.executable, str(CORE_ROOT / "Scripts/check-gate-scopes.py")],
                                         cwd=app, env=self.environment, text=True, capture_output=True)
                self.assertEqual(checked.returncode, 0 if omitted is None else 1,
                                 checked.stdout + checked.stderr)
                if omitted is not None:
                    self.assertIn(omitted, checked.stderr)

    def test_each_actual_owner_edit_invalidates_the_gtk_cache(self):
        for root in self.roots.values():
            for arguments in (("init", "-q"), ("add", "."),
                              ("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                               "commit", "-qm", "Fixture inputs")):
                subprocess.run(["git", "-C", str(root), *arguments], env=self.environment,
                               check=True, capture_output=True)
        script = '''
. "$1"
UBQ_GATE_CACHE_ROOT="$2"
UBQ_GATE_CACHE_TIER=quick
UBQ_GATE_CACHE_ENABLED=1
UBQ_GATE_CACHE_ENVIRONMENT="$(ubq_gate_cache_environment)" || exit
ubq_gate_cache_scoped_key "$3" compile
'''

        def key():
            checked = subprocess.run(["bash", "-c", script, "fixture",
                                      str(CORE_ROOT / "Scripts/pre-push-cache.sh"),
                                      str(self.roots["app"]), " ".join(self.scope)],
                                     env=self.environment, text=True, capture_output=True, check=True)
            self.assertTrue(checked.stdout.strip())
            return checked.stdout.strip()

        original = key()
        for relative, owner in INPUTS.items():
            with self.subTest(path=relative, owner=owner):
                path = self.roots[owner] / relative
                contents = path.read_bytes()
                path.write_bytes(contents + b"\n# Changed fixture input.\n")
                self.assertNotEqual(key(), original)
                path.write_bytes(contents)
        self.assertEqual(key(), original)


class RendererGateSelection(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-renderer-gate-selection-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def function(self, path, name):
        source = path.read_text()
        start = source.index(name + "() {\n")
        return source[start:source.index("\n}\n", start) + 3]

    def select(self, name, changed, *, expanded=None, status=0, host="Darwin", tier="quick"):
        diff = self.directory / "diff"
        diff.write_text(changed)
        logical = self.directory / "expanded"
        logical.write_text(changed if expanded is None else expanded)
        script = '''set -euo pipefail
git() {
    [ "$*" = 'diff --name-only origin/main...HEAD' ] || return 97
    cat "$FRAME_DIFF"
    return "$FRAME_DIFF_STATUS"
}
ubq_changed_with_libraries() {
    cat "$FRAME_EXPANDED"
    return "$FRAME_DIFF_STATUS"
}
uname() { printf '%s\\n' "$FRAME_HOST"; }
run() { printf 'RUN:<%s><%s>\\n' "$1" "$2"; }
SKIPPED=()
'''
        script += self.function(KIT_ROOT / "Scripts/pre-push-gates-kit.sh", "kit_swift_arm_reached")
        script += self.function(ROOT / "Scripts/pre-push-gates.sh", name)
        script += f"\n{name}\nprintf '\\nSKIPS:%s\\n' \"${{SKIPPED[*]-}}\"\n"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(FRAME_DIFF=str(diff), FRAME_EXPANDED=str(logical), FRAME_DIFF_STATUS=str(status),
                           FRAME_HOST=host, TIER=tier, UBQ_CORE_ROOT=str(CORE_ROOT), UBQ_KIT_ROOT=str(KIT_ROOT))
        checked = subprocess.run(["bash", "-c", script], env=environment, text=True,
                                 capture_output=True, timeout=20)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertNotIn("Broken pipe", checked.stderr)
        return checked.stdout

    def large_diff(self, first):
        return first + "\n" + "".join(f"Docs/unrelated-{index:06d}-{'x' * 80}.md\n" for index in range(40000))

    def test_frame_gate_consumes_a_large_early_match(self):
        output = self.select("gate_core_builder_frames", self.large_diff("Source/Core/Rendering/CellInstance.h"))
        self.assertIn("RUN:<core builder frames><./Scripts/check-core-builder-frames.sh>", output)
        self.assertNotIn("none", output)

    def test_frame_gate_selects_each_dependency_pin_and_existing_path(self):
        for path in ("Libraries/ubiquitty-core", "Libraries/ubiquitty-kit", "Source/Core/Rendering/CellInstance.h",
                     "Source/Platform/macOS/main.swift", "Scripts/cmake/UbiquittyKit.cmake",
                     "Scripts/cmake/AppleSharedSwift.cmake"):
            with self.subTest(path=path):
                self.assertIn("RUN:<core builder frames>", self.select("gate_core_builder_frames", path))

    def test_frame_gate_preserves_unrelated_and_unread_diff_behavior(self):
        for path in ("", "Docs/guide.md", "Libraries/ubiquitty-core-other", "Libraries/ubiquitty-kit-other"):
            with self.subTest(path=path):
                output = self.select("gate_core_builder_frames", path)
                self.assertNotIn("RUN:", output)
                self.assertIn("none — this branch changes no frame path", output)
        for status in (1, 128):
            with self.subTest(status=status):
                output = self.select("gate_core_builder_frames", "Libraries/ubiquitty-core", status=status)
                self.assertNotIn("RUN:", output)
                self.assertNotIn("none", output)

    def test_frame_gate_keeps_the_non_darwin_decline(self):
        output = self.select("gate_core_builder_frames", "Libraries/ubiquitty-kit", host="Linux")
        self.assertNotIn("RUN:", output)
        self.assertIn("SKIPS:core builder frames (needs the macOS app and a Metal device; this host is Linux)", output)

    def renderer_arms(self, changed, **arguments):
        return self.select("ubq_renderer_arms", changed, **arguments).split("\nSKIPS:", 1)[0].split()

    def test_renderer_arms_consume_each_large_early_match(self):
        for path, expected in (("Source/Core/Terminal.cpp", ["portable"]),
                               ("Source/Platform/Web/WebTerminal.cpp", ["web"]),
                               ("Source/Platform/Linux/main.cpp", ["linux"]),
                               ("Source/UbiquittyRenderKit/FrameInstances.swift", ["swift"]),
                               ("Source/UbiquittyKit/Swift/Surface.swift", ["swift"]),
                               ("Source/Platform/macOS/main.swift", ["swift"])):
            with self.subTest(path=path):
                self.assertEqual(self.renderer_arms(self.large_diff(path)), expected)

    def test_unresolved_dependency_pins_select_all_arms_once(self):
        for path in ("Libraries/ubiquitty-core", "Libraries/ubiquitty-kit",
                     "Libraries/ubiquitty-core\nLibraries/ubiquitty-kit"):
            with self.subTest(path=path):
                self.assertEqual(self.renderer_arms(self.large_diff(path)), ["swift", "portable", "web", "linux"])

    def test_resolved_dependency_changes_keep_logical_paths_and_tier_policy(self):
        for path, expected in (("Source/Core/Terminal.cpp", ["portable"]),
                               ("Source/Platform/Web/WebTerminal.cpp", ["web"]),
                               ("Source/Platform/Linux/main.cpp", ["linux"]),
                               ("Source/UbiquittyRenderKit/FrameInstances.swift", ["swift"]),
                               ("Scripts/cmake/UbiquittyKit.cmake", ["swift"]),
                               ("Scripts/cmake/AppleSharedSwift.cmake", ["swift"])):
            with self.subTest(expanded=path):
                self.assertEqual(self.renderer_arms("Libraries/ubiquitty-kit", expanded=path), expected)
        for tier in ("linux", "full"):
            with self.subTest(tier=tier):
                self.assertEqual(self.renderer_arms("Libraries/ubiquitty-core", expanded=self.large_diff(
                    "Source/Core/Terminal.cpp"), tier=tier), ["portable", "linux"])

    def test_renderer_selection_preserves_unrelated_excluded_and_unread_diffs(self):
        for path in ("", "Docs/guide.md", "Source/Platform/macOS/UITest/Scenario.swift",
                     "Libraries/ubiquitty-core-other", "Libraries/ubiquitty-kit-other"):
            with self.subTest(path=path):
                self.assertEqual(self.renderer_arms(path), [])
        for status in (1, 128):
            with self.subTest(status=status):
                self.assertEqual(self.renderer_arms("Libraries/ubiquitty-core", status=status), [])


if __name__ == "__main__":
    unittest.main()
