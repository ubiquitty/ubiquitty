// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

// LocaleEnvironment.swift — the locale a spawned shell starts in.
//
// A GUI process launched from Finder or the Dock inherits launchd's
// environment, which carries no locale, so a shell spawned from it runs under
// C/POSIX: byte-order collation, C date formats. Supplying the system locale
// makes the shell's sorting and date formats follow the user's region.
//
// The locale candidate order follows Terminal.app's measured algorithm.
// What it does, in order: build candidate locale names from the current locale,
// try each with setlocale(), export LANG for the first that the C library
// accepts, and fall back to LC_CTYPE=UTF-8 alone when none is installed.
//
// Validation is setlocale() and not a scan of `locale -a` on purpose: it is the
// same function the child's libc will call, so it cannot disagree with itself.
// A name that merely looks plausible is worse than none, because libc falls
// back to C silently while the variable claims otherwise.
@objc(UBLocaleEnvironment)
final class LocaleEnvironment: NSObject {
    /// Exports `LANG` for the shells this process will spawn.
    ///
    /// A no-op when the environment already carries a locale: an inherited one
    /// is the user's own choice and outranks anything derived here. Also a
    /// no-op when the preference is off, for users who set locale in their
    /// shell rc and do not want the terminal in that business.
    ///
    /// Sets the variable on the app's own process, which is what the PTY layer copies
    /// into each child. This composes with
    /// CharacterLocalePolicy.auto, whose rule is to supply a default only when
    /// no locale is inherited. Once LANG is set, that rule correctly declines.
    @objc
    static func exportIfNeeded() {
        switch plan(isEnabled: isEnabledInPreferences(), inheritedLocale: inheritedLocale()) {
        case .declineDisabled, .declineInherited:
            return
        case .setLanguage(let name):
            setenv("LANG", name, 1)
        case .setCharacterSetOnly:
            setenv("LC_CTYPE", "UTF-8", 1)
        case .declineNothingInstalled:
            return
        }
    }

    /// What `exportIfNeeded` will do, as a value.
    ///
    /// Split out because the decision cannot be observed end to end: any
    /// harness that launches the app launches it from a shell, so the app
    /// inherits that shell's locale and this correctly declines — a test
    /// driving the real app can never see the branch that matters. The
    /// decision is therefore tested here, on a supplied environment, and the
    /// export itself is the one untested line.
    ///
    /// - Parameters:
    ///   - isEnabled: The preference.
    ///   - inheritedLocale: The locale already in the environment, or nil.
    /// - Returns: The action to take.
    enum Plan: Equatable {
        case declineDisabled
        case declineInherited
        case declineNothingInstalled
        case setLanguage(String)
        case setCharacterSetOnly
    }

    static func plan(isEnabled: Bool, inheritedLocale: String?) -> Plan {
        guard isEnabled else {
            return .declineDisabled
        }
        // An inherited locale wins, whatever its spelling. This mirrors the PTY
        // layer's own hasInheritedCharacterLocale, which counts all three.
        if inheritedLocale != nil {
            return .declineInherited
        }
        if let resolved = resolvedLocaleName() {
            return .setLanguage(resolved)
        }
        // No candidate is installed. Terminal.app narrows to the character set
        // alone here rather than giving up, and so do we: UTF-8 ctype is the
        // half that matters most and the half most likely to exist.
        return probeAccepts(LC_CTYPE, "UTF-8") ? .setCharacterSetOnly : .declineNothingInstalled
    }

    /// The locale already present in the environment, if any.
    ///
    /// - Returns: The first non-empty of LC_ALL, LC_CTYPE, LANG.
    static func inheritedLocale() -> String? {
        for name in ["LC_ALL", "LC_CTYPE", "LANG"] {
            guard let value = getenv(name), strlen(value) > 0 else {
                continue
            }
            return String(cString: value)
        }
        return nil
    }

    /// The candidate ladder, in the order Terminal.app tries it.
    ///
    /// Exposed so a test can assert the ORDER rather than only the outcome: on
    /// a machine where several candidates are installed, an implementation that
    /// tried them in the wrong order would still return something acceptable.
    ///
    /// - Returns: The candidates, most specific first.
    static func candidateNames() -> [String] {
        let locale = Locale.current
        let identifier = locale.identifier
        let language = locale.language.languageCode?.identifier
        let region = locale.region?.identifier
        let characterSet = "UTF-8"

        var candidates: [String] = ["\(identifier).\(characterSet)"]
        if let language, let region {
            candidates.append("\(language)_\(region).\(characterSet)")
        }
        candidates.append(identifier)
        if let language, let region {
            candidates.append("\(language)_\(region)")
        }
        if let language {
            candidates.append(language)
        }
        return candidates
    }

    /// The first candidate name the C library accepts, or nil when none is.
    ///
    /// The ladder is Terminal.app's, and the two `.UTF-8` forms are both tried
    /// because they differ whenever the identifier carries more than a language
    /// and a region — a script subtag, or an @-keyword. `en_GB` is the same
    /// either way; `zh-Hans_CN` is not.
    ///
    /// - Returns: A locale name setlocale accepted, or nil.
    static func resolvedLocaleName() -> String? {
        let candidates = candidateNames()

        // setlocale MUTATES this process's locale, so the probe has to put back
        // what it found. Without the restore, asking the question would change
        // the answer for every later formatter in this process.
        let saved = setlocale(LC_ALL, nil).map { String(cString: $0) }
        defer {
            if let saved {
                setlocale(LC_ALL, saved)
            }
        }
        for candidate in candidates where setlocale(LC_ALL, candidate) != nil {
            return candidate
        }
        return nil
    }

    /// Whether setlocale accepts a name for one category, restoring after.
    ///
    /// - Parameters:
    ///   - category: The `LC_*` category to probe.
    ///   - name: The locale name to try.
    /// - Returns: Whether the C library accepted it.
    private static func probeAccepts(_ category: Int32, _ name: String) -> Bool {
        let saved = setlocale(category, nil).map { String(cString: $0) }
        defer {
            if let saved {
                setlocale(category, saved)
            }
        }
        return setlocale(category, name) != nil
    }

    /// The preference, enabled by default.
    ///
    /// - Returns: Whether to export a locale at all.
    private static func isEnabledInPreferences() -> Bool {
        Ubiquitty.Preferences.Effective.setsLocaleEnvironment(Ubiquitty.Preferences.values().pointee)
    }
}
