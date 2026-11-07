# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""The demo HOME the README's remote screenshots run in.

`Tools/readme-screenshots.py --demo-home DIR` writes it. Everything here is
either configuration or a program that does real work: the helpers report
only what a real command or Claude Code itself does, and no file plays a
status on a timer. Every path is relative to the demo HOME, so nothing names
the person or machine that wrote it.
"""

import json
from pathlib import Path


# Folders the recipe's tabs open in, created even when they hold nothing:
# `Tests` receives the host's own build of the two sync test executables and
# `build` the demo checkout ninja builds (see Docs/images/README.md).
FOLDERS = ("sync", "api", "build", "web", "Docs", "bench", "notes", "typography", "Tests", "bin")

# Repository files copied in unchanged, demo path -> repository path.
COPIES = {
    "sync/Images.cpp": "Source/Core/Protocol/Sync/Images.cpp",
    "sync/btop.conf": "Docs/images/btop.conf",
    "sync/noir.theme": "Docs/images/noir.theme",
    "Docs/sync.md": "Docs/sync.md",
}

def repository_file(root, source):
    """A repository file, from the checkout that holds it.

    The libraries the app carries are checkouts of their own under Libraries/;
    in a checkout that holds every repository the file is in `root`.
    """
    for checkout in (Path(root), Path(root) / "Libraries" / "ubiquitty-core", Path(root) / "Libraries" / "ubiquitty-kit"):
        if (checkout / source).is_file():
            return checkout / source
    return Path(root) / source


EXECUTABLES = ("bin/status-run", "bin/pst-hook", "bin/bench-sync")

ZSHRC = r'''PROMPT='%F{4}demo%f %F{12}%1~%f $ '
HISTFILE=/dev/null
path=("$HOME/bin" $path)
export EDITOR=nvim

# The pane's terminal, so the pst-hook reports land in the pane that runs this
# Claude Code. Nothing else: Claude Code sees the environment any program does.
function claude {
    UBQ_STATUS_TTY="$(tty)" command claude "$@"
}
'''

NEOVIM_INIT = '''vim.opt.number = true
vim.opt.wrap = false
vim.opt.swapfile = false
vim.opt.laststatus = 2
vim.opt.statusline = " %t%=[%{&filetype}]  %l:%c  %p%% "
'''

# Neovim's markdown ftplugin turns wrapping back on for `sync.md`.
NEOVIM_MARKDOWN = "vim.opt_local.wrap = false\n"

HOST_CONFIG = '''[appearance]
theme = "Noir"
follow_system = false
'''

# The capturing Mac's config.toml. It is not part of the HOME copied to the
# host; it is written beside it, hidden, for the capture to load.
CLIENT_CONFIG = '''[font]
family = "JetBrains Mono"
size = 13
ligatures = true

[appearance]
theme = "Noir"
follow_system = false
pane_title_bars = true

[tabs]
show_shortcuts = "off"

[[tags]]
name = "devbox"
color = "green"
match_host = "dev-box"

[title]
window_dimensions = true
pane_dimensions = false
tab_directory_path = false
pane_program_status = true
window_program_status = true
tab_program_status = false
'''

NOTES = '''# Notes

- Check image placement after reconnecting.
- Review the keyboard navigation.
'''


def hook(command, matcher=None):
    entry = {"hooks": [{"type": "command", "command": '"$HOME"/bin/pst-hook ' + command}]}
    if matcher is not None:
        entry = {"matcher": matcher, **entry}
    return entry


# Each of Claude Code's lifecycle events, mapped to the state it means.
# PreToolUse fires before a permission prompt and PostToolUse once the tool
# has run, so the approved tool's completion is what turns blocked back to
# working.
CLAUDE_SETTINGS = {
    "hooks": {
        "SessionStart": [hook("idle", "startup|resume|clear")],
        "UserPromptSubmit": [hook("working")],
        "PreToolUse": [hook("working", "*")],
        "PostToolUse": [hook("working", "*")],
        "Notification": [hook("blocked permission", "permission_prompt"), hook("prompt-idle", "idle_prompt")],
        "Stop": [hook("done")],
        "SessionEnd": [hook("clear")],
    }
}

DEMO_SOURCES = {
    "bin/status-run": r'''#!/usr/bin/env python3
"""status-run LABEL -- COMMAND [ARGUMENT...]

