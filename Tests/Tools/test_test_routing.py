#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Checks App tool routing, source ownership, snapshots, and verdict caching."""

import ast
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
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


class ComposedSnapshotRouting(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-composed-snapshots-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.app = self.directory / "App owner"
        self.core = self.directory / "Core owner"
        self.kit = self.directory / "Kit owner"
        for role, root in (("app", self.app), ("core", self.core), ("kit", self.kit)):
            (root / "Scripts").mkdir(parents=True)
            (root / "Scripts/repository.txt").write_text(role + "\n")
            (root / "CMakeLists.txt").write_text("cmake_minimum_required(VERSION 3.13)\n")
        for name in ("ci_batteries.py", "gate_framework.py", "gate_report.py", "ubq_roots.py", "build_root.py"):
            shutil.copyfile(CORE_ROOT / "Scripts" / name, self.core / "Scripts" / name)
        self.calls = self.directory / "calls.jsonl"
        tool = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
kind = Path(sys.argv[0]).name
record = {"tool": kind, "arguments": sys.argv[1:], "cwd": os.getcwd(),
          "subject": os.environ.get("UBQ_TESTS_ROOT"), "core": os.environ.get("UBQ_CORE_ROOT"),
          "kit": os.environ.get("UBQ_KIT_ROOT")}
with open(os.environ["SNAPSHOT_CALLS"], "a") as output:
    output.write(json.dumps(record) + "\\n")
status = 0
if kind == "run.py":
    backend = sys.argv[sys.argv.index("--backend") + 1]
    status = json.loads(os.environ.get("SNAPSHOT_STATUSES", "{}" )).get(backend, 0)
    print("VERDICT  " + ("PASSED" if status == 0 else "REFUSED" if status == 2 else "FAILED"))
raise SystemExit(status)
'''
        for path in (self.core / "Scripts/build-core-snapshot.sh", self.app / "Scripts/build-macos.sh",
                     self.core / "Tests/Snapshots/run.py"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(tool)
            path.chmod(0o755)
        binary = self.directory / "bin"
        binary.mkdir()
        uname = binary / "uname"
        uname.write_text('#!/bin/sh\nprintf "%s\\n" "$SNAPSHOT_HOST"\n')
        uname.chmod(0o755)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(("GIT_", "GITHUB_", "UBQ_", "UBIQUITTY_"))}
        self.environment.update(PATH=str(binary) + os.pathsep + os.environ.get("PATH", ""),
                                ROOT=str(self.app), UBQ_CORE_ROOT=str(self.core), UBQ_KIT_ROOT=str(self.kit),
                                UBQ_BUILD_ROOT=str(self.directory / "build"),
                                UBQ_CI_ROOT=str(self.directory / "ci"), RUNNER_TEMP=str(self.directory / "temp"),
                                RUNNER_WORKSPACE=str(self.directory), SNAPSHOT_CALLS=str(self.calls),
                                SNAPSHOT_HOST="Darwin", SNAPSHOT_ARMS="portable swift web linux",
                                ACTUAL_CORE_ROOT=str(CORE_ROOT), TIER="quick")
        Path(self.environment["RUNNER_TEMP"]).mkdir()
        Path(self.environment["UBQ_CI_ROOT"]).mkdir()
        self.environment["TMPDIR"] = self.environment["RUNNER_TEMP"]

    def function(self, name):
        source = (ROOT / "Scripts/pre-push-gates.sh").read_text()
        start = source.find(name + "() {\n")
        if start < 0:
            return ""
        return source[start:source.index("\n}\n", start) + 3]

    def execute(self, name, *, host="Darwin", arms="portable swift web linux", statuses=None, demand=False):
        self.calls.unlink(missing_ok=True)
        environment = self.environment.copy()
        environment.update(SNAPSHOT_HOST=host, SNAPSHOT_ARMS=arms,
                           SNAPSHOT_STATUSES=json.dumps(statuses or {}))
        if demand:
            environment["SNAPSHOT"] = "demand"
        script = '''set -euo pipefail
. "$ACTUAL_CORE_ROOT/Scripts/ubq-roots.sh"
. "$ACTUAL_CORE_ROOT/Scripts/pre-push-cache.sh"
. "$ACTUAL_CORE_ROOT/Scripts/pre-push-runner.sh"
UBQ_GATE_CACHE_ENABLED=0
ubq_renderer_arms() { printf '%s' "$SNAPSHOT_ARMS"; }
ubq_linux_route() { UBQ_LINUX_HOST=""; }
'''
        for function in ("ubq_arm_rebuild", "ubq_app_snapshot_sources", "ubq_optional_web_snapshots", name):
            script += self.function(function) + "\n"
        script += name + '''
printf 'RESULT:%s|%s|%s\\n' "${FAILED[*]-}" "${SKIPPED[*]-}" "${ELSEWHERE[*]-}"
[ "${#FAILED[@]}" -eq 0 ]
'''
        checked = subprocess.run(["bash", "-c", script], cwd=self.app, env=environment,
                                 text=True, capture_output=True, timeout=40)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        self.assertIn("RESULT:", checked.stdout, checked.stdout + checked.stderr)
        result = checked.stdout.rsplit("RESULT:", 1)[1].splitlines()[0].split("|")
        return checked, calls, result

    def backends(self, calls):
        return [call["arguments"][call["arguments"].index("--backend") + 1]
                for call in calls if call["tool"] == "run.py"]

    def assert_roots(self, calls):
        for call in calls:
            if call["tool"] != "run.py":
                continue
            for flag, root in (("--source-root", self.app), ("--core-source-root", self.core),
                               ("--kit-source-root", self.kit)):
                self.assertIn(flag, call["arguments"])
                self.assertEqual(call["arguments"][call["arguments"].index(flag) + 1], str(root))
            self.assertEqual(call["cwd"], str(self.app))

    def test_normal_gate_runs_selected_arms_in_a_real_gitless_composition(self):
        checked, calls, result = self.execute("gate_renderer_snapshots")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(self.backends(calls), ["portable", "swift", "web", "linux"])
        self.assert_roots(calls)
        self.assertEqual(result, ["", "", ""])
        for call in calls:
            if call["tool"] == "run.py":
                self.assertEqual("--require-ceilings" in call["arguments"],
                                 call["arguments"][call["arguments"].index("--backend") + 1] != "linux")

    def test_normal_gate_preserves_empty_selection_and_required_arm_failure(self):
        checked, calls, result = self.execute("gate_renderer_snapshots", arms="")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(result, ["", "", ""])
        for status in (1, 2):
            with self.subTest(status=status):
                checked, calls, result = self.execute("gate_renderer_snapshots", arms="swift", statuses={"swift": status})
                self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                self.assertIn("snapshot arm: swift", result[0])
                self.assertEqual(result[1:], ["", ""])
                self.assertEqual(self.backends(calls), ["swift"] * (2 if status == 2 else 1))
                self.assertEqual([call["arguments"] for call in calls if call["tool"] == "build-macos.sh"],
                                 [["--clean"]] if status == 2 else [])

    def test_normal_gate_uses_canonical_library_mounts_too(self):
        canonical_core = self.app / "Libraries/ubiquitty-core"
        canonical_kit = self.app / "Libraries/ubiquitty-kit"
        shutil.copytree(self.core, canonical_core)
        shutil.copytree(self.kit, canonical_kit)
        self.core, self.kit = canonical_core, canonical_kit
        self.environment.update(UBQ_CORE_ROOT=str(self.core), UBQ_KIT_ROOT=str(self.kit))
        checked, calls, result = self.execute("gate_renderer_snapshots", arms="portable swift")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(self.backends(calls), ["portable", "swift"])
        self.assert_roots(calls)
        self.assertEqual(result, ["", "", ""])

    def test_missing_or_wrong_owner_refuses_before_building_or_rendering(self):
        for owner in (self.core, self.kit):
            for missing in (True, False):
                with self.subTest(owner=owner.name, missing=missing):
                    path = owner / ("CMakeLists.txt" if missing else "Scripts/repository.txt")
                    original = path.read_text()
                    if missing:
                        path.unlink()
                    else:
                        path.write_text("app\n")
                    try:
                        for gate in ("gate_renderer_snapshots", "gate_snapshots"):
                            checked, calls, result = self.execute(gate)
                            self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                            self.assertEqual(calls, [])
                            self.assertIn("snapshot source roots", result[0])
                            self.assertEqual(result[1:], ["", ""])
                    finally:
                        path.write_text(original)

    def test_full_darwin_uses_the_official_battery_and_all_native_catalogs(self):
        module = Path(self.environment["UBQ_BUILD_ROOT"]) / "web-dist/ubiquitty.wasm"
        module.parent.mkdir(parents=True)
        module.write_bytes(b"fixture")
        checked, calls, result = self.execute("gate_snapshots")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(self.backends(calls), ["portable", "macos", "swift", "web"])
        self.assert_roots(calls)
        self.assertEqual([call["arguments"] for call in calls if call["tool"] == "build-macos.sh"], [["--no-helpers"]])
        self.assertEqual([call["tool"] for call in calls[:2]], ["build-macos.sh", "build-core-snapshot.sh"])
        records = list((self.directory / "ci/apple").glob("battery-*.json"))
        self.assertEqual(len(records), 1)
        stages = json.loads(records[0].read_text())
        self.assertEqual([(stage["key"], stage["state"]) for stage in stages],
                         [("portable-build", "completed"), ("snapshots", "completed")])
        self.assertEqual(result, ["", "", ""])

    def test_full_linux_keeps_portable_and_optional_web_without_apple_backends(self):
        for demand in (False, True):
            with self.subTest(demand=demand):
                checked, calls, result = self.execute("gate_snapshots", host="Linux", demand=demand)
                self.assertEqual(checked.returncode, 1 if demand else 0, checked.stdout + checked.stderr)
                self.assertEqual(self.backends(calls), ["portable"])
                self.assertNotIn("build-macos.sh", [call["tool"] for call in calls])
                self.assert_roots(calls)
                self.assertIn("Web snapshot regressions", result[0] if demand else result[1])
        module = Path(self.environment["UBQ_BUILD_ROOT"]) / "web-dist/ubiquitty.wasm"
        module.parent.mkdir(parents=True, exist_ok=True)
        module.write_bytes(b"fixture")
        checked, calls, result = self.execute("gate_snapshots", host="Linux")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(self.backends(calls), ["portable", "web"])
        self.assertEqual(result, ["", "", ""])


class WebSnapshotOwnership(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ubiquitty-web-snapshot-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name).resolve()
        self.app = self.base / "app with spaces '$ literal"
        self.core = self.app / "Libraries/ubiquitty-core"
        self.kit = self.app / "Libraries/ubiquitty-kit"
        self.output = self.base / "output with spaces '$ literal"
        for directory in (self.app / "Scripts", self.core / "Scripts", self.kit,
                          self.output / "web", self.output / "web-dist"):
            directory.mkdir(parents=True)
        for relative in ("Scripts/web-snapshot-shim.mjs", "Scripts/library-scripts.sh"):
            shutil.copy2(ROOT / relative, self.app / relative)
        for relative in ("Scripts/build_root.py", "Scripts/build-provenance.sh"):
            shutil.copy2(CORE_ROOT / relative, self.core / relative)
        self.shim = self.app / "Scripts/web-snapshot-shim.mjs"
        self.wasm = self.output / "web-dist/ubiquitty.wasm"
        self.wasm.write_bytes(b"snapshot fixture")
        self.environment = {name: value for name, value in os.environ.items()
                            if not name.startswith("GIT_") and name not in (
                                "UBQ_BUILD_ROOT", "UBIQUITTY_DERIVED_DATA", "UBQ_CORE_ROOT", "UBQ_KIT_ROOT",
                                "UBIQUITTY_CORE_SOURCE_DIR", "UBIQUITTY_KIT_SOURCE_DIR")}
        self.environment.update(UBQ_BUILD_ROOT=str(self.output), GIT_CONFIG_NOSYSTEM="1",
                                GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME="Fixture",
                                GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture",
                                GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.source = self.core / "Source/Core/Fixture.cpp"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("fixture\n")
        (self.core / "Scripts/portable-core-sources.txt").write_text("Source/Core/Fixture.cpp\n")

    def probe(self, environment=None):
        return subprocess.run([str(self.shim), "--print-render-binary"], cwd=self.base,
                              env=environment or self.environment, text=True, capture_output=True, timeout=15)

    def guards(self):
        runner = CORE_ROOT / "Tests/Snapshots/run.py"
        names = {"_rendering_binary", "_refuse_if_stale", "_refuse_if_foreign",
                 "_renders_the_same_sources", "_portable_core_paths"}
        functions = [node for node in ast.parse(runner.read_text()).body
                     if isinstance(node, ast.FunctionDef) and node.name in names]
        self.assertEqual({node.name for node in functions}, names)
        spec = importlib.util.spec_from_file_location("web_snapshot_roots", CORE_ROOT / "Scripts/ubq_roots.py")
        roots = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = roots
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(roots)
        namespace = dict(Path=Path, os=os, subprocess=subprocess, sys=sys, ROOT=self.core,
                         SUBJECT_ROOT=self.app, SOURCE_FILES=SimpleNamespace(roots=(self.core, self.kit, self.app)),
                         _roots=roots)
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(runner), "exec"), namespace)
        return namespace

    def test_probe_uses_canonical_core_for_gitless_app_with_spaces(self):
        environment = self.environment.copy()
        environment.pop("UBQ_BUILD_ROOT")
        environment["UBIQUITTY_DERIVED_DATA"] = str(self.output)
        expected = subprocess.run([sys.executable, str(self.core / "Scripts/build_root.py"), str(self.app)],
                                  env=environment, capture_output=True, text=True, check=True).stdout.strip()
        result = self.probe(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(Path(expected) / "web-dist/ubiquitty.wasm"))
        self.assertFalse((self.app / "Scripts/build_root.py").exists())

    def test_probe_preserves_external_root_aliases_and_precedence(self):
        external = self.base / "external Core with spaces '$ literal"
        (external / "Scripts").mkdir(parents=True)
        shutil.copy2(self.core / "Scripts/build_root.py", external / "Scripts/build_root.py")
        (self.core / "Scripts/build_root.py").write_text("raise SystemExit('wrong canonical owner')\n")
        for mode in ("UBQ_CORE_ROOT", "UBIQUITTY_CORE_SOURCE_DIR", "precedence"):
            with self.subTest(mode=mode):
                environment = self.environment.copy()
                if mode == "precedence":
                    environment.update(UBQ_CORE_ROOT=str(external),
                                       UBIQUITTY_CORE_SOURCE_DIR=str(self.base / "wrong owner"))
                else:
                    environment[mode] = str(external)
                result = self.probe(environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(self.wasm))

    def test_probe_refuses_an_uninitialized_or_missing_core_owner(self):
        (self.core / "Scripts/build_root.py").unlink()
        for mode in ("uninitialized", "missing explicit owner"):
            with self.subTest(mode=mode):
                environment = self.environment.copy()
                if mode == "missing explicit owner":
                    environment["UBQ_CORE_ROOT"] = str(self.base / "missing Core")
                result = self.probe(environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("build_root.py", result.stderr)

    def test_real_launcher_guard_measures_wasm_and_rejects_stale_wasm(self):
        guards = self.guards()
        # Only this fixture's files are aged: the launcher is older than Core,
        # while the built module is newer, then independently becomes stale.
        os.utime(self.shim, (100, 100))
        os.utime(self.source, (200, 200))
        os.utime(self.wasm, (300, 300))
        previous = os.environ.copy()
        try:
            os.environ.clear()
            os.environ.update(self.environment)
            rendering = guards["_rendering_binary"](self.shim)
        finally:
            os.environ.clear()
            os.environ.update(previous)
        self.assertEqual(rendering, self.wasm)
        guards["_refuse_if_stale"](rendering, "web")
        os.utime(self.wasm, (150, 150))
        os.utime(self.shim, (400, 400))
        with self.assertRaisesRegex(RuntimeError, "older than the portable Core"):
            guards["_refuse_if_stale"](rendering, "web")

    def test_real_stage_stamp_and_foreign_guard_bind_the_distribution(self):
        def git(*arguments):
            return subprocess.run(["git", "-C", str(self.app), *arguments], env=self.environment,
                                  capture_output=True, text=True, check=True).stdout.strip()

        (self.app / "Source").mkdir()
        source = self.app / "Source/Web.cpp"
        source.write_text("original\n")
        git("init", "-q")
        git("add", "Source/Web.cpp")
        git("commit", "-qm", "Fixture original")
        original = git("rev-parse", "HEAD")
        source.write_text("foreign\n")
        git("commit", "-qam", "Fixture different renderer")
        foreign = git("rev-parse", "HEAD")
        builder = (ROOT / "Scripts/build-web.sh").read_text()
        stamp = 'source "$CORE_ROOT/Scripts/build-provenance.sh"'
        commands = builder[builder.index(stamp):].split('echo "build-web: staged', 1)[0]
        environment = dict(self.environment, ROOT=str(self.app), CORE_ROOT=str(self.core),
                           BUILD=str(self.output / "web"), STAGE=str(self.output / "web-dist"))
        checked = subprocess.run(["bash", "-euc", commands], env=environment,
                                 capture_output=True, text=True, timeout=15)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        for directory in (self.output / "web", self.output / "web-dist"):
            stamp_file = directory / ".ubiquitty-build-provenance"
            self.assertTrue(stamp_file.is_file(), directory)
            self.assertEqual(stamp_file.read_text().split()[0], foreign)
        guards = self.guards()
        guards["_refuse_if_foreign"](self.wasm, "web")
        git("checkout", "-q", original)
        with self.assertRaisesRegex(RuntimeError, "built from"):
            guards["_refuse_if_foreign"](self.wasm, "web")


if __name__ == "__main__":
    unittest.main()
