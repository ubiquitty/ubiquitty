#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Checks App tool routing, source ownership, snapshots, and verdict caching."""

import ast
from dataclasses import replace
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
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import library_scripts  # noqa: E402

CORE_ROOT = Path(library_scripts.CORE_ROOT)
KIT_ROOT = Path(library_scripts.KIT_ROOT)


def gate_library_function(name):
    """A function of Core's gate library, as the hook defines it."""
    source = (CORE_ROOT / "Scripts/pre-push-gates-lib.sh").read_text()
    start = source.index(name + "() {\n")
    return source[start:source.index("\n}\n", start) + 3]
INPUTS = {
    "Scripts/library-scripts.sh": "app",
    "cmake/LicenseNotices.cmake": "core",
    "cmake/BundleLicenseNotices.cmake": "kit",
    "cmake/BundleResources.cmake": "kit",
    "cmake/SwiftInteropStamp.cmake": "kit",
}


class PlatformSmokeOwnership(unittest.TestCase):
    def test_deferred_smokes_have_required_jobs_that_run_their_subject(self):
        spec = importlib.util.spec_from_file_location("app_style", ROOT / "Scripts/style_sections_app.py")
        table = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(table)
        rows = {row.get("gate"): row for row in table.SECTIONS}
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        battery = (CORE_ROOT / "Scripts/ci_batteries.py").read_text()
        for gate, stage, job in (("check-linux-smokes.sh", "linux-smokes", "Linux battery (frontend)"),
                                  ("check-macos-smokes.py", "macos-smokes", "Apple battery (macos)")):
            with self.subTest(gate=gate):
                self.assertEqual(rows[gate]["kind"], "deferred")
                self.assertEqual(rows[gate]["to"], '"' + job + '"')
                self.assertIn("--only " + stage, workflow)
                self.assertIn('Stage("' + stage + '"', battery)
        self.assertIn("Scripts/check-macos-smokes.py", battery)
        self.assertIn("Scripts/run-linux-smokes.sh", battery)