Runs COMMAND, passes its output through, and reports what it is really doing
to the terminal: OSC 3008 opens a command context and closes it with the exit
status; OSC 7501 says working, then done or error; OSC 9;4 carries the
progress read from the command's own `[n/N]` or `n/N cases` lines. Nothing is
reported that the command did not print or return. Exits with the command's
status.
"""

import base64
import os
import re
import signal
import subprocess
import sys

ESC = "\033"
ST = ESC + "\\"
PROGRESS = (re.compile(r"^\[(\d+)/(\d+)\]"), re.compile(r"\b(\d+)/(\d+) cases\b"))
SUMMARY = re.compile(r"\b\d+ (?:failed|passed)\b")
LABEL = re.compile(r"^[A-Za-z0-9_.+-]{1,32}$")


def open_terminal():
    """The pane's terminal, so piped output cannot swallow the reports."""
    for path in (os.environ.get("UBQ_STATUS_TTY"), "/dev/tty"):
        if not path:
            continue
        try:
            return os.open(path, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND)
        except OSError:
            continue
    return None


def report(terminal, body):
    if terminal is not None:
        # One write per sequence, so no other writer lands inside it.
        os.write(terminal, (ESC + "]" + body + ST).encode("utf-8"))


def printable(text):
    return "".join(c for c in text if c >= " " and not "\x7f" <= c <= "\x9f")


def message(text):
    text = " ".join(printable(text).split())
    data = text.encode("utf-8")[:240]
    return base64.b64encode(data.decode("utf-8", "ignore").encode("utf-8")).decode("ascii")


def context_value(text):
    return printable(text).replace("\\", "\\x5c").replace(";", "\\x3b")


