#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Run esctest with rectangular screen observations on an explicit page."""

import ast
import functools
import importlib
import os
import runpy
from contextlib import contextmanager
from pathlib import Path
import sys


def install_single_page_observer(utility, commands):
    original_observer = utility.GetChecksumOfRect

    @functools.wraps(original_observer)
    def observe_rectangle(rectangle):
        original_command = commands.DECRQCRA

        def request_rectangle(identifier, page, area):
            return original_command(identifier, 1 if page == 0 else page, area)

        # DEC page zero ignores the rectangle and checks all page memory.
        # Change only the observer's request, retaining esctest's reply parser,
        # assertions and direct DECRQCRA test commands.
        # https://vt100.net/docs/vt510-rm/DECRQCRA.html
        commands.DECRQCRA = request_rectangle
        try:
            return original_observer(rectangle)
        finally:
            commands.DECRQCRA = original_command

    utility.GetChecksumOfRect = observe_rectangle


@contextmanager
def implemented_features(utility):
    # These xterm limitations are implemented by Core. Run their assertions as
    # ordinary tests: a failure must propagate instead of becoming a known bug.
    features = {
        "knownBug": {
            *("DECRQMTests.test_DECRQM_DEC_" + mode for mode in (
                "DECARM", "DECCRTSM", "DECHEM", "DECKBUM", "DECKPM", "DECNCSM",
                "DECNULM", "DECPCCM", "DECRLCM", "DECRLM", "DECVCCM",
            )),
            "DECSEDTests.test_DECSED_doesNotRespectISOProtect",
            "DECSELTests.test_DECSEL_doesNotRespectISOProtect",
        },
        "optionRequired": {
            "DECSETTests.test_DECSET_DECNCSM",
            "DECRQMTests.test_DECRQM_DEC_DECNCSM",
        },
    }
    originals = {}
    try:
        for name, methods in features.items():
            original = getattr(utility, name)
            originals[name] = original

            def factory(*args, _original=original, _methods=methods, **kwargs):
                decorator = _original(*args, **kwargs)
                terminal = kwargs.get("terminal", args[0] if args else None)

                def decorate(function):
                    if terminal == "xterm" and function.__qualname__ in _methods:
                        return function
                    return decorator(function)

                return decorate

            setattr(utility, name, factory)
        yield
    finally:
        for name, original in originals.items():
            setattr(utility, name, original)


def install_target(namespace, commands, utility):
    categories = {category.__name__: category for category in namespace["tests"].tests}
    modes = categories["DECRQMTests"]
    mutable = {getattr(commands, name) for name in (
        "DECARM", "DECCRTSM", "DECHCCM", "DECHEM", "DECKBUM", "DECKPM",
        "DECNCSM", "DECNULM", "DECPCCM", "DECRLCM", "DECRLM", "DECVCCM",
    )}
    original = modes.doPermanentlyResetDecTest

    def check_mode(self, mode):
        if mode in mutable:
            return self.doModifiableDecTest(mode)
        return original(self, mode)

    modes.doPermanentlyResetDecTest = check_mode

    original_reset = namespace["reset"]

    def reset_case():
        # DECSTR preserves protected cells and several DEC registers. A case
        # must not inherit those from the preceding case; its own reset tests
        # still exercise DECSTR after arranging their state.
        commands.RIS()
        original_reset()
        commands.DECSET(commands.Allow80To132)

    namespace["reset"] = reset_case

    # OSC 105 restores configured special-colour resources, not an OSC 4/5
    # assignment. Core has no such resources. Assert that both wire aliases
    # preserve each assigned value, including a multi-index reset. See Core's
    # Tests/Core/test_conformance_color.cpp and xterm's OSC 105 contract:
    # https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
    colors = categories["ResetSpecialColorTests"]
    io = namespace["escio"]

    def check_special_colors(alias, count):
        offset = utility.GetIndexedColors() if alias == "4" else 0
        change = commands.ChangeSpecialColor if alias == "4" else commands.ChangeSpecialColor2
        values = ("aaaa/bbbb/cccc", "dddd/eeee/ffff")[:count]
        for index, value in enumerate(values):
            change(str(index), "#" + value.replace("/", ""))
            change(str(index), "?")
            utility.AssertEQ(io.ReadOSC(alias), ";" + str(offset + index) + ";rgb:" + value)
        commands.ResetSpecialColor(*(str(index) for index in range(count)))
        for index, value in enumerate(values):
            change(str(index), "?")
            utility.AssertEQ(io.ReadOSC(alias), ";" + str(offset + index) + ";rgb:" + value)

    for name, alias, count in (
        ("test_ResetSpecialColor_Single", "4", 1),
        ("test_ResetSpecialColor_Single2", "5", 1),
        ("test_ResetSpecialColor_Multiple", "4", 2),
        ("test_ResetSpecialColor_Multiple2", "5", 2),
    ):
        if not hasattr(colors, name):
            raise RuntimeError("esctest special-colour cases changed")

        def check(self, _alias=alias, _count=count):
            check_special_colors(_alias, _count)

        check.__name__ = name
        setattr(colors, name, check)


def run_target(suite, commands, utility):
    module = ast.parse(suite.read_text(), filename=str(suite))
    # The pinned upstream script calls main unconditionally. Defer only that
    # entry call so the fixture can be installed before any test is executed.
    entry = module.body[-1]
    if not (isinstance(entry, ast.Expr) and isinstance(entry.value, ast.Call)
            and isinstance(entry.value.func, ast.Name) and entry.value.func.id == "main"
            and not entry.value.args and not entry.value.keywords):
        raise RuntimeError("esctest entry point changed; refusing an unconfigured run")
    module.body.pop()
    namespace = {"__name__": "__main__", "__file__": str(suite)}
    with implemented_features(utility):
        exec(compile(module, str(suite), "exec"), namespace)
    install_target(namespace, commands, utility)
    namespace["main"]()

def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: esctest-observer.py <esctest.py> [arguments...]")
    target = sys.argv[1] == "--ubiquitty-target"
    if target:
        del sys.argv[1]
    suite = Path(sys.argv[1]).resolve()
    sys.argv = [str(suite), *sys.argv[2:]]
    sys.path.insert(0, str(suite.parent))
    # esccmd imports a completed escutil; enter their cycle in the suite's order.
    commands = importlib.import_module("esccmd")
    utility = importlib.import_module("escutil")
    install_single_page_observer(utility, commands)
    if target:
        run_target(suite, commands, utility)
    else:
        runpy.run_path(str(suite), run_name="__main__")
    completion = os.environ.get("UBQ_ESCTEST_COMPLETION_FILE")
    if completion:
        Path(completion).write_text("complete\n")


if __name__ == "__main__":
    main()
