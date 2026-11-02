#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-xcode-workspace — the generated Xcode projects can be built for what Xcode offers.

`Scripts/generate-xcode-workspace.sh` writes one Xcode project per frontend and
the "Xcode workspace generates" gate proves only that CMake can write them.
Two failures can sit behind a green generate, and each shows only to a person
pressing Build:

* The iOS app cannot be built for a phone from a project that carries
  `SDKROOT = iphonesimulator`. Xcode reads that as "these targets support the
  simulator and nothing else", so under the scheme the workspace shows, a
  device is not a valid destination and Xcode says the targets' SDKs are at
  fault. A project with its SDK's own directory spelled into its link line and
  commands can only link the wrong archives when built for the other SDK.

* The Debug configuration does not compile when the Swift targets are
  whole-module in the optimised configurations and incremental in Debug: a
  member whose signature names an imported C++ type does not survive an
  incremental compile on either side of an import. The importer fails with
  "value of type ... has no member ..." on a member that is public in the
  source, and nothing points at the mode. It is the importer's mode as much as
  the emitter's: with the two kits whole-module and the app incremental, the
  app fails instead.

An archive of the iOS app is what reaches App Store Connect, which reads the app
from the archive's Products/Applications and refuses an archive that installs
anything else: Xcode calls that a generic archive. Where each product goes is
again a setting of the generated project. So is what the archive's Release
configuration is built with, and a TestFlight build is the build that ships: it
has the link-time optimization and the training profile the Ninja Release build
has, and keeps its debug information as a dSYM, written where the archive
gathers it and free of references dsymutil cannot follow.

Each of these is a property of the generated project, readable without building
it, so this reads them: the base SDK and supported platforms of every project,
that an iOS project names no SDK of its own anywhere, that it has the scheme the
docs name, that an archive installs its app into Applications and no other
target anywhere, that its Release configuration is optimized, profiled and
symbolicated as above, and that every Swift target using C++ interop is
whole-module in every configuration and agrees with its neighbours on the flags
that decide how the C++ module is seen.

    python3 Scripts/check-xcode-workspace.py                 the checkout's workspace
    python3 Scripts/check-xcode-workspace.py --workspace W   another one
    python3 Scripts/check-xcode-workspace.py --ask-xcode     also ask xcodebuild which
                                                             destinations each iOS scheme has
    python3 Scripts/check-xcode-workspace.py --self-test

What this does not establish: that the projects compile, or that an archive
uploads. It holds the properties whose absence made them unbuildable or their
archive unusable; a source error is the build's to find.

