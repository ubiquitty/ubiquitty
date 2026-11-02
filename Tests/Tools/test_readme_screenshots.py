# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Check documentation-feed contracts without launching the renderer."""

import base64
import importlib.util
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
SPEC = importlib.util.spec_from_file_location("readme_screenshots", ROOT / "Tools/readme-screenshots.py")
RECIPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECIPE)


class ReadmeScreenshotsTest(unittest.TestCase):
    def test_every_capture_uses_noir(self):
        self.assertTrue(RECIPE.CAPTURES)
        for _, _, _, theme in RECIPE.CAPTURES.values():
            self.assertEqual(theme, "Noir")

    def test_tek_vectors_leave_room_for_all_labels(self):
        line_count = 0
        original = RECIPE._tek_vectors

        def count_lines(points):
            nonlocal line_count
            line_count += max(0, len(points) - 1)
            return original(points)

        with patch.object(RECIPE, "_tek_vectors", count_lines):
            feed = RECIPE.tektronix()
        labels = ("Tektronix 4014", "Wireframe cube", "Latitude / longitude", "z = sin(2.4x) cos(2.4y)")
        for label in labels:
            self.assertIn("\x1f\x1b8" + label, feed)
        self.assertLessEqual(line_count + sum(map(len, labels)), 4096)

    def test_polish_uses_real_attributes_and_bracket_pieces(self):
        feed = RECIPE.polish()
        for sequence in ("\x1b[73m", "\x1b[74m", "\x1b[4:3m", "⎛", "⎝", "⎧", "⎩"):
            self.assertIn(sequence, feed)
        self.assertNotIn("diff", RECIPE.CAPTURES)

    def test_btop_capture_hides_personal_panels(self):
        config = (ROOT / "Docs/images/btop.conf").read_text()
        for setting in ('shown_boxes = "cpu"', 'clock_format = ""',
                        'disable_presets = "All"', "show_disks = false", "show_uptime = false"):
            self.assertIn(setting, config)

    def test_workspace_typography_keeps_proportional_runs_inside_box(self):
        feed = RECIPE.workspace_typography()
        self.assertEqual(RECIPE.CAPTURES["workspace-typography"][1:3], (77, 32))
        runs = re.findall(r"\x1b\[(\d+);(\d+)H[^\x1b]*(?:\x1b\[[0-9;:]*m)*"
                          r"\x1b\]66;p=1:c=(\d+);([^\x1b]*)\x1b\\", feed)
        self.assertEqual(len(runs), 4)
        for row, column, cells, _ in runs:
            self.assertGreater(int(row), 4)
            self.assertLess(int(row), 13)
            self.assertGreater(int(column), 4)
            self.assertLess(int(column) + int(cells), 73)
        self.assertIn("Review queue", feed)
        self.assertEqual(feed.count("□"), 2)
        for sequence in ("\x1b[73m", "\x1b[74m", "\x1b[4:3m", "⎛", "⎝", "⎧", "⎩"):
            self.assertIn(sequence, feed)


def trace_line(time, tab, tabs, kind, slot, **facts):
    values = {"selected": 1, "isSelected": 0, "isKey": 1, "appActive": 1, "unread": 0, "bell": 0,
              "notification": 0, "progress": 0, "status": 0, "held": 0, "hintOff": 1}
    values.update(facts)
    middle = " ".join(f"{key}={value}" for key, value in values.items())
    return f"[tab-accessory] {time:.6f} tab={tab}/{tabs} {middle} kind={kind} slot={slot}"


def reports(path):
    """The OSC bodies written to a stand-in terminal, in order."""
    return [body.removeprefix("\x1b]") for body in path.read_text(encoding="utf-8").split("\x1b\\") if body]


def message_of(body):
    fields = dict(field.partition("=")[::2] for field in body.removeprefix("7501;").split(":"))
    return base64.b64decode(fields["msg"]).decode("utf-8") if "msg" in fields else None


