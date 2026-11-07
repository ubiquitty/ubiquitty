#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-bundled-fonts — every family Core names has its file beside each binary.

`BundledFonts.h` is the table a frontend puts a configured family through, and
its answer is a path derived from the directory the binary sits in. A family in
that table whose file the build never copied resolves to a path that does not
exist, and the frontends do not stop there: FreeType falls through to the
embedded Unifont, which RENDERS. So the failure is a picture in the wrong face
rather than an error, and a golden minted from it records the fallback.

Found that way: eight snapshot profiles named `Monaspace Neon`, whose file the
Linux build did not copy, and their native freetype goldens came out
byte-identical to their unifont ones — the tier that exists to draw a real face
was drawing the bitmap one. The CMake comment beside the list already said this
would happen and named this script as the check; the script did not exist.

The AppImage is checked against the same list. package-linux-appimage.sh lays
out its AppDir with `cmake --install`, and the Linux install rule names the
staged fonts and shaders, so the archive carries what the build directory does.
A face the script copies by hand instead is a second list, which can fall
short of the first with no build failing.

The macOS app is not checked here. It registers the whole `Resources/fonts`
directory through `ATSApplicationFontsPath`, so its set is the directory itself
and cannot drift from it.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import library_scripts  # noqa: E402 — the table and the font files are Core's

TABLE = pathlib.Path(library_scripts.locate("Source/Core/Rendering/BundledFonts.h"))
CMAKE = ROOT / "CMakeLists.txt"
FONTS = pathlib.Path(library_scripts.locate("Resources/fonts"))
NAME = "check-bundled-fonts"

# The list each frontend copies, and the name to print when one is short.
FRONTEND_LISTS = {
    "Linux": "UBIQUITTY_LINUX_BUNDLED_FONTS",
    "iOS": "UBIQUITTY_IOS_BUNDLED_FONT_FILES",
}

# The iOS plist key that REGISTERS what the list stages. A file copied into the
# bundle and left out of it is present and unopenable: `UIFont(name:)` answers
# nil, the app falls to the system face, and the grid comes out at another
# family's metrics. Generated from the same list, so this checks the generation
# rather than a second hand-written copy.
IOS_PLIST = ROOT / "Source" / "Platform" / "iOS" / "App" / "Info.plist.in"

# The script that packages the Linux binary, and the install rule its AppDir is
# laid out from: the staged fonts and the compiled shaders, beside the binary.
APPIMAGE_SCRIPT = ROOT / "Scripts" / "package-linux-appimage.sh"
LINUX_INSTALL_RULE = re.compile(
    r"install\(FILES\s+(?=[^)]*\$\{_ubiquitty_spv\})(?=[^)]*\$\{UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS\})"
    r"[^)]*DESTINATION\s+bin\s*\)")


def tableFiles():
    """Every file name `bundledFonts()` names, each style alike.

    Read out of the header rather than compiled against, so the check runs in
    the style job with no build behind it.

    - Returns: A dict of file name to the family that names it.
    """
    text = TABLE.read_text()
    files = {}
    # An entry is the family and then its style files; a style the family
    # carries on an axis, or not at all, is an empty `{}`.
    for entry in re.findall(r'\{\s*"[^"]+"(?:\s*,\s*(?:"[^"]*"|\{\}))+\s*\}', text):
        family, *styleFiles = re.findall(r'"([^"]*)"', entry)
        for name in styleFiles:
            if name:
                files[name] = family
    return files


def listedFiles(variable):
    """The file names one frontend's `set(...)` block copies.

    - Parameter variable: The CMake variable holding the list.
    - Returns: A set of file names, without any directory in front of them.
    """
    text = CMAKE.read_text()
    match = re.search(r"set\(" + re.escape(variable) + r"\b(.*?)\)", text, re.S)
    if not match:
        return None
    return {pathlib.PurePosixPath(name).name for name in re.findall(r'"([^"]+)"', match.group(1))}