class CTestExecutionOwnership(unittest.TestCase):
    def registration(self, *, native=True, advertise=True, remove_filter=False):
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-app-test-ownership-")
        self.addCleanup(temporary.cleanup)
        source = Path(temporary.name)
        driver = source / "driver.sh"
        stanzas = ["test_app_tools"] + (["test_macos_file_read"] if advertise else [])
        driver.write_text("#!/bin/sh\nprintf '%s\\n' " + " ".join(stanzas) + "\n")
        driver.chmod(0o755)
        owner = (ROOT / "Tests/CMakeLists.txt").read_text()
        start = owner.index("ubiquitty_read_shell_stanzas(_ubq_app_stanzas ")
        end = owner.index("add_test(NAME test_ios_sync_driver", start)
        scheduling = owner[start:end]
        if remove_filter:
            scheduling = scheduling.replace("    list(REMOVE_ITEM _ubq_app_stanzas test_macos_file_read)\n", "")
        release = owner[owner.index("foreach(release_test release_ci release_preparation)"):]
        module = source / "Tests/Tools/test_release_ci.py"
        module.parent.mkdir(parents=True)
        module.symlink_to(ROOT / "Tests/Tools/test_release_ci.py")
        cmake = [
            "cmake_minimum_required(VERSION 3.20)",
            "project(TestOwnership NONE)",
            "enable_testing()",
            f'set(UBIQUITTY_CORE_SOURCE_DIR "{CORE_ROOT}")',
            f'set(Python3_EXECUTABLE "{sys.executable}")',
            f'include("{CORE_ROOT}/Scripts/cmake/UbiquittyTests.cmake")',
            f'set(_ubq_app_shell_driver "{driver}")',
        ]
        if native:
            cmake += [
                "add_test(NAME test_macos_file_read COMMAND cmake -E true)",
                "ubiquitty_set_test_entry_properties(test_macos_file_read)",
                "set_property(DIRECTORY APPEND PROPERTY UBIQUITTY_HOST_TESTS test_macos_file_read)",
            ]
        cmake += [scheduling, "ubiquitty_finish_host_tests()", release]
        (source / "CMakeLists.txt").write_text("\n".join(cmake) + "\n")
        build = source / "build"
        configured = subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja"],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
        listing = subprocess.run(["ctest", "--test-dir", str(build), "--show-only=json-v1"],
                                 capture_output=True, text=True, timeout=15, check=True)
        tests = json.JSONDecoder().raw_decode(listing.stdout)[0]["tests"]
        return {test["name"]: test for test in tests}, (build / "ctest-covered.txt").read_text().splitlines()

    def assert_file_read_has_one_owner(self, tests):
        self.assertEqual(sum(name in tests for name in ("test_macos_file_read", "shell_test_macos_file_read")), 1)

    def test_native_file_read_runs_once_and_is_covered_for_the_outer_driver(self):
        tests, covered = self.registration()
        self.assert_file_read_has_one_owner(tests)
        self.assertIn("test_macos_file_read", tests)
        properties = {row["name"]: row["value"] for row in tests["test_macos_file_read"]["properties"]}
        self.assertEqual(properties["TIMEOUT"], 60.0)
        self.assertIn("ubq_build_fixture", properties["FIXTURES_REQUIRED"])
        self.assertIn("test_macos_file_read", covered)
        self.assertIn("test_app_tools", covered)

    def test_file_read_keeps_its_shell_owner_without_a_native_entry(self):
        tests, covered = self.registration(native=False)
        self.assert_file_read_has_one_owner(tests)
        self.assertIn("shell_test_macos_file_read", tests)
        self.assertIn("test_macos_file_read", covered)

    def test_file_read_census_rejects_duplicate_and_missing_owners(self):
        for arguments in ({"remove_filter": True}, {"native": False, "advertise": False}):
            with self.subTest(arguments=arguments):
                tests, _ = self.registration(**arguments)
                with self.assertRaises(AssertionError):
                    self.assert_file_read_has_one_owner(tests)

    def test_release_ci_module_runs_only_from_its_required_ctest_entry(self):
        tests, _ = self.registration()
        entry = tests["test_release_ci"]
        self.assertEqual(Path(entry["command"][1]).resolve(), ROOT / "Tests/Tools/test_release_ci.py")
        properties = {row["name"]: row["value"] for row in entry["properties"]}
        self.assertEqual(properties["TIMEOUT"], 60.0)
        self.assertIn("ubq_build_fixture", properties["FIXTURES_REQUIRED"])
        with tempfile.TemporaryDirectory(prefix="ubiquitty-app-tools-invocations-") as directory:
            log = Path(directory) / "invocations"
            script = '''
set -euo pipefail
ROOT="$1"
CORE_ROOT="$UBQ_CORE_ROOT"
KIT_ROOT="$UBQ_KIT_ROOT"
RAN=0
wanted() { [ "$1" = test_app_tools ]; }
build_and_run() { :; }
python3() { printf '%s\\n' "$1" >> "$OWNERSHIP_LOG"; }
. "$ROOT/Scripts/run-tests-stanzas-app.sh"
'''
            checked = subprocess.run(["bash", "-c", script, "fixture", str(ROOT)],
                                     env={**os.environ, "OWNERSHIP_LOG": str(log),
                                          "UBQ_CORE_ROOT": str(CORE_ROOT), "UBQ_KIT_ROOT": str(KIT_ROOT)},
                                     capture_output=True, text=True, timeout=15)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            modules = [Path(line).name for line in log.read_text().splitlines()]
        self.assertEqual(modules, [
            "test_install_macos.py", "test_bundle_resources.py", "test_fetch_sparkle.py",
            "test_test_routing.py", "test_package_notices.py",
        ])
        owners = [Path(entry["command"][1]).name] + modules
        self.assertEqual(owners.count("test_release_ci.py"), 1)


