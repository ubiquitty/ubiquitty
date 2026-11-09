#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Runs the packagers' root setup and notice/resource phases without a compiler."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import library_scripts  # noqa: E402

CORE_ROOT = Path(os.environ.get("UBQ_CORE_ROOT") or os.environ.get("UBIQUITTY_CORE_SOURCE_DIR")
                 or library_scripts.CORE_ROOT)
PACKAGERS = ("build-web.sh", "package-macos.sh", "package-linux-appimage.sh")


class PackageNotices(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-package-notices-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.environment = {name: value for name, value in os.environ.items()
                            if not name.startswith("GIT_") and name not in (
                                "UBQ_CORE_ROOT", "UBQ_KIT_ROOT", "UBIQUITTY_CORE_SOURCE_DIR",
                                "UBIQUITTY_KIT_SOURCE_DIR", "UBIQUITTY_PACKAGE_SOURCE")}
        self.environment.update(UBQ_BUILD_ROOT=str(self.directory / "build"),
                                UBQ_CI_LINUX_IMAGE_ID="fixture", UBQ_PGO_LLVM=str(self.directory / "bin"))
        self.app, self.core, self.kit = self.make_checkout("tools")

    def write(self, path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def make_checkout(self, label):
        app = self.directory / label
        kit = app / "Libraries/ubiquitty-kit"
        core = kit / "Libraries/ubiquitty-core"
        dependencies = (
            {"name": f"{label} Core fixture", "noticeRequired": True,
             "noticePath": "Source/ThirdParty/fixture/LICENSE"},
            {"name": f"{label} Kit fixture", "noticeRequired": True,
             "noticePath": "Resources/phosphor/LICENSE"},
            {"name": f"{label} App fixture", "noticeRequired": True,
             "noticePath": "Docs/third-party-licenses/Sparkle-Fixture.txt"},
        )
        for role, owner, inventory in (("app", app, dependencies), ("core", core, dependencies[:1]),
                                       ("kit", kit, dependencies[1:2])):
            self.write(owner / "Scripts/repository.txt", role + "\n")
            for relative in ("LICENSE", "LICENSES/Apache-2.0.txt", "NOTICE", "TRADEMARKS.md",
                             "third-party-notices.md", "Docs/licensing.md"):
                self.write(owner / relative, f"{label} {role} {relative}\n")
            self.write(owner / "Docs/third-party-inventory.json", json.dumps(inventory))
        self.write(core / "Source/Core/Themes/theme-credits.md", f"{label} Core themes\n")
        self.write(core / dependencies[0]["noticePath"], f"{label} Core dependency\n")
        self.write(kit / dependencies[1]["noticePath"], f"{label} Kit dependency\n")
        self.write(app / dependencies[2]["noticePath"], f"{label} App dependency\n")
        for relative in ("Scripts/license_notices.py", "Scripts/build-root.sh", "Scripts/ccache-env.sh"):
            shutil.copyfile(CORE_ROOT / relative, core / relative)
        shutil.copyfile(ROOT / "Scripts/library-scripts.sh", app / "Scripts/library-scripts.sh")
        return app, core, kit

    def caller_prefix(self, name):
        lines = (ROOT / "Scripts" / name).read_text().splitlines()
        # Keep the actual setup, including the tagged-source override and both
        # library selections. Stop before any build, signature or archive work.
        end = lines.index('. "$CORE_ROOT/Scripts/build-root.sh"')
        return "\n".join(lines[:end + 1]) + "\n"

    def notice_commands(self, name):
        commands = []
        for line in (ROOT / "Scripts" / name).read_text().splitlines():
            if "license_notices.py\"" not in line:
                continue
            if line.startswith("if ! ") and line.endswith("; then"):
                line = line[len("if ! "):-len("; then")]
            self.assertTrue(line.startswith("python3 "), line)
            commands.append(line)
        self.assertEqual(len(commands), 2 if name == "build-web.sh" else 1)
        return commands

    def run_phase(self, name, commands, environment=None):
        script = self.app / "Scripts" / name
        self.write(script, self.caller_prefix(name) + "\n".join(commands) + "\n")
        return subprocess.run(["bash", str(script)], cwd=self.app,
                              env=environment or self.environment, text=True, capture_output=True, timeout=20)

    def check_notices(self, name, selected_app, selected_core, selected_kit, environment):
        stage = self.directory / f"stage-{name}"
        environment = dict(environment, STAGE=str(stage), DOCDIR=str(stage))
        checked = self.run_phase(name, self.notice_commands(name), environment)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        destination = stage / "licenses" if name == "build-web.sh" else stage
        for relative, source in (
            ("NOTICE", selected_app / "NOTICE"),
            ("Source/ThirdParty/fixture/LICENSE", selected_core / "Source/ThirdParty/fixture/LICENSE"),
            ("Resources/phosphor/LICENSE", selected_kit / "Resources/phosphor/LICENSE"),
            ("Libraries/ubiquitty-core/NOTICE", selected_core / "NOTICE"),
            ("Libraries/ubiquitty-kit/NOTICE", selected_kit / "NOTICE"),
            ("Libraries/ubiquitty-kit/Libraries/ubiquitty-core/NOTICE", selected_core / "NOTICE"),
        ):
            self.assertEqual((destination / relative).read_bytes(), source.read_bytes(), relative)
        return destination

    def test_all_callers_copy_the_complete_canonical_and_external_notice_graph(self):
        _, external_core, external_kit = self.make_checkout("external")
        for name in PACKAGERS:
            for external in (False, True):
                with self.subTest(packager=name, external=external):
                    environment = self.environment.copy()
                    core, kit = self.core, self.kit
                    if external:
                        core, kit = external_core, external_kit
                        environment.update(UBIQUITTY_CORE_SOURCE_DIR=str(core),
                                           UBIQUITTY_KIT_SOURCE_DIR=str(kit))
                    self.check_notices(name, self.app, core, kit, environment)

    def test_appimage_uses_the_tagged_subject_and_its_dependencies(self):
        app, core, kit = self.make_checkout("tagged-package")
        # Current packaging tools interpret the tagged inventories; executing
        # an older collector from the package would lose that separation.
        self.write(core / "Scripts/license_notices.py", "raise SystemExit('package collector must not run')\n")
        _, external_core, external_kit = self.make_checkout("external-package")
        self.write(external_core / "Scripts/license_notices.py",
                   "raise SystemExit('external package collector must not run')\n")
        for external in (False, True):
            with self.subTest(external=external):
                environment = dict(self.environment, UBIQUITTY_PACKAGE_SOURCE=str(app))
                selected_core, selected_kit = core, kit
                if external:
                    selected_core, selected_kit = external_core, external_kit
                    environment.update(UBIQUITTY_CORE_SOURCE_DIR=str(selected_core),
                                       UBIQUITTY_KIT_SOURCE_DIR=str(selected_kit))
                self.check_notices("package-linux-appimage.sh", app, selected_core, selected_kit, environment)

    def test_web_verification_refuses_a_missing_kit_notice(self):
        destination = self.check_notices("build-web.sh", self.app, self.core, self.kit, self.environment)
        (destination / "Resources/phosphor/LICENSE").unlink()
        checked = self.run_phase("build-web.sh", self.notice_commands("build-web.sh")[1:],
                                 dict(self.environment, STAGE=str(destination.parent)))
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("missing Resources/phosphor/LICENSE", checked.stderr)

    def test_appimage_bootstrap_uses_the_tools_core_without_changing_the_package_source(self):
        package, package_core, _ = self.make_checkout("tagged-package")
        report = self.directory / "bootstrap.json"
        self.write(self.core / "Scripts/pgo_toolchain.py",
                   "import json, os, pathlib, sys\n"
                   "pathlib.Path(os.environ['BOOTSTRAP_REPORT']).write_text(json.dumps({"
                   "'owner': __file__, 'argv': sys.argv[1:], 'source': os.environ['UBIQUITTY_PACKAGE_SOURCE'],"
                   "'pgo': os.environ['UBIQUITTY_PGO']}))\n")
        self.write(package_core / "Scripts/pgo_toolchain.py", "raise SystemExit('package launcher must not run')\n")
        prefix = self.caller_prefix("package-linux-appimage.sh")
        script = self.app / "Scripts/package-linux-appimage.sh"
        self.write(script, prefix)
        environment = dict(self.environment, UBIQUITTY_PACKAGE_SOURCE=str(package), BOOTSTRAP_REPORT=str(report))
        environment.pop("UBQ_CI_LINUX_IMAGE_ID")
        for external in (False, True):
            with self.subTest(external_package_core=external):
                selected_environment = environment.copy()
                if external:
                    selected_environment["UBIQUITTY_CORE_SOURCE_DIR"] = str(package_core)
                checked = subprocess.run(["bash", str(script), "--no-build", "0.3.5"], cwd=self.app,
                                         env=selected_environment, text=True, capture_output=True, timeout=20)
                self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                self.assertEqual(json.loads(report.read_text()), {
                    "owner": str(self.core / "Scripts/pgo_toolchain.py"),
                    "argv": ["run", str(script), "--no-build", "0.3.5"],
                    "source": str(package), "pgo": "REQUIRE"})

    def test_appimage_checks_kit_shaders_and_carries_core_font_notices(self):
        shader = self.kit / "Source/Platform/Linux/shaders/fixture.comp"
        self.write(shader, "shader fixture\n")
        appdir = self.directory / "AppDir"
        compiled = appdir / "usr/bin/fixture.comp.spv"
        self.write(compiled, "compiled fixture\n")
        for notice in ("NotoSans-OFL.txt", "NotoColorEmoji-OFL.txt"):
            self.write(self.core / "Resources/fonts" / notice, f"Core {notice}\n")
        installer = self.directory / "bin/install"
        self.write(installer, f"#!{sys.executable}\nimport pathlib, shutil, sys\n"
                   "assert sys.argv[1] == '-Dm644'\n"
                   "target = pathlib.Path(sys.argv[3])\n"
                   "target.parent.mkdir(parents=True, exist_ok=True)\n"
                   "shutil.copyfile(sys.argv[2], target)\n")
        installer.chmod(0o755)
        source = (ROOT / "Scripts/package-linux-appimage.sh").read_text()
        start = source.index("missingShaders=()\n")
        end = source.index("# The updater uses", start)
        environment = dict(self.environment, APPDIR=str(appdir),
                           PATH=str(installer.parent) + os.pathsep + self.environment["PATH"])
        checked = self.run_phase("package-linux-appimage.sh", [source[start:end]], environment)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        for notice in ("NotoSans-OFL.txt", "NotoColorEmoji-OFL.txt"):
            self.assertEqual((appdir / "usr/bin" / notice).read_bytes(),
                             (self.core / "Resources/fonts" / notice).read_bytes())
        compiled.unlink()
        checked = self.run_phase("package-linux-appimage.sh", [source[start:end]], environment)
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("fixture.comp.spv", checked.stderr)


if __name__ == "__main__":
    unittest.main()