def problemsFor(files, listsByFrontend, presentFiles):
    """Every gap between what Core names and what a frontend copies.

    Takes its three inputs rather than reading them, so the self-test can plant
    a gap and watch this find it. A checker calibrated only on the absence
    proves nothing about the presence.

    - Parameter files: File name to the family naming it.
    - Parameter listsByFrontend: Frontend name to the set of files it copies.
    - Parameter presentFiles: The file names the repository actually holds.
    - Returns: A list of one line per gap, empty when there is none.
    """
    problems = []
    for name in sorted(files):
        if name not in presentFiles:
            problems.append(f'    Resources/fonts/{name} — named by "{files[name]}", not in the repository')

    for frontend, listed in listsByFrontend.items():
        if listed is None:
            problems.append(f"    {frontend} — no such list in CMakeLists.txt")
            continue
        for name in sorted(files):
            if name not in listed:
                problems.append(
                    f'    {frontend}: {name} — named by "{files[name]}" and never copied, '
                    "so that family resolves to a path that does not exist")
    return problems


def facesMissingFrom(listed, presentFonts):
    """The font files a frontend's list leaves out of the whole directory.

    The macOS app registers every file in Resources/fonts, and the iOS arm is
    held to the same CoreText goldens. A face only the Mac registers is one
    CoreText synthesises on the phone: Monaspace Neon's italic came out as a
    skewed upright, a pixel to the side of the drawn one, on every italic run.

    - Parameter listed: The file names the frontend stages.
    - Parameter presentFonts: The font files the directory holds.
    - Returns: The missing file names, sorted.
    """
    return sorted(presentFonts - (listed or set()))


def appImageProblems(cmakeText, scriptText, linuxListed):
    """Every way the AppImage can ship other fonts than the Linux build stages.

    - Parameters:
      - cmakeText: The text of CMakeLists.txt.
      - scriptText: The text of the AppImage packaging script.
      - linuxListed: The file names the Linux build stages beside its binary.
    - Returns: A list of one line per problem, empty when there is none.
    """
    problems = []
    if not LINUX_INSTALL_RULE.search(cmakeText):
        problems.append("    AppImage: CMakeLists.txt installs no `${_ubiquitty_spv} "
                        "${UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS}` into bin, beside the binary")
    if not re.search(r"^\s*cmake --install\b", scriptText, re.M):
        problems.append(f"    AppImage: {APPIMAGE_SCRIPT.name} does not lay out its AppDir with cmake --install")
    for name in sorted(set(re.findall(r"[\w.\[\]-]+\.(?:ttf|otf)\b", scriptText))):
        if name not in (linuxListed or set()):
            problems.append(f"    AppImage: {name} — copied by {APPIMAGE_SCRIPT.name} and not in "
                            "UBIQUITTY_LINUX_BUNDLED_FONTS, so the two lists disagree")
    return problems


def selfTest():
    """The check can fail, on a table and a list that differ by one file.

    - Returns: 0 when the planted gap is caught and the complete pair passes.
    """
    table = {"A.ttf": "Family A", "B.ttf": "Family B"}
    present = {"A.ttf", "B.ttf"}
    complete = problemsFor(table, {"Frontend": {"A.ttf", "B.ttf"}}, present)
    short = problemsFor(table, {"Frontend": {"A.ttf"}}, present)
    absent = problemsFor(table, {"Frontend": {"A.ttf", "B.ttf"}}, {"A.ttf"})
    if complete:
        print(f"{NAME} --self-test: a complete list reported {len(complete)} problem(s)")
        return 1
    if len(short) != 1 or "B.ttf" not in short[0]:
        print(f"{NAME} --self-test: a list missing one file was not caught")
        return 1
    if facesMissingFrom({"A.ttf"}, {"A.ttf", "A-Italic.otf"}) != ["A-Italic.otf"] or facesMissingFrom(
            {"A.ttf"}, {"A.ttf"}):
        print(f"{NAME} --self-test: a face left out of the iOS list was not caught")
        return 1
    if len(absent) != 1 or "not in the repository" not in absent[0]:
        print(f"{NAME} --self-test: a table naming a file nothing ships was not caught")
        return 1
    rule = "install(FILES ${_ubiquitty_spv} ${UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS} DESTINATION bin)"
    installed = 'cmake --install "$BUILD" --prefix "$APPDIR/usr"\n'
    if appImageProblems(rule, installed, {"A.ttf"}):
        print(f"{NAME} --self-test: an AppImage laid out from the install rule was refused")
        return 1
    handCopied = installed + 'install -Dm644 "$ROOT/Resources/fonts/B.ttf" "$APPDIR/usr/bin/B.ttf"\n'
    if len(appImageProblems(rule, handCopied, {"A.ttf"})) != 1:
        print(f"{NAME} --self-test: a face the AppImage copies outside the Linux list was not caught")
        return 1
    noRule = "install(FILES ${UBIQUITTY_LINUX_BUNDLED_FONT_OUTPUTS} DESTINATION bin)"
    if len(appImageProblems(noRule, 'install -Dm755 "$BIN" "$APPDIR/usr/bin/x"\n', {"A.ttf"})) != 2:
        print(f"{NAME} --self-test: an AppImage without the shaders' install rule or cmake --install "
              "was not caught")
        return 1
    print(f"{NAME} --self-test: ok (a complete pair passes, a short list, a missing "
          "file and an AppImage list of its own are each caught)")
    return 0