class AppleTestBuildReuse(unittest.TestCase):
    def push_script(self):
        apple = (ROOT / ".github/workflows/ci.yml").read_text().split("  apple:\n", 1)[1]
        step = apple.split("      - name: Push gates (${{ matrix.group }})\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("UBQ_BUILD_ROOT: ${{ steps.roots.outputs.build }}", step)
        self.assertIn("UBQ_APPLE_GROUP: ${{ matrix.group }}", step)
        return "\n".join(line[10:] for line in step.split("        run: |\n", 1)[1].splitlines())

    def test_apple_tests_reuse_the_batterys_compile_configuration_and_postcheck_inputs(self):
        with tempfile.TemporaryDirectory(prefix="ubiquitty-apple-test-reuse-") as temporary:
            directory = Path(temporary).resolve()
            app = directory / "app with spaces"
            (app / "Scripts").mkdir(parents=True)
            (app / "CMakeLists.txt").write_text("# App source fixture\n")
            (app / "Scripts/repository.txt").write_text("app\n")
            subprocess.run(["git", "init", "--quiet", str(app)], check=True)
            tools = directory / "tools"
            tools.mkdir()
            trace = directory / "calls.jsonl"
            cmake = tools / "cmake"
            cmake.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
with open(os.environ['BUILD_REUSE_TRACE'], 'a') as output:
    output.write(json.dumps({{'arguments': sys.argv[1:], 'CC': os.environ.get('CC'), 'CXX': os.environ.get('CXX')}}) + '\\n')
if '-B' in sys.argv:
    pathlib.Path(sys.argv[sys.argv.index('-B') + 1]).mkdir(parents=True, exist_ok=True)
''')
            cmake.chmod(0o755)
            python = tools / "python3"
            python.write_text(f'''#!{sys.executable}
import os, sys
if len(sys.argv) > 1 and sys.argv[1].endswith('/Scripts/check-build-reached.py'):
    sys.exit(0)
os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])
''')
            python.chmod(0o755)
            captured = directory / "postcheck-environment.json"
            (app / "Scripts/pre-push-gates.sh").write_text(f'''#!/bin/bash
set -euo pipefail
"{sys.executable}" - "$BUILD_REUSE_ENV" <<'PY'
import json, os, sys
with open(sys.argv[1], 'w') as output:
    json.dump({{name: os.environ.get(name) for name in ('UBQ_BUILD_ROOT', 'UBQ_TESTS_BUILD', 'UBQ_HOST_TEST_TREE', 'UBIQUITTY_QUIC_PREFIX')}}, output)
