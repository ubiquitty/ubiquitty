// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// LocaleEnvironmentScenarios.swift — which locale a spawned shell is given.
//
// These drive the decision, not the export, and that limit is one
// worth stating. Any harness that launches the app launches it from a shell, so
// the app inherits that shell's LANG and the resolver correctly declines: a
// scenario driving the real app cannot reach the branch that matters. A
// scenario asserting collation in a live shell passes with the export removed
// as well: it measures the harness's own environment.
//
// So: the ladder, the order, the precedence and the fallbacks are tested here
// against supplied inputs. The one untested line is the setenv itself.
//
// The consequence is reachable by another route, and the last scenario takes
// it: rather than read the harness's environment, it CONSTRUCTS the one a
// Finder launch produces — empty but for what the PTY layer adds — and runs a
// child in it twice, once with the resolved locale and once without. The
// without arm is the control: a Finder-launched shell with no locale resolved.

/// Runs `sort` over `input` in a controlled environment.
///
/// The environment is replaced outright rather than extended, because the
/// question is what a child with no inherited locale does and an extension
/// would carry the harness's own.
///
/// - Parameters:
///   - input: The lines to sort, newline-terminated.
///   - environment: The child's whole environment.
/// - Returns: The sorted lines, or nil when the child could not be run.
private func sorted(_ input: String, environment: [String: String]) -> [String]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sort")
    process.environment = environment
    let toChild = Pipe()
    let fromChild = Pipe()
    process.standardInput = toChild
    process.standardOutput = fromChild
    do {
        try process.run()
    } catch {
        return nil
    }
    toChild.fileHandleForWriting.write(Data(input.utf8))
    toChild.fileHandleForWriting.closeFile()
    let output = fromChild.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: output, encoding: .utf8) else {
        return nil
    }
    return text.split(separator: "\n").map(String.init)
}

/// Registers the locale-environment scenarios with the UI-test runner.
///
/// A scenario is a C function pointer, so each closure below carries no
/// context.
enum LocaleEnvironmentScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("locale_resolves_a_name_the_c_library_accepts") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let resolved = LocaleEnvironment.resolvedLocaleName() else {
                    t.expect(false, desc: "some candidate resolves on a machine with locales installed")
                    return
                }
                // The claim is not that the string looks plausible but that the
                // C library ACCEPTS it — the same call the child's libc makes.
                // A name that merely parses would leave the shell in C while
                // the variable claimed otherwise, which is the failure this
                // whole change exists to avoid.
                let saved = setlocale(LC_ALL, nil).map { String(cString: $0) }
                let accepted = setlocale(LC_ALL, resolved) != nil
                if let saved {
                    setlocale(LC_ALL, saved)
                }
                t.expect(accepted, desc: "the resolved name \(resolved) is one setlocale accepts")
                t.expect(
                    resolved.contains("UTF-8") || !resolved.contains("."),
                    desc: "and it is a UTF-8 form, or a bare name carrying no other character set"
                )
            }
        }

        UBUITestRegister("locale_changes_how_a_child_sorts_and_dates") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let resolved = LocaleEnvironment.resolvedLocaleName() else {
                    t.expect(false, desc: "some candidate resolves on a machine with locales installed")
                    return
                }

                // The environment a Finder-launched app hands its children
                // today: launchd's, which carries no locale, plus the character
                // set the PTY layer supplies when it finds none. PATH is here
                // because the child has to be found, not because it matters to
                // the question.
                let asShippedToday = ["PATH": "/usr/bin:/bin", "LC_CTYPE": "C.UTF-8"]
                let withTheUsersLocale = ["PATH": "/usr/bin:/bin", "LANG": resolved]

                // Two names differing only in case. C collation orders by byte,
                // so every capital sorts before every lowercase; a region
                // locale folds case. Nothing about this reads the machine
                // running the test.
                let names = "Zebra\napple\n"

                guard let cOrder = sorted(names, environment: asShippedToday),
                    let localeOrder = sorted(names, environment: withTheUsersLocale)
                else {
                    t.expect(false, desc: "the child ran in both environments")
                    return
                }

                t.expect(
                    cOrder == ["Zebra", "apple"],
                    desc: "without a locale a child sorts by byte, capitals first (got \(cOrder))"
                )
                t.expect(
                    localeOrder == ["apple", "Zebra"],
                    desc: "with \(resolved) it folds case, as the rest of the system does (got \(localeOrder))"
                )
                t.expect(
                    cOrder != localeOrder,
                    desc: "and the two differ, so the locale is what decided it"
                )
            }
        }

        UBUITestRegister("locale_ladder_is_most_specific_first") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let candidates = LocaleEnvironment.candidateNames()
                t.expect(!candidates.isEmpty, desc: "the ladder has rungs")
                // Terminal.app's order. The two dotted forms differ only when
                // the identifier carries more than a language and a region, so
                // both exist; asserting the order matters because on a machine
                // where several are installed, trying them in the wrong order
                // still returns something acceptable and silently loses the
                // user's region.
                t.expect(
                    candidates.first?.hasSuffix(".UTF-8") == true,
                    desc: "the most specific rung is the identifier with the character set"
                )
                let dotted = candidates.filter { $0.contains(".") }
                let bare = candidates.filter { !$0.contains(".") }
                t.expect(!dotted.isEmpty && !bare.isEmpty, desc: "the ladder falls from dotted forms to bare ones")
                if let lastDotted = candidates.lastIndex(where: { $0.contains(".") }),
                    let firstBare = candidates.firstIndex(where: { !$0.contains(".") })
                {
                    t.expect(lastDotted < firstBare, desc: "and every dotted rung is tried before any bare one")
                }
                t.expect(
                    candidates.last?.contains("_") == false,
                    desc: "the last rung is the bare language, the broadest thing that can still match"
                )
            }
        }

        UBUITestRegister("an_inherited_locale_is_never_overridden") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The user's own choice outranks anything derived here, and
                // this is also what keeps the terminal out of the way of a
                // shell rc that sets locale itself.
                t.expect(
                    LocaleEnvironment.plan(isEnabled: true, inheritedLocale: "fr_FR.UTF-8") == .declineInherited,
                    desc: "an inherited locale is left alone"
                )
                t.expect(
                    LocaleEnvironment.plan(isEnabled: false, inheritedLocale: nil) == .declineDisabled,
                    desc: "the preference turns the whole thing off"
                )
                // Disabled wins over an empty environment: a user who turned it
                // off gets nothing set, not a derived default.
                t.expect(
                    LocaleEnvironment.plan(isEnabled: false, inheritedLocale: "fr_FR.UTF-8") == .declineDisabled,
                    desc: "and the preference is checked before anything else"
                )
                guard case .setLanguage = LocaleEnvironment.plan(isEnabled: true, inheritedLocale: nil) else {
                    t.expect(false, desc: "with nothing inherited and the preference on, a language is set")
                    return
                }
                t.expect(true, desc: "with nothing inherited and the preference on, a language is set")
            }
        }
    }
}