class DemoHomeTest(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="readme-demo-test."))
        self.home = self.scratch / "home"
        RECIPE.write_demo_home(self.home)
        self.terminal = self.scratch / "terminal"
        self.terminal.write_text("")
        self.environment = dict(os.environ, UBQ_STATUS_TTY=str(self.terminal), TMPDIR=str(self.scratch))

    def tearDown(self):
        shutil.rmtree(self.scratch)

    def run_helper(self, name, *arguments, stdin=""):
        return subprocess.run([str(self.home / "bin" / name), *arguments], input=stdin, capture_output=True,
                              text=True, env=self.environment, cwd=self.home, timeout=60)

    def test_writes_every_piece_the_recipe_names(self):
        for folder in ("sync", "api", "build", "web", "Docs", "bench", "notes", "typography", "Tests"):
            self.assertTrue((self.home / folder).is_dir(), folder)
        for name in (".zshrc", ".config/nvim/init.lua", ".config/nvim/after/ftplugin/markdown.lua",
                     ".config/ubiquitty/config.toml", ".claude/settings.json", "sync/Images.cpp",
                     "Docs/sync.md", "typography/workspace-typography.ans", "web/Makefile", "api/Client.cpp"):
            self.assertTrue((self.home / name).is_file(), name)
        for name in ("status-run", "pst-hook", "bench-sync"):
            self.assertTrue((self.home / "bin" / name).stat().st_mode & stat.S_IXUSR, name)
        self.assertIn("wrap = false", (self.home / ".config/nvim/after/ftplugin/markdown.lua").read_text())
        manifest = json.loads((self.home / ".readme-demo-manifest.json").read_text())
        hashed = {entry["path"] for entry in manifest["files"]}
        self.assertIn("bin/status-run", hashed)
        self.assertIn(".claude/settings.json", hashed)

    def test_hooks_cover_claude_codes_lifecycle(self):
        hooks = json.loads((self.home / ".claude/settings.json").read_text())["hooks"]
        commands = {event: [(entry.get("matcher"), hook["command"]) for entry in entries for hook in entry["hooks"]]
                    for event, entries in hooks.items()}
        self.assertIn(("permission_prompt", '"$HOME"/bin/pst-hook blocked permission'), commands["Notification"])
        self.assertIn(("idle_prompt", '"$HOME"/bin/pst-hook prompt-idle'), commands["Notification"])
        self.assertEqual(commands["Stop"], [(None, '"$HOME"/bin/pst-hook done')])
        self.assertEqual(commands["UserPromptSubmit"], [(None, '"$HOME"/bin/pst-hook working')])
        self.assertTrue(commands["SessionStart"][0][1].endswith("pst-hook idle"))
        self.assertTrue(commands["PostToolUse"][0][1].endswith("pst-hook working"))

    def test_names_no_person_machine_or_checkout(self):
        forbidden = {str(RECIPE.ROOT), str(Path.home())}
        if len(platform.node().split(".")[0]) > 3:
            forbidden.add(platform.node().split(".")[0])
        for path in self.home.rglob("*"):
            if path.is_file():
                text = path.read_bytes().decode("utf-8", errors="replace")
                for word in forbidden:
                    self.assertNotIn(word, text, path)

    def test_refuses_the_real_home_and_the_checkout(self):
        for target in (Path.home(), RECIPE.ROOT, RECIPE.ROOT / "Docs"):
            result = subprocess.run([sys.executable, str(RECIPE.ROOT / "Tools/readme-screenshots.py"),
                                     "--demo-home", str(target)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, target)

    def test_status_run_reports_the_commands_progress_and_failure(self):
        program = "import sys\nfor n in range(1, 5): print(f'[{n}/4] step {n}')\nprint('1 failed, 3 passed')\nsys.exit(3)\n"
        result = self.run_helper("status-run", "tests", "--", sys.executable, "-c", program)
        self.assertEqual(result.returncode, 3)
        self.assertIn("[4/4] step 4", result.stdout)
        sent = reports(self.terminal)
        self.assertTrue(sent[0].startswith("3008;start=status-run.tests."))
        self.assertEqual(sent[1], "7501;id=tests:app=tests:state=working")
        self.assertEqual([body for body in sent if body.startswith("9;4;1;")], ["9;4;1;25", "9;4;1;50", "9;4;1;75", "9;4;1;100"])
        self.assertIn("7501;id=tests:app=tests:state=working:progress=50", sent)
        self.assertEqual(sent[-3], "9;4;0")
        self.assertRegex(sent[-2], r"^3008;end=status-run\.tests\.\d+;exit=failure;status=3$")
        self.assertTrue(sent[-1].startswith("7501;id=tests:app=tests:state=error:msg="))
        self.assertEqual(message_of(sent[-1]), "1 failed, 3 passed")

    def test_status_run_reports_done_and_a_bare_exit_status(self):
        result = self.run_helper("status-run", "build", "--", sys.executable, "-c", "print('[1/1] link')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(reports(self.terminal)[-1], "7501;id=build:app=build:state=done")
        self.terminal.write_text("")
        result = self.run_helper("status-run", "build", "--", sys.executable, "-c", "raise SystemExit(4)")
        self.assertEqual(result.returncode, 4)
        self.assertEqual(message_of(reports(self.terminal)[-1]), "exit 4")
        self.assertNotEqual(self.run_helper("status-run", "no spaces", "--", "true").returncode, 0)

    def test_pst_hook_reports_claudes_own_words(self):
        prompt = json.dumps({"session_id": "one", "prompt": "Proofread the headings in ~/Docs/sync.md; fix capitalisation only"})
        self.assertEqual(self.run_helper("pst-hook", "working", stdin=prompt).stdout, "")
        blocked = json.dumps({"session_id": "one", "message": "Claude needs your permission to use Bash"})
        self.run_helper("pst-hook", "blocked", "permission", stdin=blocked)
        self.run_helper("pst-hook", "working", stdin=json.dumps({"session_id": "one", "tool_name": "Edit"}))
        self.run_helper("pst-hook", "done", stdin=json.dumps({"session_id": "one", "last_assistant_message": "Edited 3 headings\nDetails follow."}))
        self.run_helper("pst-hook", "prompt-idle", stdin=json.dumps({"session_id": "one"}))
        self.run_helper("pst-hook", "clear", stdin=json.dumps({"session_id": "one"}))
        sent = reports(self.terminal)
        self.assertEqual(len(sent), 5, sent)
        self.assertTrue(sent[0].startswith("7501;id=claude:app=claude:state=working:msg="))
        self.assertEqual(message_of(sent[0]), "Proofread the headings in ~/Docs/sync.md; fix capitalisation…")
        self.assertTrue(sent[1].startswith("7501;id=claude:app=claude:state=blocked:kind=permission:msg="))
        self.assertEqual(message_of(sent[1]), "Claude needs your permission to use Bash")
        self.assertEqual(sent[2], sent[0])
        self.assertEqual(message_of(sent[3]), "Edited 3 headings")
        self.assertEqual(sent[4], "7501;id=claude:state=clear")

    def test_pst_hook_reports_idle_when_nothing_finished(self):
        self.run_helper("pst-hook", "idle", stdin=json.dumps({"session_id": "two", "source": "startup"}))
        self.run_helper("pst-hook", "prompt-idle", stdin=json.dumps({"session_id": "two"}))
        self.assertEqual(reports(self.terminal), ["7501;id=claude:app=claude:state=idle"] * 2)
        self.assertEqual(self.run_helper("pst-hook", "working", stdin="not json").returncode, 0)

    @unittest.skipUnless(shutil.which("cc") and shutil.which("make"), "needs cc and make")
    def test_web_project_fails_exactly_one_case(self):
        result = subprocess.run(["make", "-C", str(self.home / "web"), "test"], capture_output=True, text=True, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 failed, 41 passed", result.stdout)
        self.assertEqual(result.stdout.count("FAILED"), 1)


class CheckStatusTest(unittest.TestCase):
    TRACE = [
        "unrelated output",
        trace_line(10.0, 2, 7, "none", "empty"),
        trace_line(11.0, 1, 7, "statusDot", "dots(1)", isSelected=1, status=1),
        trace_line(12.0, 2, 7, "statusDot", "dots(1)", status=1),
        trace_line(12.5, 3, 7, "ring", "ring", progress=1),
        trace_line(13.0, 6, 7, "bell", "bell", bell=1),
        trace_line(14.0, 3, 6, "none", "empty"),
    ]

    def test_accepts_the_expected_marks(self):
        expected = {"tabs": 7, "marks": {"1": {"kind": "statusDot", "isSelected": 1},
                                         "2": {"kind": "statusDot", "status": 1},
                                         "3": {"kind": "ring"}, "6": {"kind": "bell"}}}
        self.assertEqual(RECIPE.check_status(self.TRACE, expected), [])

    def test_reports_a_wrong_or_missing_mark(self):
        expected = {"tabs": 7, "marks": {"3": {"kind": "statusDot"}, "4": {"kind": "statusDot"}}}
        problems = RECIPE.check_status(self.TRACE, expected)
        self.assertEqual(problems, ["tab 3: kind is ring, expected statusDot",
                                    "tab 4: no decision in the trace for a group of 7"])

    def test_reports_a_slot_that_did_not_follow_core(self):
        trace = [trace_line(1.0, 1, 1, "statusDot", "empty", status=1)]
        problems = RECIPE.check_status(trace, {"marks": {"1": {"kind": "statusDot"}}})
        self.assertEqual(problems, ["tab 1: Core answered statusDot but the slot holds empty"])
        fading = [trace_line(1.0, 1, 1, "none", "dots(1) fading")]
        self.assertEqual(RECIPE.check_status(fading, {"marks": {"1": {"kind": "none"}}}), [])

    def test_checks_states_against_status_records(self):
        records = [{"session": "session:2", "state": "blocked", "records": []},
                   {"session": "session:4", "state": "done", "records": []}]
        expected = {"tabs": 7, "marks": {"2": {"kind": "statusDot", "session": "session:2", "state": "blocked"},
                                         "1": {"kind": "statusDot", "session": "session:4", "state": "error"},
                                         "6": {"kind": "bell", "session": "session:9", "state": "idle"}}}
        self.assertEqual(RECIPE.check_status(self.TRACE, expected, records),
                         ["tab 1: session session:4 is done, expected error",
                          "tab 6: no status record for session session:9"])

    def test_command_line_exit_status(self):
        with tempfile.TemporaryDirectory() as scratch:
            trace, expected, records = (Path(scratch) / name for name in ("trace.log", "expected.json", "status.json"))
            trace.write_text("\n".join(self.TRACE) + "\n")
            records.write_text('{"session":"session:2","state":"blocked","records":[]}\n\n{"session":"session:3","state":"working","records":[]}\n')
            tool = [sys.executable, str(RECIPE.ROOT / "Tools/readme-screenshots.py"), "--check-status", str(trace), str(expected),
                    "--status-records", str(records)]
            expected.write_text(json.dumps({"tabs": 7, "marks": {"2": {"kind": "statusDot", "session": "session:2", "state": "blocked"}}}))
            self.assertEqual(subprocess.run(tool, capture_output=True).returncode, 0)
            expected.write_text(json.dumps({"tabs": 7, "marks": {"3": {"kind": "bell"}}}))
            failed = subprocess.run(tool, capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1)
            self.assertIn("tab 3: kind is ring, expected bell", failed.stdout)


if __name__ == "__main__":
    unittest.main()