PY
if [ "$UBQ_APPLE_GROUP" = tests ]; then "$ACTUAL_CORE_ROOT/Scripts/build-tests.sh"; fi
''')
            (app / "Scripts/pre-push-gates.sh").chmod(0o755)
            base = directory / "build root"
            environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
            environment.update(PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
                               UBQ_TESTS_ROOT=str(app), UBQ_CORE_ROOT=str(CORE_ROOT), UBQ_KIT_ROOT=str(KIT_ROOT),
                               ACTUAL_CORE_ROOT=str(CORE_ROOT), UBQ_BUILD_ROOT=str(base), UBQ_APPLE_GROUP="tests",
                               BUILD_REUSE_TRACE=str(trace), BUILD_REUSE_ENV=str(captured),
                               CC="apple-clang", CXX="apple-clang++", BUILD_JOBS="1")
            environment.pop("UBQ_TESTS_BUILD", None)
            environment.pop("UBQ_HOST_TEST_TREE", None)
            environment.pop("UBIQUITTY_QUIC_PREFIX", None)
            tree = base / "subject/BuildHostTests/ctest"
            driver = (CORE_ROOT / "Scripts/run-tests.sh").read_text()
            start = driver.index("ubq_configure_ctest_tree() {\n")
            configure = driver[start:driver.index("\n}\n", start) + 3]
            configured = subprocess.run(["bash", "-c", configure + '\nROOT="$1"\nubq_configure_ctest_tree "$2"',
                                         "fixture", str(app), str(tree)], cwd=app, env=environment,
                                        capture_output=True, text=True, timeout=20)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            checked = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", self.push_script()],
                                     cwd=app, env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            calls = [json.loads(line) for line in trace.read_text().splitlines()]
            configurations = [call for call in calls if "-S" in call["arguments"]]
            self.assertEqual(len(configurations), 2)
            for call in configurations:
                arguments = call["arguments"]
                self.assertEqual(arguments[arguments.index("-S") + 1], str(app))
                self.assertEqual(arguments[arguments.index("-B") + 1], str(tree))
                self.assertEqual((call["CC"], call["CXX"]), ("apple-clang", "apple-clang++"))
                self.assertIn("-DCMAKE_BUILD_TYPE=Debug", arguments)
                self.assertIn("-DUBIQUITTY_FRONTEND=Core", arguments)
                self.assertIn("-DUBIQUITTY_BUILD_TESTS=ON", arguments)
                self.assertFalse(any("OWNERSHIP_ANALYSIS" in argument or "SANITIZERS" in argument for argument in arguments))
            values = json.loads(captured.read_text())
            self.assertEqual(values, {"UBQ_BUILD_ROOT": str(base / "subject"),
                                      "UBQ_TESTS_BUILD": str(tree), "UBQ_HOST_TEST_TREE": str(tree),
                                      "UBIQUITTY_QUIC_PREFIX": str(base / "quic-deps")})
            spec = importlib.util.spec_from_file_location("reuse_prerequisites", CORE_ROOT / "Scripts/prepush_preflight.py")
            prerequisites = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = prerequisites
            spec.loader.exec_module(prerequisites)
            object_file = tree / "CMakeFiles/core.dir/Source/Core/example.cpp.o"
            object_file.parent.mkdir(parents=True)
            object_file.touch()
            context = prerequisites.Context(build_root=Path(values["UBQ_BUILD_ROOT"]), core_root=CORE_ROOT,
                                             kit_root=KIT_ROOT, subject_root=app, darwin=True, tools=frozenset())
            self.assertTrue(prerequisites.NEEDS["host-test-objects"].present(context))
            context = replace(context, build_root=base)
            self.assertFalse(prerequisites.NEEDS["host-test-objects"].present(context))
            for name in ("check-core-subset-symbols", "check-ownership-analysis-on"):
                spec = importlib.util.spec_from_file_location(name, CORE_ROOT / "Scripts" / (name + ".py"))
                gate = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(gate)
                if name == "check-core-subset-symbols":
                    with patch.dict(os.environ, UBQ_HOST_TEST_TREE=values["UBQ_HOST_TEST_TREE"]):
                        self.assertEqual(gate.objectTree([]), tree)
                else:
                    cache = tree / "CMakeCache.txt"
                    cache.write_text("UBIQUITTY_OWNERSHIP_ANALYSIS:BOOL=ON\n")
                    self.assertEqual(gate.judge([values["UBQ_BUILD_ROOT"]]), ([(tree, "ON")], []))
                    cache.write_text("UBIQUITTY_OWNERSHIP_ANALYSIS:BOOL=OFF\n")
                    self.assertEqual(gate.judge([values["UBQ_BUILD_ROOT"]]), ([], [(tree, "OFF")]))
            # Other groups retain their own native product roots.
            environment["UBQ_APPLE_GROUP"] = "macos"
            checked = subprocess.run(["bash", "-e", "-c", self.push_script()], cwd=app, env=environment,
                                     capture_output=True, text=True, timeout=15)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertEqual(json.loads(captured.read_text()), {"UBQ_BUILD_ROOT": str(base),
                                                               "UBQ_TESTS_BUILD": None, "UBQ_HOST_TEST_TREE": None,
                                                               "UBIQUITTY_QUIC_PREFIX": None})

    def test_compile_census_rejects_the_original_second_test_tree(self):
        script = self.push_script().replace('  export UBQ_BUILD_ROOT="$UBQ_BUILD_ROOT/subject"\n', "")
        with patch.object(self, "push_script", return_value=script), self.assertRaises(AssertionError):
            self.test_apple_tests_reuse_the_batterys_compile_configuration_and_postcheck_inputs()


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
        canonical = {"kit": app / "Libraries/ubiquitty-kit",
                     "core": app / "Libraries/ubiquitty-kit/Libraries/ubiquitty-core"}
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

    def select(self, name, changed, *, expanded=None, status=0, host="Darwin", tier="quick", select_all=False):
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
        script += gate_library_function("ubq_select_all")
        script += self.function(KIT_ROOT / "Scripts/pre-push-gates-kit.sh", "kit_swift_arm_reached")
        script += self.function(ROOT / "Scripts/pre-push-gates.sh", name)
        script += f"\n{name}\nprintf '\\nSKIPS:%s\\n' \"${{SKIPPED[*]-}}\"\n"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(FRAME_DIFF=str(diff), FRAME_EXPANDED=str(logical), FRAME_DIFF_STATUS=str(status),
                           FRAME_HOST=host, TIER=tier, UBQ_CORE_ROOT=str(CORE_ROOT), UBQ_KIT_ROOT=str(KIT_ROOT))
        environment.pop("UBQ_PREPUSH_SELECT", None)
        if select_all:
            environment["UBQ_PREPUSH_SELECT"] = "all"
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

    def test_frame_gate_selects_the_dependency_pin_and_each_existing_path(self):
        for path in ("Libraries/ubiquitty-kit", "Source/Core/Rendering/CellInstance.h",
                     "Source/Platform/macOS/main.swift", "Scripts/cmake/UbiquittyKit.cmake",
                     "Scripts/cmake/AppleSharedSwift.cmake"):
            with self.subTest(path=path):
                self.assertIn("RUN:<core builder frames>", self.select("gate_core_builder_frames", path))

    def test_frame_gate_preserves_unrelated_and_unread_diff_behavior(self):
        for path in ("", "Docs/guide.md", "Libraries/ubiquitty-core", "Libraries/ubiquitty-kit-other"):
            with self.subTest(path=path):
                output = self.select("gate_core_builder_frames", path)
                self.assertNotIn("RUN:", output)
                self.assertIn("none — this branch changes no frame path", output)
        for status in (1, 128):
            with self.subTest(status=status):
                output = self.select("gate_core_builder_frames", "Libraries/ubiquitty-kit", status=status)
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
                self.assertEqual(self.renderer_arms("Libraries/ubiquitty-kit", expanded=self.large_diff(
                    "Source/Core/Terminal.cpp"), tier=tier), ["portable", "linux"])

    def test_renderer_selection_preserves_unrelated_excluded_and_unread_diffs(self):
        for path in ("", "Docs/guide.md", "Source/Platform/macOS/UITest/Scenario.swift",
                     "Libraries/ubiquitty-core-other", "Libraries/ubiquitty-kit-other"):
            with self.subTest(path=path):
                self.assertEqual(self.renderer_arms(path), [])
        for status in (1, 128):
            with self.subTest(status=status):
                self.assertEqual(self.renderer_arms("Libraries/ubiquitty-kit", status=status), [])

    def test_a_run_that_selects_every_gate_takes_every_arm_and_the_frame_gate(self):
        for path, status in (("", 0), ("Docs/guide.md", 0), ("Libraries/ubiquitty-kit", 128)):
            with self.subTest(path=path, status=status):
                self.assertEqual(self.renderer_arms(path, status=status, select_all=True),
                                 ["swift", "portable", "web", "linux"])
                self.assertIn("RUN:<core builder frames>",
                              self.select("gate_core_builder_frames", path, status=status, select_all=True))


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
        for name in ("ci_batteries.py", "gate_framework.py", "gate_report.py", "ubq_roots.py", "build_root.py", "clang-format-pin"):
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
        script += gate_library_function("ubq_select_all") + "\n"
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
        canonical_kit = self.app / "Libraries/ubiquitty-kit"
        canonical_core = canonical_kit / "Libraries/ubiquitty-core"
        shutil.copytree(self.kit, canonical_kit)
        shutil.copytree(self.core, canonical_core)
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

    def test_full_darwin_uses_the_official_battery_for_app_catalogs(self):
        module = Path(self.environment["UBQ_BUILD_ROOT"]) / "web-dist/ubiquitty.wasm"
        module.parent.mkdir(parents=True)
        module.write_bytes(b"fixture")
        checked, calls, result = self.execute("gate_snapshots")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(self.backends(calls), ["macos", "web"])
        self.assert_roots(calls)
        self.assertEqual([call["arguments"] for call in calls if call["tool"] == "build-macos.sh"], [["--no-helpers"]])
        self.assertNotIn("build-core-snapshot.sh", [call["tool"] for call in calls])
        records = list((self.directory / "ci/apple").glob("battery-*.json"))
        self.assertEqual(len(records), 1)
        stages = json.loads(records[0].read_text())
        self.assertEqual([(stage["key"], stage["state"]) for stage in stages],
                         [("snapshots", "completed")])
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
        self.kit = self.app / "Libraries/ubiquitty-kit"
        self.core = self.kit / "Libraries/ubiquitty-core"
        self.output = self.base / "output with spaces '$ literal"
        for directory in (self.app / "Scripts", self.core / "Scripts",
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