def registeredInPlist():
    """The file names `UIAppFonts` registers, without their directory.

    Read from the template CMake configures, since that is where a name is
    written. A template generating the array from the staged list has no names
    of its own, and reports an empty set — which turns this from a check on a
    second hand-written copy into a check that the generation is in place.

    - Returns: A set of file names, None when the key is missing, or an empty
      set when the array is generated from the staged list.
    """
    text = IOS_PLIST.read_text()
    match = re.search(r"<key>UIAppFonts</key>\s*<array>(.*?)</array>", text, re.S)
    if not match:
        return None
    body = match.group(1)
    if "UBIQUITTY_IOS_APP_FONTS_ENTRIES" in body:
        return set()
    return {pathlib.PurePosixPath(name).name for name in re.findall(r"<string>([^<]+)</string>", body)}


def main(arguments):
    if arguments and arguments[0] in ("--self-test", "--selftest"):
        return selfTest()

    files = tableFiles()
    if not files:
        print(f"{NAME}: no entries parsed from BundledFonts.h; the table's shape changed")
        return 1

    present = {path.name for path in FONTS.iterdir()} if FONTS.is_dir() else set()
    lists = {frontend: listedFiles(variable) for frontend, variable in FRONTEND_LISTS.items()}
    problems = problemsFor(files, lists, present)
    # Staging a file is not registering it. A font in the bundle and absent from
    # UIAppFonts cannot be opened by name: UIFont answers nil, the app falls to
    # the system face, and the grid comes out at another family's metrics with
    # nothing reported.
    presentFonts = {name for name in present if name.endswith((".ttf", ".otf"))}
    for name in facesMissingFrom(lists.get("iOS"), presentFonts):
        problems.append(
            f"    iOS: {name} — in Resources/fonts, which the macOS app registers whole, and not "
            "staged for iOS, so CoreText synthesises that face on the phone")
    problems.extend(appImageProblems(CMAKE.read_text(), APPIMAGE_SCRIPT.read_text(), lists.get("Linux")))
    registered = registeredInPlist()
    if registered is None:
        problems.append("    Info.plist.in — no UIAppFonts array; nothing registers the staged files")
    elif registered:
        for name in sorted(files):
            if name not in registered:
                problems.append(
                    f'    iOS: {name} — named by "{files[name]}" and staged but absent from UIAppFonts')
    if problems:
        print(f"{NAME}: a family Core names has no file beside a binary:")
        print("\n".join(problems))
        print("  A missing file is not an error at run time — FreeType falls through to the")
        print("  embedded Unifont, which renders — so this is the only place it is visible.")
        return 1

    print(f"{NAME}: ok ({len(files)} file(s) across "
          f"{len(FRONTEND_LISTS)} frontend list(s), each one shipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