def main(arguments):
    if len(arguments) < 3 or arguments[1] != "--" or not LABEL.match(arguments[0]):
        sys.stderr.write("usage: status-run LABEL -- COMMAND [ARGUMENT...]\n"
                         "LABEL is 1-32 letters, digits, '_', '.', '+' or '-'.\n")
        return 2
    label, command = arguments[0], arguments[2:]
    terminal = open_terminal()
    context = f"status-run.{label}.{os.getpid()}"
    report(terminal, f"3008;start={context};type=command;cmdline={context_value(' '.join(command))}")
    report(terminal, f"7501;id={label}:app={label}:state=working")
    summary = None
    shown = -1
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as error:
        sys.stderr.write(f"status-run: {command[0]}: {error.strerror}\n")
        status = 127
        report(terminal, f"3008;end={context};exit=failure;status={status}")
        report(terminal, f"7501;id={label}:app={label}:state=error:msg={message(f'exit {status}')}")
        return status
    # The terminal's interrupt reaches the child through the process group;
    # this process outlives it to report how it ended.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    for raw in iter(child.stdout.readline, b""):
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if SUMMARY.search(line):
            summary = line.strip()
        for pattern in PROGRESS:
            found = pattern.search(line)
            if found and int(found.group(2)) > 0:
                percent = min(100, int(found.group(1)) * 100 // int(found.group(2)))
                if percent != shown:
                    shown = percent
                    report(terminal, f"9;4;1;{percent}")
                    report(terminal, f"7501;id={label}:app={label}:state=working:progress={percent}")
                break
    status = child.wait()
    report(terminal, "9;4;0")
    if status == 0:
        report(terminal, f"3008;end={context};exit=success;status=0")
        report(terminal, f"7501;id={label}:app={label}:state=done" + (f":msg={message(summary)}" if summary else ""))
        return 0
    if status < 0:
        name = signal.Signals(-status).name
        ending = "interrupt" if -status in (signal.SIGINT, signal.SIGTERM) else "crash"
        report(terminal, f"3008;end={context};exit={ending};signal={name}")
        report(terminal, f"7501;id={label}:app={label}:state=error:msg={message(summary or name)}")
        return 128 - status
    report(terminal, f"3008;end={context};exit=failure;status={min(status, 255)}")
    report(terminal, f"7501;id={label}:app={label}:state=error:msg={message(summary or f'exit {status}')}")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
''',
    "bin/pst-hook": r'''#!/usr/bin/env python3
"""pst-hook STATE [KIND] — a Claude Code hook that reports Claude's own state.

Claude Code runs it on its lifecycle events with the event's JSON on standard
input (see the demo HOME's .claude/settings.json). It writes one OSC 7501
record, `id=claude:app=claude:state=STATE`, to the pane's terminal: the one
named by $UBQ_STATUS_TTY, which the demo `claude` function exports, else
/dev/tty. The message is the event's own text: the notification's `message`,
the start of the submitted `prompt`, or the start of Claude's last reply.

STATE is idle, working, blocked, done or clear. `prompt-idle` is Claude's idle
notification: it reports idle unless this session's last report was done, so a
finished answer that waits at the prompt still reads as done.

A hook's standard output becomes Claude's context for some events, so this
prints nothing, and any failure leaves Claude untouched.
"""

import base64
import json
import os
import re
import sys
import tempfile

ESC = "\033"
STATES = {"idle", "working", "blocked", "done", "clear", "prompt-idle"}
EXCERPT_BYTES = 60


def printable(text):
    text = "".join(c for c in text if c >= " " and not "\x7f" <= c <= "\x9f")
    return " ".join(text.split())


def excerpt(text, limit=EXCERPT_BYTES):
    data = printable(text).encode("utf-8")
    if len(data) <= limit:
        return data.decode("utf-8")
    return data[:limit].decode("utf-8", "ignore").rstrip() + "…"


def encoded(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def last_reply(event):
    """The first line of Claude's last reply, from the event or its transcript."""
    if isinstance(event.get("last_assistant_message"), str):
        return event["last_assistant_message"].strip().splitlines()[0] if event["last_assistant_message"].strip() else ""
    path = event.get("transcript_path")
    if not isinstance(path, str):
        return ""
    reply = ""
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "assistant":
                    continue
                content = entry.get("message", {}).get("content", [])
                texts = [part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"]
                text = "\n".join(t for t in texts if t.strip()).strip()
                if text:
                    reply = text.splitlines()[0]
    except OSError:
        return ""
    return reply


def memory(event):
    session = re.sub(r"[^A-Za-z0-9_.-]", "", str(event.get("session_id", "")))[:64] or "unknown"
    directory = os.path.join(tempfile.gettempdir(), f"pst-hook-{os.getuid()}")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    return os.path.join(directory, session + ".json")


def main(arguments):
    if not arguments or arguments[0] not in STATES:
        return 0
    state = arguments[0]
    kind = arguments[1] if len(arguments) > 1 and arguments[1] in ("permission", "question", "auth") else ""
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            event = {}
    except ValueError:
        event = {}
    remembered_path = memory(event)
    try:
        with open(remembered_path, encoding="utf-8") as source:
            remembered = json.load(source)
    except (OSError, ValueError):
        remembered = {}
    if state == "prompt-idle":
        if remembered.get("state") == "done":
            return 0
        state = "idle"

    text = ""
    if isinstance(event.get("prompt"), str):
        text = excerpt(event["prompt"])
        remembered["prompt"] = text
    elif state == "blocked" and isinstance(event.get("message"), str):
        text = excerpt(event["message"], 160)
    elif state == "working":
        text = remembered.get("prompt", "")
    elif state == "done":
        text = excerpt(last_reply(event))

    if state == "clear":
        body = "7501;id=claude:state=clear"
    else:
        body = f"7501;id=claude:app=claude:state={state}"
        if kind and state == "blocked":
            body += f":kind={kind}"
        if text:
            body += f":msg={encoded(text)}"
    remembered["state"] = state
    try:
        with open(remembered_path, "w", encoding="utf-8") as sink:
            json.dump(remembered, sink)
    except OSError:
        pass

    for path in (os.environ.get("UBQ_STATUS_TTY"), "/dev/tty"):
        if not path:
            continue
        try:
            terminal = os.open(path, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND)
        except OSError:
            continue
        try:
            os.write(terminal, (ESC + "]" + body + ESC + "\\").encode("ascii"))
        finally:
            os.close(terminal)
        break
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:  # A broken report must never block Claude.
        sys.exit(0)
''',
    "bin/bench-sync": r'''#!/usr/bin/env python3
"""bench-sync [RUNS] — times ~/Tests/test_sync_images, five runs by default."""

import os
import statistics
import subprocess
import sys
import time

test = os.path.expanduser("~/Tests/test_sync_images")
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
if not os.access(test, os.X_OK):
    sys.exit(f"bench-sync: {test} is not built for this host")
timings = []
for run in range(1, runs + 1):
    started = time.perf_counter()
    status = subprocess.run([test], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    elapsed = time.perf_counter() - started
    if status:
        sys.exit(f"bench-sync: run {run} exited {status}")
    timings.append(elapsed)
    print(f"run {run}/{runs}  {elapsed * 1000:8.1f} ms", flush=True)
print(f"median {statistics.median(timings) * 1000:.1f} ms, best {min(timings) * 1000:.1f} ms")
''',
    "api/Client.h": r'''#pragma once

#include <chrono>
#include <optional>
#include <string>
#include <vector>

namespace demo {

struct Response {
    int status = 0;
    std::string body;
};

class Client {
public:
    explicit Client(std::string baseURL);

    void setTimeout(std::chrono::milliseconds timeout);
    std::chrono::milliseconds timeout() const { return m_timeout; }

    std::string urlFor(const std::string& path) const;
    std::optional<Response> get(const std::string& path) const;
    std::optional<Response> post(const std::string& path, const std::string& body) const;
    std::vector<std::string> listSessions() const;

private:
    std::optional<Response> send(const std::string& method, const std::string& path, const std::string& body) const;

    std::string m_baseURL;
    std::chrono::milliseconds m_timeout { 5000 };
};

} // namespace demo
''',
    "api/Client.cpp": r'''#include "Client.h"

#include <sstream>
#include <utility>

namespace demo {

Client::Client(std::string baseURL)
    : m_baseURL(std::move(baseURL))
{
    while (!m_baseURL.empty() && m_baseURL.back() == '/')
        m_baseURL.pop_back();
}

void Client::setTimeout(std::chrono::milliseconds timeout)
{
    m_timeout = timeout.count() > 0 ? timeout : std::chrono::milliseconds { 5000 };
}

std::string Client::urlFor(const std::string& path) const
{
    if (path.empty() || path.front() != '/')
        return m_baseURL + "/" + path;
    return m_baseURL + path;
}

std::optional<Response> Client::get(const std::string& path) const
{
    return send("GET", path, {});
}

std::optional<Response> Client::post(const std::string& path, const std::string& body) const
{
    return send("POST", path, body);
}

std::vector<std::string> Client::listSessions() const
{
    std::vector<std::string> sessions;
    auto response = get("/sessions");
    if (!response || response->status != 200)
        return sessions;
    std::istringstream lines(response->body);
    for (std::string line; std::getline(lines, line);) {
        if (!line.empty())
            sessions.push_back(line);
    }
    return sessions;
}

std::optional<Response> Client::send(const std::string& method, const std::string& path, const std::string& body) const
{
    // The demo has no network: it answers from a fixed table.
    if (method == "GET" && path == "/sessions")
        return Response { 200, "build\nweb\ndocs\n" };
    if (method == "POST" && !body.empty())
        return Response { 201, body };
    return Response { 404, {} };
}

} // namespace demo
''',
    "web/web.h": r'''#ifndef WEB_H
#define WEB_H

#include <stddef.h>

/* Writes a lower-case, dash-separated slug of `text`; returns its length. */
size_t slugify(const char *text, char *slug, size_t capacity);

/* Decodes %XX escapes and '+'; returns the length, or -1 on a bad escape. */
int percent_decode(const char *text, char *decoded, size_t capacity);

/* Finds `key` in a query string and decodes its value; -1 when absent. */
int query_value(const char *query, const char *key, char *value, size_t capacity);

#endif
''',
    "web/web.c": r'''#include "web.h"

#include <ctype.h>
#include <string.h>

size_t slugify(const char *text, char *slug, size_t capacity)
{
    size_t length = 0;
    int separated = 0;
    if (capacity == 0)
        return 0;
    for (; *text; ++text) {
        unsigned char c = (unsigned char)*text;
        if (isalnum(c)) {
            if (length + 1 >= capacity)
                break;
            slug[length++] = (char)tolower(c);
            separated = 0;
        } else if (length > 0 && !separated && length + 1 < capacity) {
            slug[length++] = '-';
            separated = 1;
        }
    }
    slug[length] = '\0';
    return length;
}

static int hex_digit(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

static int decode_span(const char *text, size_t span, char *decoded, size_t capacity)
{
    size_t length = 0;
    for (size_t index = 0; index < span; ++index) {
        char c = text[index];
        if (length + 1 >= capacity)
            return -1;
        if (c == '%') {
            int high, low;
            if (index + 2 >= span)
                return -1;
            high = hex_digit(text[index + 1]);
            low = hex_digit(text[index + 2]);
            if (high < 0 || low < 0)
                return -1;
            decoded[length++] = (char)(high * 16 + low);
            index += 2;
        } else {
            decoded[length++] = c == '+' ? ' ' : c;
        }
    }
    decoded[length] = '\0';
    return (int)length;
}

int percent_decode(const char *text, char *decoded, size_t capacity)
{
    return decode_span(text, strlen(text), decoded, capacity);
}

int query_value(const char *query, const char *key, char *value, size_t capacity)
{
    size_t key_length = strlen(key);
    if (*query == '?')
        ++query;
    while (*query) {
        const char *end = strchr(query, '&');
        size_t pair = end ? (size_t)(end - query) : strlen(query);
        if (pair >= key_length && strncmp(query, key, key_length) == 0) {
            if (pair == key_length)
                return decode_span("", 0, value, capacity);
            if (query[key_length] == '=')
                return decode_span(query + key_length + 1, pair - key_length - 1, value, capacity);
        }
        query += pair;
        if (*query == '&')
            ++query;
    }
    return -1;
}
''',
    "web/test_web.c": r'''#include "web.h"

#include <stdio.h>
#include <string.h>

enum { SLUG, DECODE, QUERY };

struct Case {
    int function;
    const char *input;
    const char *key;
    const char *expected; /* NULL: the call reports -1 */
};

static const struct Case cases[] = {
    { SLUG, "Hello world", NULL, "hello-world" },
    { SLUG, "Sync images", NULL, "sync-images" },
    { SLUG, "  leading spaces", NULL, "leading-spaces" },
    { SLUG, "UPPER case", NULL, "upper-case" },
    { SLUG, "tabs\tbetween\twords", NULL, "tabs-between-words" },
    { SLUG, "many   spaces   between", NULL, "many-spaces-between" },
    { SLUG, "dots.in.names", NULL, "dots-in-names" },
    { SLUG, "under_score", NULL, "under-score" },
    { SLUG, "v2 release 10", NULL, "v2-release-10" },
    { SLUG, "a--b", NULL, "a-b" },
    { SLUG, "Caf\xc3\xa9 menu", NULL, "caf-menu" },
    { SLUG, "", NULL, "" },
    { SLUG, "!!!", NULL, "" },
    { SLUG, "x", NULL, "x" },
    { SLUG, "Q&A: notes", NULL, "q-a-notes" },
    { SLUG, "2026 roadmap", NULL, "2026-roadmap" },
    { SLUG, "path/to/page", NULL, "path-to-page" },
    { SLUG, "Ready? Set. Go!", NULL, "ready-set-go" },
    { DECODE, "plain", NULL, "plain" },
    { DECODE, "a%20b", NULL, "a b" },
    { DECODE, "a+b", NULL, "a b" },
    { DECODE, "%41%42%43", NULL, "ABC" },
    { DECODE, "%7e", NULL, "~" },
    { DECODE, "100%25", NULL, "100%" },
    { DECODE, "", NULL, "" },
    { DECODE, "%", NULL, NULL },
    { DECODE, "%4", NULL, NULL },
    { DECODE, "%zz", NULL, NULL },
    { DECODE, "caf%C3%A9", NULL, "caf\xc3\xa9" },
    { DECODE, "a%2Bb", NULL, "a+b" },
    { QUERY, "?page=2", "page", "2" },
    { QUERY, "page=2&sort=name", "sort", "name" },
    { QUERY, "q=sync+images", "q", "sync images" },
    { QUERY, "q=a%26b", "q", "a&b" },
    { QUERY, "a=1&b=2", "c", NULL },
    { QUERY, "flag&x=1", "flag", "" },
    { QUERY, "pages=3&page=4", "page", "4" },
    { QUERY, "", "page", NULL },
    { QUERY, "empty=", "empty", "" },
    { QUERY, "x=1&x=2", "x", "1" },
    { QUERY, "bad=%zz", "bad", NULL },
    { QUERY, "?tab=build&tab=web", "tab", "build" },
};

static const char *names[] = { "slugify", "percent_decode", "query_value" };

int main(void)
{
    const int total = (int)(sizeof cases / sizeof cases[0]);
    int failed = 0;
    for (int index = 0; index < total; ++index) {
        const struct Case *test = &cases[index];
        char got[128];
        int length;
        if (test->function == SLUG)
            length = (int)slugify(test->input, got, sizeof got);
        else if (test->function == DECODE)
            length = percent_decode(test->input, got, sizeof got);
        else
            length = query_value(test->input, test->key, got, sizeof got);
        int passed = test->expected ? length >= 0 && strcmp(got, test->expected) == 0 : length < 0;
        printf("[%d/%d] %s(\"%s\") %s\n", index + 1, total, names[test->function], test->input, passed ? "ok" : "FAILED");
        if (!passed) {
            printf("    expected \"%s\", got \"%s\"\n", test->expected ? test->expected : "(error)", length >= 0 ? got : "(error)");
            ++failed;
        }
        fflush(stdout);
    }
    printf("%d failed, %d passed\n", failed, total - failed);
    return failed ? 1 : 0;
}
''',
    "web/Makefile": 'CC ?= cc\nCFLAGS ?= -std=c11 -Wall -Wextra -O1\n\ntest: test_web\n\t./test_web\n\ntest_web: web.c web.h test_web.c\n\t$(CC) $(CFLAGS) -o $@ web.c test_web.c\n\nclean:\n\trm -f test_web\n\n.PHONY: test clean\n',
}


def files(root, typography_feed):
    """Every file of the demo HOME, demo path -> bytes."""
    result = {
        ".zshrc": ZSHRC,
        ".config/nvim/init.lua": NEOVIM_INIT,
        ".config/nvim/after/ftplugin/markdown.lua": NEOVIM_MARKDOWN,
        ".config/ubiquitty/config.toml": HOST_CONFIG,
        ".claude/settings.json": json.dumps(CLAUDE_SETTINGS, indent=2) + "\n",
        ".readme-demo-client.toml": CLIENT_CONFIG,
        "notes/notes.md": NOTES,
        "typography/workspace-typography.ans": typography_feed,
        **DEMO_SOURCES,
    }
    result = {path: text.encode("utf-8") for path, text in result.items()}
    for path, source in COPIES.items():
        result[path] = repository_file(root, source).read_bytes()
    return result
