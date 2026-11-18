#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Inventory selected XCTest cases and account for serial or parallel results."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


def source_cases(directory):
    """Read top-level XCTest classes, including subclasses of a shared fixture.

    Test declarations use the suite's four-space method indentation. Unsupported
    declarations and inherited tests fail closed instead of reducing the count.
    """
    classes = {}
    for path in sorted(Path(directory).glob("*.swift")):
        current = None
        for line in path.read_text().splitlines():
            declaration = re.match(r"(?:final )?class (\w+): (\w+)\s*\{", line)
            if declaration:
                name, parent = declaration.groups()
                if name in classes:
                    raise ValueError(f"duplicate class: {name}")
                classes[name] = (parent, [])
                current = name
            elif line == "}":
                current = None
            method = re.match(r"    func (test\w+)\(\)", line)
            if method:
                if current is None:
                    raise ValueError(f"test outside a recognized class: {line.strip()}")
                classes[current][1].append(method[1])

    def is_test_class(name, visited=()):
        if name == "XCTestCase":
            return True
        if name not in classes:
            return False
        if name in visited:
            raise ValueError("cyclic test fixture inheritance")
        return is_test_class(classes[name][0], (*visited, name))

    cases = set()
    for name, (_, methods) in classes.items():
        if methods and not is_test_class(name):
            raise ValueError(f"test methods in a class outside XCTestCase: {name}")
        if methods and any(parent == name for parent, _ in classes.values()):
            raise ValueError(f"shared fixture {name} must not declare inherited tests")
        for method in methods:
            case = name + "/" + method
            if case in cases:
                raise ValueError(f"duplicate test: {case}")
            cases.add(case)
    if not cases:
        raise ValueError("no XCTest cases declared")
    return cases


def selected_cases(cases, selection):
    """Resolve comma-separated class or Class/method selectors, without aliases."""
    if not selection:
        return cases
    selected = set()
    for requested in selection.split(","):
        matches = {case for case in cases
                   if case == requested or case.startswith(requested + "/")}
        if not matches:
            raise ValueError("unknown test selection: " + requested)
        selected.update(matches)
    return selected


def log_results(output):
    """Parse XCTest's detailed records and Xcode's parallel-worker summary.

    Xcode may print both forms for the same execution. Each form must contain
    at most one verdict per case, and their verdicts must agree. A retry cannot
    conceal a prior failure or take the place of a case that never executed.
    """
    detailed, parallel = {}, {}
    problems = []
    record = re.compile(r"^Test (Case|case) '([^']+)' (passed|failed|skipped)\b")
    objc_name = re.compile(r"-\[(?:\w+\.)?(\w+) (test\w+)\]")
    swift_name = re.compile(r"(?:\w+\.)?(\w+)\.(test\w+)\(\)")
    for line in output.splitlines():
        match = record.match(line)
        if not match:
            continue
        style, raw_name, state = match.groups()
        name = objc_name.fullmatch(raw_name) or swift_name.fullmatch(raw_name)
        if not name:
            problems.append("unrecognized XCTest result: " + raw_name)
            continue
        case = "/".join(name.groups())
        records = detailed if style == "Case" else parallel
        if case in records:
            problems.append("duplicate execution: " + case)
        records[case] = state
    for case in detailed.keys() & parallel.keys():
        if detailed[case] != parallel[case]:
            problems.append("conflicting verdicts: " + case)
    return detailed | parallel, problems


def verify(cases, output):
    """Require exactly the selected identities, including existing runtime skips."""
    results, problems = log_results(output)
    problems += ["missing case: " + case for case in sorted(cases - results.keys())]
    problems += ["unexpected case: " + case for case in sorted(results.keys() - cases)]
    problems += ["failed case: " + case for case, state in sorted(results.items())
                 if state == "failed"]
    return results, problems


def main():
    """Print a catalog or verify a completed run; never accept an empty suite."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--only", default="")
    parser.add_argument("--log", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        declared = source_cases(args.source)
        selected = selected_cases(declared, args.only)
        if args.log is None:
            print(len(selected))
            return 0
        results, problems = verify(selected, args.log.read_text(errors="replace"))
    except (OSError, ValueError) as error:
        print("run-ios-ui-tests: " + str(error), file=sys.stderr)
        return 2
    counts = Counter(results.values())
    for case, state in sorted(results.items()):
        print(f"  {case}  {state}")
    print(f"run-ios-ui-tests: {counts['passed']} passed, {counts['failed']} failed, "
          f"{counts['skipped']} skipped ({len(selected)} selected, {len(declared)} declared)")
    if args.receipt:
        args.receipt.write_text(json.dumps({
            "declared": sorted(declared), "selected": sorted(selected),
            "results": results, "problems": problems,
        }, indent=2) + "\n")
    for problem in problems:
        print("run-ios-ui-tests: " + problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
