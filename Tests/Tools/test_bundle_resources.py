#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Builds Apple bundles at the project's CMake policy floor to verify resource staging."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Apple bundle builds require macOS")
class BundleResources(unittest.TestCase):
    def runCommand(self, *arguments):
        result = subprocess.run(arguments, capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def checkBundle(self, generator, platform, *, mixedSources=False, dropNotice=False, framework=False, layout=False):
        for command in ("cmake", "xcrun", "ninja"):
            if shutil.which(command) is None:
                self.skipTest(f"{command} is unavailable")
        self.environment = {**os.environ, "CMAKE_BUILD_PARALLEL_LEVEL": "1"}
        self.environment.pop("SDKROOT", None)
        sdk = "iphonesimulator" if platform == "iOS" else "macosx"
        sdkPath = self.runCommand("xcrun", "--sdk", sdk, "--show-sdk-path")
        with tempfile.TemporaryDirectory(prefix="ubq bundle ") as temporary:
            source = Path(temporary) / "source"
            build = Path(temporary) / "build"
            source.mkdir()
            (source / "Docs").mkdir()
            noticeNames = ("LICENSE", "LICENSES/Apache-2.0.txt", "NOTICE",
                           "TRADEMARKS.md", "third-party-notices.md",
                           "Docs/licensing.md", "Source/Core/Themes/theme-credits.md",
                           "Resources/fonts/font-OFL.txt", "Source/ThirdParty/vendor/LICENSE")
            for name in noticeNames:
                (source / name).parent.mkdir(parents=True, exist_ok=True)
                (source / name).write_text(f"fixture {name}\n")
            (source / "Docs/third-party-inventory.json").write_text(json.dumps([
                {"name": "fixture", "noticeRequired": True,
                 "noticePath": "Resources/fonts/font-OFL.txt; Source/ThirdParty/vendor/LICENSE"}
            ]))
            font = source / "SymbolsNerdFontMono-Regular.ttf"
            shutil.copyfile(ROOT / "Resources/fonts" / font.name, font)
            bracketed = source / "font [weight].ttf"
            bracketed.write_bytes(b"font resource fixture")
            icon = source / "icon.png"
            icon.write_bytes(bytes.fromhex(
                "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                "0000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
            (source / "main.swift").write_text(
                "public func bundleFixtureValue() -> Int { 1 }\n" if framework else 'print("bundle fixture")\n')
            (source / "support.cpp").write_text('int bundleFixtureValue() { return 1; }\n')
            # Post-build commands run in the order they were added, so this
            # removal lands after staging and before the notice check: the
            # bundle the check sees is one whose staging lost a notice.
            noticeDirectory = "/Licenses" if platform == "iOS" else "/Resources"
            dropStep = (
                "add_custom_command(TARGET BundleFixture POST_BUILD COMMAND ${CMAKE_COMMAND} -E rm -f "
                f'"$<TARGET_BUNDLE_CONTENT_DIR:BundleFixture>{noticeDirectory}/NOTICE")\n'
                if dropNotice else "")
            # The framework's own layout step, after every step that writes
            # into the bundle as in the framework's build. The interface it
            # copies into Modules is a stand-in.
            layoutStep = (
                "add_custom_command(TARGET BundleFixture POST_BUILD COMMAND ${CMAKE_COMMAND} "
                '"-DUBIQUITTY_FRAMEWORK=$<TARGET_BUNDLE_DIR:BundleFixture>" -DUBIQUITTY_FRAMEWORK_VERSION=A '
                '"-DUBIQUITTY_FRAMEWORK_INTERFACE=${CMAKE_SOURCE_DIR}/main.swift" '
                "-DUBIQUITTY_FRAMEWORK_INTERFACE_NAME=fixture.swiftinterface "
                f'-P "{ROOT}/cmake/FrameworkBundleLayout.cmake" VERBATIM)\n'
                if layout else "")
            languages = "CXX Swift" if mixedSources else "Swift"
            sources = "main.swift support.cpp" if mixedSources else "main.swift"
            if framework:
                declaration = f"""add_library(BundleFixture SHARED {sources})
set_target_properties(BundleFixture PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER "org.ubiquitty.bundle-fixture"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)"""
            else:
                declaration = f"""add_executable(BundleFixture MACOSX_BUNDLE {sources})
set_target_properties(BundleFixture PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.ubiquitty.bundle-fixture"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)"""
            (source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.13)
project(BundleFixture LANGUAGES {languages})
include("{ROOT}/cmake/LicenseNotices.cmake")
{declaration}
{dropStep}ubiquitty_bundle_license_notices(BundleFixture)
ubiquitty_bundle_resources(BundleFixture "fonts"
    "${{CMAKE_SOURCE_DIR}}/{font.name}"
    "${{CMAKE_SOURCE_DIR}}/{bracketed.name}")
ubiquitty_bundle_resources(BundleFixture "" "${{CMAKE_SOURCE_DIR}}/{icon.name}")
{layoutStep}file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/bundle-$<CONFIG>.txt"
    CONTENT "$<TARGET_BUNDLE_DIR:BundleFixture>")
''')
            configure = ["cmake", "-S", str(source), "-B", str(build), "-G", generator,
                         f"-DCMAKE_OSX_SYSROOT={sdkPath}", "-DCMAKE_BUILD_TYPE=Debug",
                         "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO",
                         "-DCMAKE_Swift_FLAGS=-j 1 -num-threads 1"]
            if platform == "iOS":
                configure += ["-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0",
                              "-DCMAKE_OSX_ARCHITECTURES=arm64"]
                if generator == "Ninja":
                    configure += ["-DCMAKE_Swift_FLAGS=-j 1 -num-threads 1 -target arm64-apple-ios26.0-simulator"]
            self.runCommand(*configure)
            command = ("cmake", "--build", str(build), "--config", "Debug", "--target", "BundleFixture", "--parallel", "1")
            if dropNotice:
                result = subprocess.run(command, capture_output=True, text=True, env=self.environment)
                self.assertNotEqual(result.returncode, 0, "a bundle without its NOTICE built cleanly")
                self.assertIn("missing NOTICE", result.stdout + result.stderr)
                return
            self.runCommand(*command)
            bundlePath = (build / "bundle-Debug.txt").read_text()
            bundle = Path(bundlePath.replace("${EFFECTIVE_PLATFORM_NAME}", "-iphonesimulator" if platform == "iOS" else ""))
            if platform == "iOS":
                resources = bundle
            elif framework:
                resources = bundle / "Versions/A/Resources"
            else:
                resources = bundle / "Contents/Resources"
            noticeResources = resources / "Licenses" if platform == "iOS" else resources
            if layout:
                # CMake writes the framework's Info.plist when it generates the
                # build and never again, so a bundle deleted and rebuilt comes
                # out without one, which codesign cannot seal in a host.
                self.assertEqual(sorted(entry.name for entry in bundle.iterdir()),
                                 ["BundleFixture", "Modules", "Resources", "Versions"])
                self.assertTrue((resources / "Info.plist").is_file())
                shutil.rmtree(bundle)
                result = subprocess.run(command, capture_output=True, text=True, env=self.environment)
                self.assertNotEqual(result.returncode, 0, "a framework without its Info.plist built cleanly")
                self.assertIn("no Info.plist", result.stdout + result.stderr)
                return
            if platform == "iOS":
                # A root Resources directory changes codesign's interpretation
                # of a shallow bundle: sibling assets become nested code.
                self.runCommand("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle))
                self.runCommand("/usr/bin/codesign", "--verify", "--strict", str(bundle))
                self.assertFalse((bundle / "Resources").exists())
            for name in (*noticeNames, "Docs/third-party-inventory.json"):
                self.assertEqual((noticeResources / name).read_bytes(), (source / name).read_bytes())
            self.assertEqual((resources / icon.name).read_bytes(), icon.read_bytes())
            for resource in (font, bracketed):
                self.assertEqual((resources / "fonts" / resource.name).read_bytes(), resource.read_bytes())

            (source / "NOTICE").write_text("changed resource without source compilation\n")
            self.runCommand(*command)
            self.assertEqual((noticeResources / "NOTICE").read_bytes(), (source / "NOTICE").read_bytes())
            if framework:
                # Staged into the version directory itself, never through the
                # root's link: with the link gone, a rebuild leaves the root
                # without a Resources directory codesign would refuse.
                self.assertTrue((bundle / "Resources").is_symlink())
                (bundle / "Resources").unlink()
                (resources / "NOTICE").unlink()
                self.runCommand(*command)
                self.assertFalse((bundle / "Resources").exists() or (bundle / "Resources").is_symlink())
                self.assertEqual((resources / "NOTICE").read_bytes(), (source / "NOTICE").read_bytes())
            if generator == "Ninja":
                if platform == "iOS":
                    executable = bundle / "BundleFixture"
                elif framework:
                    executable = bundle / "Versions/A/BundleFixture"
                else:
                    executable = bundle / "Contents/MacOS/BundleFixture"
                modificationTime = executable.stat().st_mtime_ns
                (resources / "fonts" / font.name).unlink()
                self.runCommand(*command)
                self.assertEqual((resources / "fonts" / font.name).read_bytes(), font.read_bytes())
                self.assertEqual(executable.stat().st_mtime_ns, modificationTime)

    def configureWholeDirectoryFixture(self, temporary, extraStaging=""):
        """Writes and configures a framework staging an icons directory whole.

        - Parameters:
          - temporary: The directory the source and build trees go in.
          - extraStaging: CMake appended after the whole staging.
        - Returns: The source's icons directory, the build tree, and whether
          the configure succeeded with its output.
        """
        for command in ("cmake", "xcrun", "ninja"):
            if shutil.which(command) is None:
                self.skipTest(f"{command} is unavailable")
        self.environment = {**os.environ, "CMAKE_BUILD_PARALLEL_LEVEL": "1"}
        self.environment.pop("SDKROOT", None)
        sdkPath = self.runCommand("xcrun", "--sdk", "macosx", "--show-sdk-path")
        source = Path(temporary) / "source"
        build = Path(temporary) / "build"
        icons = source / "icons"
        icons.mkdir(parents=True)
        for name in ("kept.svg", "dropped.svg", "glyph [wght].ttf"):
            (icons / name).write_text(f"fixture {name}\n")
        (source / "main.swift").write_text("public func bundleFixtureValue() -> Int { 1 }\n")
        (source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.13)
project(BundleFixture LANGUAGES Swift)
include("{ROOT}/cmake/BundleResources.cmake")
add_library(BundleFixture SHARED main.swift)
set_target_properties(BundleFixture PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER "org.ubiquitty.bundle-fixture")
file(GLOB icons CONFIGURE_DEPENDS "${{CMAKE_SOURCE_DIR}}/icons/*")
ubiquitty_bundle_resource_directory(BundleFixture "icons" ${{icons}})
{extraStaging}
file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/bundle.txt" CONTENT "$<TARGET_BUNDLE_DIR:BundleFixture>")
''')
        result = subprocess.run(
            ["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
             f"-DCMAKE_OSX_SYSROOT={sdkPath}", "-DCMAKE_BUILD_TYPE=Debug",
             "-DCMAKE_Swift_FLAGS=-j 1 -num-threads 1"],
            capture_output=True, text=True, env=self.environment)
        return icons, build, result

    def testWholeResourceDirectoryHoldsOnlyWhatTheTreeHas(self):
        with tempfile.TemporaryDirectory(prefix="ubq bundle ") as temporary:
            icons, build, configured = self.configureWholeDirectoryFixture(temporary)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            command = ("cmake", "--build", str(build), "--target", "BundleFixture", "--parallel", "1")
            self.runCommand(*command)
            staged = Path((build / "bundle.txt").read_text()) / "Versions/A/Resources/icons"
            self.assertEqual(sorted(entry.name for entry in staged.iterdir()),
                             ["dropped.svg", "glyph [wght].ttf", "kept.svg"])
            # An incremental build after the tree drops a file, with a file an
            # earlier copy left beside the rest, keeps neither.
            (icons / "dropped.svg").unlink()
            (staged / "left-behind.svg").write_text("an earlier copy\n")
            self.runCommand(*command)
            self.assertEqual(sorted(entry.name for entry in staged.iterdir()), ["glyph [wght].ttf", "kept.svg"])
            for entry in staged.iterdir():
                self.assertEqual(entry.read_bytes(), (icons / entry.name).read_bytes())

    def testWholeResourceDirectoryIsStagedOnce(self):
        with tempfile.TemporaryDirectory(prefix="ubq bundle ") as temporary:
            _, _, configured = self.configureWholeDirectoryFixture(
                temporary, 'ubiquitty_bundle_resources(BundleFixture "icons" "${CMAKE_SOURCE_DIR}/main.swift")')
            self.assertNotEqual(configured.returncode, 0, "a directory staged whole was staged into again")
            # CMake wraps an error's text, so the words are compared unwrapped.
            output = " ".join((configured.stdout + configured.stderr).split())
            self.assertIn("stages the resource directory 'icons' twice, and one staging holds it whole", output)

    def testMacOSNinja(self):
        self.checkBundle("Ninja", "macOS")

    def testMacOSMixedNinja(self):
        self.checkBundle("Ninja", "macOS", mixedSources=True)

    def testMacOSFrameworkNinja(self):
        self.checkBundle("Ninja", "macOS", framework=True)

    def testMacOSFrameworkLayoutRefusesABundleWithoutItsInfoPlist(self):
        self.checkBundle("Ninja", "macOS", framework=True, layout=True)

    def testIOSNinja(self):
        self.checkBundle("Ninja", "iOS")

    def testIOSMixedNinja(self):
        self.checkBundle("Ninja", "iOS", mixedSources=True)

    def testIOSNinjaRefusesABundleMissingANotice(self):
        self.checkBundle("Ninja", "iOS", dropNotice=True)

    def testIOSXcodeRefusesABundleMissingANotice(self):
        self.checkBundle("Xcode", "iOS", dropNotice=True)

    def testMacOSNinjaRefusesABundleMissingANotice(self):
        self.checkBundle("Ninja", "macOS", dropNotice=True)

    def testMacOSXcode(self):
        self.checkBundle("Xcode", "macOS")

    def testIOSXcode(self):
        self.checkBundle("Xcode", "iOS")


if __name__ == "__main__":
    unittest.main()