Stdlib only. Reading a project needs `plutil`, so the check itself is a macOS
one; the self-test runs anywhere.
"""

import json
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ElementTree

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "check-xcode-workspace"

IOS_PLATFORMS = ("iphoneos", "iphonesimulator")

STATIC_LIBRARY_PRODUCT_TYPE = "com.apple.product-type.library.static"
APPLICATION_PRODUCT_TYPE = "com.apple.product-type.application"

# One SDK's own name or path inside a project that is built for two. Each is a
# value that is right for one destination and wrong for the other, and the
# first is also wrong for both after an Xcode update renames the directory.
SDK_BOUND = (
    (re.compile(r"/SDKs/[A-Za-z]+[0-9.]*\.sdk"), "an SDK's resolved path"),
    (re.compile(r"iPhone(?:OS|Simulator)\.platform"), "a platform's directory"),
    (re.compile(r"/iphone(?:os|simulator)(?:/|$)"), "a directory named for one SDK"),
    (re.compile(r"apple-ios[0-9.]*-simulator"), "the simulator's triple"),
    (re.compile(r"-m(?:ios-simulator|iphoneos)-version-min"), "one SDK's minimum-version flag"),
)

WHOLE_MODULE_FLAGS = ("-wmo", "-whole-module-optimization")

# Where an archive may install the app: the archive's Products/Applications.
APPLICATION_INSTALL_PATHS = ("$(LOCAL_APPS_DIR)", "/Applications")

# The configuration an archive builds, and what it must carry for the build App
# Store Connect receives to be the build that ships: link-time optimization and
# the training profile wherever C or C++ is compiled, and debug information kept
# as a dSYM for every product, which is what a TestFlight crash is symbolicated
# from.
ARCHIVE_CONFIGURATION = "Release"
LINK_TIME_OPTIMIZATION_VALUES = ("YES", "YES_THIN")
PROFILE_FLAG = "-fprofile-use="
C_FAMILY_SOURCE_SUFFIXES = ("c", "cc", "cpp", "cxx", "m", "mm")

# Where an archive gathers dSYMs from: the build products folder Xcode would
# choose. A linked product whose dSYM is written anywhere else is archived
# without one, and so is one whose CONFIGURATION_BUILD_DIR points elsewhere and
# whose dSYM follows it there by default.
ARCHIVE_DSYM_FOLDER = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"

# Swift's breadcrumbs name the explicitly built clang module files, which
# dsymutil cannot find when an archive runs it, and it warns once for each.
NO_BREADCRUMBS_FLAG = "-no-clang-module-breadcrumbs"


def flattened(value):
    """One build setting as a single string, whichever shape the project gave it.

    - Parameter value: A string, or a list of strings.
    - Returns: The value as one space-joined string.
    """
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value)


def swiftFlags(settings):
    """The words of a configuration's Swift flags.

    - Parameter settings: One configuration's build settings.
    - Returns: A list of arguments, without the inheritance marker.
    """
    try:
        words = shlex.split(flattened(settings.get("OTHER_SWIFT_FLAGS", "")))
    except ValueError:
        words = flattened(settings.get("OTHER_SWIFT_FLAGS", "")).split()
    return [word for word in words if word != "$(inherited)"]


def interopView(flags):
    """What decides how a Swift module sees the C++ it imports.

    Two modules that differ here import two different C++ modules under one
    name, and a type one of them serialized is not a type the other can find.

    - Parameter flags: A target's Swift arguments.
    - Returns: A sorted tuple of the deciding arguments, or None when the
      target does not use C++ interop at all.
    """
    view = []
    usesInterop = False
    index = 0
    while index < len(flags):
        flag = flags[index]
        following = flags[index + 1] if index + 1 < len(flags) else ""
        if flag.startswith("-cxx-interoperability-mode"):
            usesInterop = True
            view.append(flag)
        elif flag == "-package-name":
            view.append(f"-package-name {following}")
            index += 1
        elif flag == "-Xcc":
            # Module maps name what is imported, not how; a target that
            # imports one more module than its neighbour is not thereby
            # seeing the shared ones differently.
            if not following.startswith("-fmodule-map-file"):
                view.append(f"-Xcc {following}")
            index += 1
        index += 1
    return tuple(sorted(view)) if usesInterop else None


def problemsForProject(project):
    """Every reason one generated project cannot be built for what Xcode offers.

    Takes the project as plain data rather than reading it, so the self-test
    can plant each failure and watch this find it.

    - Parameter project: A dict with `name`, `settings` (configuration name to
      project-level settings), `targets` (each with `name`, `productType`,
      `settings` by configuration, `scripts`, and `sources`, the suffixes of
      the files it compiles), and `schemes` (scheme name to the target names
      it builds).
    - Returns: A list of one line per problem, empty when there is none.
    """
    problems = []
    name = project["name"]
    configurations = sorted(project["settings"])
    baseSDKs = {flattened(project["settings"][c].get("SDKROOT", "")) for c in configurations}

    isIOS = any("iphone" in sdk.lower() for sdk in baseSDKs)
    for sdk in sorted(baseSDKs):
        if "/" in sdk:
            problems.append(
                f"    {name}: SDKROOT is the path {sdk} — a path names one version of one SDK, "
                "and stops existing at the next Xcode update")
    for target in project["targets"]:
        for configuration, settings in sorted(target["settings"].items()):
            if "SDKROOT" in settings:
                problems.append(
                    f"    {name}: target {target['name']} ({configuration}) overrides SDKROOT with "
                    f"{flattened(settings['SDKROOT'])}, so it is built for that SDK whatever the destination")

    if isIOS:
        if baseSDKs != {"iphoneos"}:
            problems.append(
                f"    {name}: SDKROOT is {', '.join(sorted(baseSDKs)) or 'unset'}, not iphoneos — "
                "Xcode derives the simulator from iphoneos and nothing from iphonesimulator, "
                "so no device is a valid destination for this project's schemes")
        for configuration in configurations:
            supported = flattened(project["settings"][configuration].get("SUPPORTED_PLATFORMS", "")).split()
            missing = [platform for platform in IOS_PLATFORMS if platform not in supported]
            if missing:
                problems.append(
                    f"    {name} ({configuration}): SUPPORTED_PLATFORMS is "
                    f"'{' '.join(supported)}' and lacks {', '.join(missing)}")
        problems.extend(sdkBoundValues(project))
        problems.extend(archiveProblems(project, configurations))
        problems.extend(releaseProblems(project))
        applications = {target["name"] for target in project["targets"]
                        if target["productType"] == APPLICATION_PRODUCT_TYPE}
        if not any(applications & set(built) for built in project["schemes"].values()):
            problems.append(
                f"    {name}: no shared scheme builds the app "
                f"({', '.join(sorted(applications)) or 'no application target'}), so what "
                "the workspace offers is whatever Xcode invents from the target list")
    else:
        for configuration in configurations:
            supported = flattened(project["settings"][configuration].get("SUPPORTED_PLATFORMS", "")).split()
            foreign = [platform for platform in supported if platform.startswith("iphone")]
            if foreign:
                problems.append(
                    f"    {name} ({configuration}): a macOS project supports {', '.join(foreign)}, "
                    "so its schemes are offered a phone they cannot be built for")

    problems.extend(swiftModuleProblems(project, configurations))
    return problems


def sdkBoundValues(project):
    """Where an iOS project spells one SDK into something built for both.

    - Parameter project: The project, as `problemsForProject` takes it.
    - Returns: A list of one line per value, without repeats.
    """
    problems = []
    seen = set()

    def examine(where, text):
        for pattern, what in SDK_BOUND:
            match = pattern.search(text)
            if match and (where, what) not in seen:
                seen.add((where, what))
                problems.append(
                    f"    {project['name']}: {where} carries {what} ({match.group(0)}) — right for "
                    "one destination and wrong for the other; spell it with $(PLATFORM_NAME) or $(SDKROOT)")

    for configuration, settings in sorted(project["settings"].items()):
        for key, value in sorted(settings.items()):
            examine(f"project setting {key}", flattened(value))
    for target in project["targets"]:
        for configuration, settings in sorted(target["settings"].items()):
            for key, value in sorted(settings.items()):
                examine(f"target {target['name']} setting {key}", flattened(value))
        for script in target.get("scripts", ()):
            examine(f"target {target['name']} script phase", script)
    return problems


def archiveProblems(project, configurations):
    """Products an archive of an iOS project puts where App Store Connect cannot take them.

    A target's setting is read before the project's, and `SKIP_INSTALL` is
    `NO` where neither has one. An aggregate target has no product to install.

    - Parameter project: The project, as `problemsForProject` takes it.
    - Parameter configurations: The project's configuration names.
    - Returns: A list of one line per problem.
    """
    problems = []
    name = project["name"]
    for configuration in configurations:
        projectSettings = project["settings"][configuration]
        for target in project["targets"]:
            if not target["productType"]:
                continue
            settings = target["settings"].get(configuration, {})
            skipped = flattened(settings.get(
                "SKIP_INSTALL", projectSettings.get("SKIP_INSTALL", "NO"))).upper() == "YES"
            if target["productType"] == APPLICATION_PRODUCT_TYPE:
                installPath = flattened(settings.get("INSTALL_PATH", projectSettings.get("INSTALL_PATH", "")))
                if skipped:
                    problems.append(
                        f"    {name} ({configuration}): an archive skips installing the app {target['name']} "
                        "(SKIP_INSTALL is YES), so its Products holds no app for App Store Connect")
                elif installPath not in APPLICATION_INSTALL_PATHS:
                    problems.append(
                        f"    {name} ({configuration}): an archive does not install the app {target['name']} "
                        f"in Products/Applications (INSTALL_PATH is '{installPath}')")
            elif not skipped:
                problems.append(
                    f"    {name} ({configuration}): nothing keeps {target['name']} out of an archive "
                    "(SKIP_INSTALL is not YES), and an archive holding anything beside the app is a "
                    "generic archive, which App Store Connect refuses")
    return problems


def releaseProblems(project):
    """What an iOS project's Release configuration lacks of the build that ships.

    - Parameter project: The project, as `problemsForProject` takes it.
    - Returns: A list of one line per problem.
    """
    name = project["name"]
    if ARCHIVE_CONFIGURATION not in project["settings"]:
        return [f"    {name}: no {ARCHIVE_CONFIGURATION} configuration for an archive to build"]
    problems = []
    projectSettings = project["settings"][ARCHIVE_CONFIGURATION]
    for target in project["targets"]:
        if not target["productType"]:
            continue
        settings = target["settings"].get(ARCHIVE_CONFIGURATION, {})

        def setting(key):
            return flattened(settings.get(key, projectSettings.get(key, "")))

        where = f"    {name} ({ARCHIVE_CONFIGURATION}): {target['name']}"
        if setting("GCC_GENERATE_DEBUGGING_SYMBOLS").upper() != "YES":
            problems.append(f"{where} is built without debug information (GCC_GENERATE_DEBUGGING_SYMBOLS)")
        if setting("DEBUG_INFORMATION_FORMAT") != "dwarf-with-dsym":
            problems.append(f"{where} keeps no dSYM (DEBUG_INFORMATION_FORMAT is "
                            f"'{setting('DEBUG_INFORMATION_FORMAT')}')")
        if target["productType"] != STATIC_LIBRARY_PRODUCT_TYPE:
            folder = setting("DWARF_DSYM_FOLDER_PATH") or setting("CONFIGURATION_BUILD_DIR")
            if folder not in ("", ARCHIVE_DSYM_FOLDER):
                problems.append(f"{where} writes its dSYM to '{folder}', where an archive does not gather "
                                f"it; DWARF_DSYM_FOLDER_PATH needs to be {ARCHIVE_DSYM_FOLDER}")
        sources = target.get("sources", ())
        if "swift" in sources and NO_BREADCRUMBS_FLAG not in setting("OTHER_SWIFT_FLAGS"):
            problems.append(f"{where} compiles Swift with clang module breadcrumbs, which dsymutil "
                            f"warns about in an archive ({NO_BREADCRUMBS_FLAG})")
        if not any(suffix in C_FAMILY_SOURCE_SUFFIXES for suffix in sources):
            continue
        if setting("LLVM_LTO").upper() not in LINK_TIME_OPTIMIZATION_VALUES:
            problems.append(f"{where} compiles C or C++ without link-time optimization (LLVM_LTO is "
                            f"'{setting('LLVM_LTO')}')")
        if PROFILE_FLAG not in setting("OTHER_CFLAGS") + " " + setting("OTHER_CPLUSPLUSFLAGS"):
            problems.append(f"{where} compiles C or C++ without the training profile ({PROFILE_FLAG})")
    return problems


def swiftModuleProblems(project, configurations):
    """C++-interop Swift targets that are not whole-module, or disagree.

    - Parameter project: The project, as `problemsForProject` takes it.
    - Parameter configurations: The project's configuration names.
    - Returns: A list of one line per problem.
    """
    problems = []
    name = project["name"]
    for configuration in configurations:
        projectSettings = project["settings"][configuration]
        views = {}
        for target in project["targets"]:
            settings = target["settings"].get(configuration, {})
            if "OTHER_SWIFT_FLAGS" not in settings:
                continue
            flags = swiftFlags(settings)
            view = interopView(flags)
            if view is None:
                continue
            views[target["name"]] = view
            # Every such target, the application included. The loss happens on
            # the importing side as well as the emitting one: with both kits
            # whole-module and the app incremental, it is the app that fails.
            mode = flattened(settings.get(
                "SWIFT_COMPILATION_MODE", projectSettings.get("SWIFT_COMPILATION_MODE", "")))
            if mode != "wholemodule" and not any(flag in flags for flag in WHOLE_MODULE_FLAGS):
                problems.append(
                    f"    {name}: Swift target {target['name']} is not whole-module in {configuration} "
                    f"(SWIFT_COMPILATION_MODE is '{mode or 'unset'}') — across an import, a member whose "
                    "signature names an imported C++ type is lost, and the importer fails with \"has no member\"")
        distinct = sorted(set(views.values()))
        if len(distinct) > 1:
            reference = distinct[0]
            for target, view in sorted(views.items()):
                if view != reference:
                    only = sorted(set(view) ^ set(reference))
                    problems.append(
                        f"    {name} ({configuration}): Swift target {target} sees the C++ module "
                        f"differently from its neighbours — they differ in {', '.join(only)}")
    return problems


def readProject(path):
    """One generated project as the plain data `problemsForProject` examines.

    - Parameter path: The `.xcodeproj` directory.
    - Returns: The project dict.
    """
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path / "project.pbxproj")],
        capture_output=True, text=True, check=True)
    objects = json.loads(converted.stdout)["objects"]

    def configurationsOf(listIdentifier):
        result = {}
        for identifier in objects[listIdentifier]["buildConfigurations"]:
            configuration = objects[identifier]
            result[configuration["name"]] = configuration.get("buildSettings", {})
        return result

    root = next(entry for entry in objects.values() if entry["isa"] == "PBXProject")
    targets = []
    for identifier in root["targets"]:
        target = objects[identifier]
        scripts = [objects[phase].get("shellScript", "")
                   for phase in target.get("buildPhases", [])
                   if objects[phase]["isa"] == "PBXShellScriptBuildPhase"]
        sources = set()
        for phase in target.get("buildPhases", []):
            if objects[phase]["isa"] != "PBXSourcesBuildPhase":
                continue
            for buildFile in objects[phase].get("files", []):
                reference = objects.get(objects[buildFile].get("fileRef", ""), {})
                fileName = reference.get("path") or reference.get("name") or ""
                if "." in fileName:
                    sources.add(fileName.rsplit(".", 1)[1].lower())
        targets.append({
            "name": target["name"],
            "productType": target.get("productType", ""),
            "settings": configurationsOf(target["buildConfigurationList"]),
            "scripts": scripts,
            "sources": sorted(sources),
        })

    schemes = {}
    for scheme in sorted((path / "xcshareddata" / "xcschemes").glob("*.xcscheme")):
        tree = ElementTree.parse(scheme)
        schemes[scheme.stem] = [
            reference.get("BlueprintName", "")
            for reference in tree.iterfind("./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")]

    return {
        "name": path.stem,
        "settings": configurationsOf(root["buildConfigurationList"]),
        "targets": targets,
        "schemes": schemes,
    }


def referencedProjects(workspace):
    """The projects a workspace names, as paths.

    - Parameter workspace: The `.xcworkspace` directory.
    - Returns: A list of `.xcodeproj` paths, in the workspace's order.
    """
    tree = ElementTree.parse(workspace / "contents.xcworkspacedata")
    projects = []
    for reference in tree.iter("FileRef"):
        location = reference.get("location", "")
        if location.startswith("group:"):
            projects.append(workspace.parent / location[len("group:"):])
    return projects


def destinationProblems(workspace, project):
    """What xcodebuild itself says each iOS scheme can be built for.

    The settings above are the cause; this is the verdict, asked of the tool
    that gives it, for when the two are suspected of disagreeing.

    - Parameter workspace: The `.xcworkspace` directory.
    - Parameter project: A project dict whose schemes are asked about.
    - Returns: A list of one line per scheme short of a destination.
    """
    problems = []
    for scheme in sorted(project["schemes"]):
        listed = subprocess.run(
            ["xcodebuild", "-workspace", str(workspace), "-scheme", scheme, "-showdestinations"],
            capture_output=True, text=True)
        text = listed.stdout + listed.stderr
        for platform, label in (("platform:iOS,", "a device"), ("platform:iOS Simulator,", "a simulator")):
            if not any(platform in line and "error:" not in line for line in text.splitlines()):
                problems.append(
                    f"    {project['name']}: xcodebuild offers scheme {scheme} no destination for {label}")
    return problems


def selfTestProject(**changes):
    """A two-SDK iOS project that passes, with one thing altered.

    - Parameter changes: `project`, `renderKit` or `app` settings, or
      `appFlags`, each applied to the Debug configuration; the settings a
      `projectWithout`, `renderKitWithout` or `appWithout` removes from it;
      `release` settings and `releaseWithout` keys by target name, applied to
      the Release configuration; and `schemes`.
    - Returns: A project dict.
    """
    flags = "-package-name ubiquitty '-cxx-interoperability-mode=default' -Xcc '-std=c++23'"
    projectSettings = {"SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                       "SKIP_INSTALL": "YES"}
    release = dict(projectSettings, SWIFT_COMPILATION_MODE="wholemodule")
    debug = dict(projectSettings, **changes.get("project", {}))
    for removed in changes.get("projectWithout", ()):
        debug.pop(removed, None)
    renderKitDebug = {"OTHER_SWIFT_FLAGS": flags, "SWIFT_COMPILATION_MODE": "wholemodule"}
    renderKitDebug.update(changes.get("renderKit", {}))
    for removed in changes.get("renderKitWithout", ()):
        renderKitDebug.pop(removed, None)
    app = {
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "OTHER_SWIFT_FLAGS": changes.get("appFlags", flags),
        "OTHER_LDFLAGS": changes.get("appLink", ["-isysroot", "$(SDKROOT)", "/build/$(PLATFORM_NAME)/libUbiquittySSH.a"]),
        "SKIP_INSTALL": "NO",
        "INSTALL_PATH": "$(LOCAL_APPS_DIR)",
    }
    app.update(changes.get("app", {}))
    for removed in changes.get("appWithout", ()):
        app.pop(removed, None)
    debugInformation = {"GCC_GENERATE_DEBUGGING_SYMBOLS": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"}
    releaseSwiftFlags = f"{flags} -Xfrontend {NO_BREADCRUMBS_FLAG}"
    releases = {
        "RenderKit": dict(debugInformation, OTHER_SWIFT_FLAGS=releaseSwiftFlags),
        "Core": dict(debugInformation, LLVM_LTO="YES_THIN",
                     OTHER_CPLUSPLUSFLAGS="-O3 -fprofile-use=/build/pgo/portable-core.profdata"),
        "App": dict(app, OTHER_SWIFT_FLAGS=releaseSwiftFlags,
                    CONFIGURATION_BUILD_DIR="/build/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
                    DWARF_DSYM_FOLDER_PATH=ARCHIVE_DSYM_FOLDER, **debugInformation),
    }
    for targetName, updates in changes.get("release", {}).items():
        releases[targetName].update(updates)
    for targetName, removed in changes.get("releaseWithout", {}).items():
        for key in removed:
            releases[targetName].pop(key, None)
    return {
        "name": "SelfTest",
        "settings": {"Debug": debug, "Release": release},
        "targets": [
            {"name": "RenderKit", "productType": STATIC_LIBRARY_PRODUCT_TYPE, "sources": ["swift"],
             "settings": {"Debug": renderKitDebug, "Release": releases["RenderKit"]}, "scripts": []},
            {"name": "Core", "productType": STATIC_LIBRARY_PRODUCT_TYPE, "sources": ["c", "cpp"],
             "settings": {"Debug": {"OTHER_CPLUSPLUSFLAGS": "-O0"}, "Release": releases["Core"]}, "scripts": []},
            {"name": "App", "productType": APPLICATION_PRODUCT_TYPE, "sources": ["swift"],
             "settings": {"Debug": app, "Release": releases["App"]}, "scripts": []},
        ],
        "schemes": changes.get("schemes", {"App": ["App"]}),
    }


def selfTest():
    """The check can fail: each planted fault is caught, and the sound project passes.

    - Returns: 0 when every case answers as expected.
    """
    cases = (
        ("a sound two-SDK project", {}, None),
        ("a simulator base SDK", {"project": {"SDKROOT": "iphonesimulator"}}, "not iphoneos"),
        ("a device-only project", {"project": {"SUPPORTED_PLATFORMS": "iphoneos"}}, "lacks iphonesimulator"),
        ("an SDK path on the link line",
         {"appLink": ["-isysroot", "/Xcode.app/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk"]},
         "an SDK's resolved path"),
        ("an archive from one SDK's directory",
         {"appLink": ["/build/quic-deps/iphonesimulator/lib/libssl.a"]}, "a directory named for one SDK"),
        ("an incremental Debug module", {"renderKitWithout": ("SWIFT_COMPILATION_MODE",)}, "not whole-module in Debug"),
        ("a module without the package name",
         {"appFlags": "'-cxx-interoperability-mode=default' -Xcc '-std=c++23'"},
         "sees the C++ module differently"),
        ("a project with no scheme for its app", {"schemes": {}}, "no shared scheme builds the app"),
        ("an app the archive leaves uninstalled", {"appWithout": ("SKIP_INSTALL",)}, "skips installing the app"),
        ("an app installed outside Applications", {"app": {"INSTALL_PATH": ""}},
         "in Products/Applications (INSTALL_PATH"),
        ("a library the archive installs", {"projectWithout": ("SKIP_INSTALL",)}, "generic archive"),
        ("a Release library without link-time optimization", {"releaseWithout": {"Core": ("LLVM_LTO",)}},
         "without link-time optimization"),
        ("a Release library without the training profile", {"release": {"Core": {"OTHER_CPLUSPLUSFLAGS": "-O3"}}},
         "without the training profile"),
        ("a Release app that keeps no dSYM", {"release": {"App": {"DEBUG_INFORMATION_FORMAT": "dwarf"}}},
         "keeps no dSYM"),
        ("a Release library without debug information",
         {"release": {"RenderKit": {"GCC_GENERATE_DEBUGGING_SYMBOLS": "NO"}}}, "without debug information"),
        ("a Release app whose dSYM follows its build folder", {"releaseWithout": {"App": ("DWARF_DSYM_FOLDER_PATH",)}},
         "where an archive does not gather"),
        ("a Release Swift module with clang module breadcrumbs",
         {"release": {"RenderKit": {"OTHER_SWIFT_FLAGS": "-package-name ubiquitty"}}}, "clang module breadcrumbs"),
    )
    for label, changes, expected in cases:
        problems = problemsForProject(selfTestProject(**changes))
        if expected is None and problems:
            print(f"{NAME} --self-test: {label} reported {len(problems)} problem(s): {problems[0].strip()}")
            return 1
        if expected is not None and not any(expected in problem for problem in problems):
            print(f"{NAME} --self-test: {label} was not caught")
            return 1

    macOS = selfTestProject(project={"SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx iphoneos"})
    macOS["settings"]["Release"].update(SDKROOT="macosx", SUPPORTED_PLATFORMS="macosx")
    if not any("offered a phone" in problem for problem in problemsForProject(macOS)):
        print(f"{NAME} --self-test: a macOS project that supports a phone was not caught")
        return 1

    print(f"{NAME} --self-test: ok (a sound project passes; {len(cases)} planted faults are each caught)")
    return 0


def main(arguments):
    if arguments and arguments[0] in ("--self-test", "--selftest"):
        return selfTest()

    workspace = ROOT / "Ubiquitty.xcworkspace"
    askXcode = False
    index = 0
    while index < len(arguments):
        if arguments[index] == "--workspace" and index + 1 < len(arguments):
            workspace = pathlib.Path(arguments[index + 1]).resolve()
            index += 1
        elif arguments[index] == "--ask-xcode":
            askXcode = True
        else:
            print(f"{NAME}: unknown argument {arguments[index]}")
            return 2
        index += 1

    if shutil.which("plutil") is None:
        print(f"{NAME}: SKIPPED — reading an Xcode project needs plutil, which this machine does not have")
        return 0

    problems = []
    projects = []
    references = referencedProjects(workspace)
    if not references:
        problems.append(f"    {workspace.name} names no project")
    for path in references:
        if not (path / "project.pbxproj").is_file():
            problems.append(
                f"    {path.relative_to(workspace.parent)} — named by the workspace and not generated; "
                "run Scripts/generate-xcode-workspace.sh")
            continue
        project = readProject(path)
        projects.append(project)
        problems.extend(problemsForProject(project))
        isIOS = any("iphone" in flattened(settings.get("SDKROOT", ""))
                    for settings in project["settings"].values())
        if askXcode and isIOS:
            problems.extend(destinationProblems(workspace, project))

    if problems:
        print(f"{NAME}: a generated project cannot be built for what Xcode offers it:")
        print("\n".join(problems))
        print("  These are settings of the generated projects; the fix is in CMakeLists.txt or")
        print("  Scripts/generate-xcode-workspace.sh, then generate again.")
        return 1

    targets = sum(len(project["targets"]) for project in projects)
    print(f"{NAME}: ok ({len(projects)} project(s), {targets} target(s); base SDKs, supported "
          "platforms, SDK-free iOS settings, schemes and Swift module modes hold)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
