#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Checks UI scenario results against explicit known failures and flaky cases.

A new failure or a recovered known failure fails the gate. Flaky scenarios
remain visibly ungated on every run. The exception tables carry public reasons
and are validated locally; no private tracker credentials are read.

    python3 Scripts/check-ui-scenarios.py
    python3 Scripts/check-ui-scenarios.py --entries
    python3 Scripts/check-ui-scenarios.py --self-test
"""

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import library_scripts  # noqa: F401, E402 — makes the libraries' modules importable
import gate_report  # noqa: E402

GATE = "check-ui-scenarios"

# A passing known failure must leave this set; its reason is part of the report.
KNOWN_FAILING = {}

# Flaky cases are reported as ungated whether they pass or fail.
KNOWN_FLAKY = {
    "swift_shell_context_menu_greys_out_and_stands_off":
        "fails inside the full suite and passes alone; isolate leaked menu, "
        "window, selection, shell, or private-pasteboard state",
}

_RESULT = re.compile(r"^(PASS|FAIL|REFUSED)\s+(\S+)\s*$")
_TOTALS = re.compile(r"^(\d+)/(\d+) scenarios passed\s*$")

def check_entries():
    """Validates disjoint scenario tables with nonempty public explanations."""
    problems = []
    for scenario in sorted(set(KNOWN_FAILING) & set(KNOWN_FLAKY)):
        problems.append(f"{scenario}: both known failing and flaky")
    for entries in (KNOWN_FAILING, KNOWN_FLAKY):
        for scenario, reason in entries.items():
            if not re.fullmatch(r"[a-z0-9_]+", scenario):
                problems.append(f"{scenario!r}: invalid scenario name")
            if not isinstance(reason, str) or not reason.strip():
                problems.append(f"{scenario}: missing explanation")
    if problems:
        return gate_report.failed(GATE, "invalid exception entries", problems)
    print(f"{GATE}: entries valid ({len(KNOWN_FAILING)} known failing, {len(KNOWN_FLAKY)} ungated)")
    return 0


def parse(output):
    """Splits a suite run into its passing and failing scenario names.

    - Parameter output: run-ui-tests.sh's stdout.
    - Returns: (passed, failed, totals, problems) — two sets, the reported
      (passed, total) pair or None, and result-accounting errors.
    """
    passed, failed, totals = set(), set(), None
    seen, problems = set(), []
    for line in output.splitlines():
        result = _RESULT.match(line)
        if result:
            state, scenario = result.groups()
            if scenario in seen:
                problems.append(f"scenario {scenario} reported more than one result")
            seen.add(scenario)
            if totals is not None:
                problems.append(f"scenario {scenario} reported after the suite total")
            if state == "REFUSED":
                problems.append(f"scenario {scenario} was refused; it did not execute")
            else:
                (passed if state == "PASS" else failed).add(scenario)
            continue
        total = _TOTALS.match(line)
        if total:
            if totals is not None:
                problems.append("suite reported more than one total")
            totals = (int(total.group(1)), int(total.group(2)))
    return passed, failed, totals, problems


def verdict(passed, failed, totals, problems=(), *, expected=(), returncode=None):
    """The gate's decision over one parsed run.

    A suite that reported no total did not finish — a crash mid-run leaves a
    prefix of PASS lines that would otherwise read as a clean sweep of whatever
    it reached.
    """
    if totals is None:
        return gate_report.failed(GATE, "suite did not report a total (it did not finish)")
    if problems:
        return gate_report.failed(GATE, "invalid suite result accounting", problems)
    if not totals[1]:
        return gate_report.failed(GATE, "suite did not execute any scenarios")
    if passed & failed:
        return gate_report.failed(GATE, "scenario(s) reported both PASS and FAIL", sorted(passed & failed))
    if totals[0] != len(passed):
        return gate_report.failed(
            GATE,
            f"suite reported {totals[0]} passing scenarios but named {len(passed)}")
    if totals[1] != len(passed) + len(failed):
        return gate_report.failed(
            GATE,
            f"suite reported {totals[1]} scenarios but named {len(passed) + len(failed)}")
    missing = sorted(set(expected) - passed - failed)
    if missing:
        return gate_report.failed(GATE, "expected scenario(s) did not execute", missing)
    if returncode is not None:
        if returncode not in (0, 1):
            return gate_report.failed(GATE, f"suite exited without a completed verdict (exit {returncode})")
        expected_code = 1 if failed else 0
        if returncode != expected_code:
            return gate_report.failed(
                GATE, f"suite exit {returncode} disagrees with its reported results (expected {expected_code})")

    # Flaky scenarios leave both sets before either question is asked: their
    # result carries no information, so neither "it failed" nor "it passed" is
    # something this gate can act on.
    gated_pass = passed - set(KNOWN_FLAKY)
    gated_fail = failed - set(KNOWN_FLAKY)

    regressions = sorted(gated_fail - set(KNOWN_FAILING))
    recovered = sorted(gated_pass & set(KNOWN_FAILING))

    # Printed first and on every run, whatever the verdict: an ungated scenario
    # is coverage this gate does not provide, and a reader who sees only the
    # passing line would otherwise believe it did.
    for scenario in sorted(KNOWN_FLAKY):
        state = "passed" if scenario in passed else "failed" if scenario in failed else "did not run"
        gate_report.finding(
            scenario, GATE,
            f"UNGATED — {state} this run, and the result is ignored either way ({KNOWN_FLAKY[scenario]})",
            level="warning")

    for scenario in regressions:
        gate_report.finding(scenario, GATE, "failing and not in KNOWN_FAILING")
    for scenario in recovered:
        gate_report.finding(
            scenario, GATE,
            f"passing — drop it from KNOWN_FAILING ({KNOWN_FAILING[scenario]})")

    if regressions:
        return gate_report.failed(GATE, "scenario(s) newly failing", regressions)
    if recovered:
        return gate_report.failed(GATE, "KNOWN_FAILING entrie(s) now passing", recovered)

    known = ", ".join(sorted(KNOWN_FAILING)) or "none"
    ungated = ", ".join(sorted(KNOWN_FLAKY)) or "none"
    return gate_report.ok(
        GATE,
        f"{totals[0]}/{totals[1]} passed; gated {len(gated_pass) + len(gated_fail)}; "
        f"known-failing: {known}; UNGATED: {ungated}")


def exercise_self_test():
    """Every verdict this gate exists to give, over synthetic runs."""
    known = sorted(KNOWN_FAILING)
    flaky = sorted(KNOWN_FLAKY)
    total = len(known) + len(flaky) + 1

    def run(failing, passing, reported=None):
        lines = [f"FAIL  {s}" for s in failing] + [f"PASS  {s}" for s in passing]
        count = reported if reported is not None else (len(passing), len(failing) + len(passing))
        return "\n".join(lines) + f"\n\n{count[0]}/{count[1]} scenarios passed"

    # The known set failing and the flake FAILING: the gate passes, because the
    # flake's result is ignored.
    assert verdict(*parse(run(known + flaky, ["other"]))) == 0, \
        "known-failing plus a failing flake must pass"

    # The same run with the flake passing: still passes. Ignoring the result in
    # both directions is what the third state exists for — a flake cannot make
    # this red whichever way it lands.
    assert verdict(*parse(run(known, flaky + ["other"]))) == 0, \
        "known-failing plus a passing flake must pass"

    # A real regression still fails, with the flake in either state.
    assert verdict(*parse(run(known + flaky + ["other"], []))) == 1, \
        "a new failure must fail even while the flake is failing"
    assert verdict(*parse(run(known + ["other"], flaky))) == 1, \
        "a new failure must fail even while the flake is passing"

    # A recovered KNOWN_FAILING entry still fails, so an entry expires with its
    # subject rather than outliving it.
    assert verdict(*parse(run(flaky, known + ["other"]))) == 1, \
        "a recovered known-failure must fail so the entry expires"

    # Structural guards, unchanged by the third state.
    assert verdict(*parse("PASS  other\n")) == 1, "a suite that printed no total must fail"
    assert verdict(*parse(run(known + flaky, ["other"], reported=(1, 99)))) == 1, \
        "a total that disagrees with the named lines must fail"

    # Opt-in scenarios are listed for discovery but absent from a default
    # run's result count. An explicitly selected refusal is still a failure.
    not_selected = "NOT SELECTED  external_probe (opt-in)\n"
    assert verdict(*parse(not_selected + run(known + flaky, ["other"]))) == 0, \
        "an opt-in scenario omitted by the runner must not count as a refusal"
    refused = "REFUSED  external_probe\n        - missing probe\n"
    assert verdict(*parse(refused + run(known + flaky, ["other"]))) == 1, \
        "an explicitly selected refusal must fail result accounting"

    # A scenario that starts a second application process. Inherited, the
    # child's suite lines are a second result and a second total among the
    # parent's, and they fail the accounting: they cannot be told from a
    # scenario that really ran twice, and folding them away would pass that
    # too. The harness writes the child's lines to a log instead.
    child = "PASS  restart\nscenarios complete: 1 executed\n\n1/1 scenarios passed\n"
    nested = "PASS  other\n" + child + "PASS  restart\nscenarios complete: 2 executed\n\n2/2 scenarios passed"
    passed, failed, totals, problems = parse(nested)
    assert "scenario restart reported more than one result" in problems \
        and "suite reported more than one total" in problems, \
        "a child application's suite lines among the parent's must fail the accounting"
    assert verdict(passed, failed, totals, problems) == 1, \
        "a child application's suite lines among the parent's must fail the gate"

    # A failing child is relayed as one reason under the parent's own result,
    # indented as the runner indents every reason, so nothing the child printed
    # reads as a result or a total, whatever it says.
    relayed = ("PASS  other\nFAIL  restart\n"
               "        - the first application process completes its assertions "
               "(exit 1: PASS  restart; 1/1 scenarios passed)\n"
               "scenarios complete: 2 executed\n\n1/2 scenarios passed")
    assert parse(relayed) == ({"other"}, {"restart"}, (1, 2), []), \
        "a relayed child failure must read as a reason, not as a result or a total"

    # A scenario cannot be in both sets: KNOWN_FLAKY wins by construction above,
    # which would silently ungate something recorded as a tracked failure.
    assert not (set(KNOWN_FAILING) & set(KNOWN_FLAKY)), \
        "KNOWN_FAILING and KNOWN_FLAKY must not overlap"

    assert check_entries() == 0, "the public exception tables must be valid"
    from unittest.mock import patch
    with patch.dict(KNOWN_FLAKY, {known[0]: "overlap"}):
        assert check_entries() == 1, "an overlapping exception must fail"
    with patch.dict(KNOWN_FAILING, {"invalid name": "reason"}):
        assert check_entries() == 1, "an invalid scenario name must fail"
    with patch.dict(KNOWN_FAILING, {"empty_reason": " "}):
        assert check_entries() == 1, "an unexplained exception must fail"

    print(f"{GATE}: self-test ok ({total} synthetic scenarios)")
    return 0


def self_test():
    from unittest.mock import patch
    with patch.dict(KNOWN_FAILING, {"known_failure": "synthetic failure"}, clear=True), \
            patch.dict(KNOWN_FLAKY, {"flaky_case": "synthetic flake"}, clear=True):
        return exercise_self_test()


def main():
    if "--self-test" in sys.argv:
        return self_test()
    if "--entries" in sys.argv:
        return check_entries()
    if check_entries() != 0:
        return 1

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    script = os.path.join(root, "Scripts", "run-ui-tests.sh")
    if not os.access(script, os.X_OK):
        return gate_report.failed(GATE, "run-ui-tests.sh is missing or not executable", [script])

    # A normal failed scenario exits 1, including a known failure. Refusals,
    # crashes, and exit codes contradicting the results cannot earn a verdict.
    run = subprocess.run([script], cwd=root, capture_output=True, text=True)
    status = verdict(*parse(run.stdout), expected=set(KNOWN_FAILING) | set(KNOWN_FLAKY),
                     returncode=run.returncode)
    if status != 0:
        # The suite's own lines are the evidence for a bad verdict: which
        # scenario failed and on which assertion, or how far a crashed run
        # got. A clean run's lines say that every scenario passed, one line
        # each, which the verdict above says in one.
        sys.stdout.write(run.stdout)
    if run.stderr:
        sys.stderr.write(run.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
