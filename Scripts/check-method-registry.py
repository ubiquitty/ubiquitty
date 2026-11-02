#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-method-registry.py — no operation is exposed outside the registry.

Source/Core/Protocol/Control/MethodRegistry.cpp is the one table of what
Ubiquitty exposes to people and agents. Every surface reaches an operation by
looking its name up there, so a name compared with a literal of the surface's
own is an operation served around the table. This refuses:

  - a control-socket dispatcher (Server.cpp) that compares a method's name with
    any literal, in either order, by equality, prefix or strcmp;
  - a control-socket method the macOS host (ControlHost.swift) handles without
    a registry entry naming it, read from every pattern of every case label;
  - an entry naming a control method with no route, a route with no control
    method, or a route to the host for a method the host does not handle;
  - an MCP tool AgentMCP.cpp dispatches without an entry naming it, and an MCP
    protocol method it answers that is not one the server is known to speak;
  - in `ubq`'s main.cpp, a comparison of argv, the verb, or an operation name
    with a literal anywhere but the argument parser, and in the parser a
    literal that is no registered verb: the only route from argv to work is
    findCommandLineVerb and the operation table;
  - a `ubq` verb whose entry main.cpp's operation table does not run, or an
    operation the table runs that no entry names;
  - an entry naming a control method or tool that nothing dispatches, which
    would advertise an operation no call can reach;
  - a completion script whose verb list, or whose `api` subverb list, is not
    exactly the registry's.

The registry is read as text: one field per line, `.controlMethod = "..."`.

    python3 Scripts/check-method-registry.py
    python3 Scripts/check-method-registry.py --self-test
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = "check-method-registry"

REGISTRY = "Source/Core/Protocol/Control/MethodRegistry.cpp"
SERVER = "Source/Core/Protocol/Control/Server.cpp"
CONTROL_HOST = "Source/Platform/macOS/App/ControlHost.swift"
AGENT_MCP = "Source/Agent/AgentMCP.cpp"
AGENT_MAIN = "Source/Agent/main.cpp"
BASH_COMPLETION = "Resources/shell-integration/ubq.bash"
ZSH_COMPLETION = "Resources/shell-integration/ubq.zsh"

# Host verbs that are not client methods: the dispatcher's own lookup of a
# request's window and pane before a gated verb runs.
HOST_ONLY_VERBS = {"target"}

# The JSON-RPC methods of MCP itself, which carry the tools rather than being
# operations; every operation is a tool reached through tools/call.
MCP_PROTOCOL_METHODS = {"initialize", "tools/list", "tools/call", "ping"}

# The function in main.cpp that reads argv; the only place a verb is compared
# with a literal, to pick which flags it takes.
ARGUMENT_PARSER = "parseCommandLine"

FIELDS = ("name", "controlMethod", "commandLineVerb", "mcpTool")

# The routes the server answers itself; every other route but NotServed hands
# the method to the host under its control-method name.
SERVER_ROUTES = {"Handshake", "ListOperations", "DescribeOperation"}

LITERAL = r'"((?:[^"\\\n]|\\.)*)"'


def registryEntries(text):
    """Returns one dict per `MethodDescriptor { ... }` block, its name fields read."""
    entries = []
    for block in re.split(r"\bMethodDescriptor\s*\{", text)[1:]:
        entry = {}
        for field in FIELDS:
            match = re.search(r"\.%s\s*=\s*\"([^\"]*)\"" % field, block)
            if match:
                entry[field] = match.group(1)
        route = re.search(r"\.controlRoute\s*=\s*ControlRoute::(\w+)", block)
        if route:
            entry["controlRoute"] = route.group(1)
        syncMatch = re.search(r"\.syncMethod\s*=\s*\"([^\"]*)\"", block)
        entry["syncMethod"] = syncMatch.group(1) if syncMatch else ""
        entry["statesRoles"] = bool(re.search(r"^\s*\.roles\s*=(?!=)", block, re.M))
        entry["statesScope"] = bool(re.search(r"^\s*\.scope\s*=(?!=)", block, re.M))
        entry["statesTarget"] = bool(re.search(r"^\s*\.target\s*=(?!=)", block, re.M))
        if "name" in entry:
            entries.append(entry)
    return entries


def registered(entries, field):
    return {entry[field] for entry in entries if entry.get(field)}


def stripComments(text):
    """Blanks // and /* */ comments, keeping string literals and line numbers."""
    pattern = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"', re.S)
    return pattern.sub(lambda match: match.group(0) if match.group(0).startswith('"') else re.sub(r"[^\n]", " ", match.group(0)), text)


def literalComparisons(text, operand):
    """Every (form, literal) where a string literal is compared with `operand`.

    `operand` is a regular expression for the compared expression. Equality and
    inequality are read in either order; a prefix, suffix, search or compare
    call on it, and strcmp with it on either side, are read too.
    """
    lead = r"(?<![\w.>])"
    tail = r"(?![\w(\[.])"
    found = []
    for form, pattern in (
        ("equality", r"%s(?:%s)%s\s*[!=]=\s*%s" % (lead, operand, tail, LITERAL)),
        ("equality", r"%s\s*[!=]=\s*%s(?:%s)%s" % (LITERAL, lead, operand, tail)),
        ("call", r"%s(?:%s)\s*\.\s*(?:starts_with|ends_with|compare|find|rfind|contains)\s*\(\s*%s" % (lead, operand, LITERAL)),
        ("call", r"\bstrn?(?:case)?cmp\s*\(\s*(?:%s)\s*,\s*%s" % (operand, LITERAL)),
        ("call", r"\bstrn?(?:case)?cmp\s*\(\s*%s\s*,\s*(?:%s)\s*[,)]" % (LITERAL, operand)),
    ):
        for match in re.finditer(pattern, text):
            found.append((form, match.group(1), text.count("\n", 0, match.start()) + 1))
    return found


def functionBody(text, name):
    """The (start, end) offsets of a function's body, or None when it is not defined."""
    match = re.search(r"\b%s\s*\([^;{]*\)\s*\{" % re.escape(name), text)
    if not match:
        return None
    depth = 0
    for index in range(match.end() - 1, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return (match.end(), index)
    return None


def serverFindings(text):
    """Server.cpp compares no method or name with a literal: each is routed by its entry."""
    text = stripComments(text)
    lines = []
    for _, literal, line in literalComparisons(text, r"method|name"):
        lines.append("  %s:%d compares a method with '%s' rather than following its entry's route" % (SERVER, line, literal))
    return lines


def hostVerbs(text):
    """The verbs ControlHost.swift's answer(verb:) handles: every pattern of every case."""
    start = text.find("func answer(verb:")
    if start < 0:
        return set()
    body = stripComments(text[start:])
    verbs = set()
    for label in re.findall(r"^\s*case\s+((?:\"[^\"]*\"\s*,\s*)*\"[^\"]*\")\s*:", body, re.M):
        verbs |= set(re.findall(r"\"([^\"]*)\"", label))
    verbs |= {literal for _, literal, _ in literalComparisons(body, r"verb")}
    return verbs


def mcpTools(text):
    """The tool names AgentMCP.cpp compares a name with, or catalogues by hand."""
    text = stripComments(text)
    found = {literal for _, literal, _ in literalComparisons(text, r"name")}
    found |= set(re.findall(r"addTool\(\s*\w+\s*,\s*\"([^\"]+)\"", text))
    return found


def mcpProtocolFindings(text):
    """AgentMCP.cpp answers only the JSON-RPC methods MCP itself defines."""
    text = stripComments(text)
    lines = []
    for form, literal, line in literalComparisons(text, r"method"):
        if form != "equality" or literal not in MCP_PROTOCOL_METHODS:
            lines.append("  %s:%d answers JSON-RPC method '%s', which is not one MCP defines; an operation is a tool"
                         % (AGENT_MCP, line, literal))
    for form, literal, line in literalComparisons(text, r"name"):
        if form != "equality":
            lines.append("  %s:%d matches tool names by '%s' rather than by the registry" % (AGENT_MCP, line, literal))
    return lines


def commandLineFindings(text, entries):
    """main.cpp reaches work only through findCommandLineVerb and the operation table."""
    text = stripComments(text)
    verbs = registered(entries, "commandLineVerb")
    words = verbs | {verb.split(" ")[0] for verb in verbs}
    parser = functionBody(text, ARGUMENT_PARSER)
    lines = []
    if parser is None:
        return ["  %s defines no %s, so where argv is read cannot be checked" % (AGENT_MAIN, ARGUMENT_PARSER)]
    argv = r"(?:std::(?:string_view|string)\s*\(\s*)?argv\s*\[[^\]]*\]\s*\)?"
    for _, literal, line in literalComparisons(text, argv):
        lines.append("  %s:%d compares argv with '%s'; argv reaches work only through %s"
                     % (AGENT_MAIN, line, literal, ARGUMENT_PARSER))
    for _, literal, line in literalComparisons(text, r"(?:parsed\s*\.\s*)?verb|method|name"):
        offset = sum(len(row) + 1 for row in text.split("\n")[:line - 1])
        isInParser = parser[0] <= offset <= parser[1]
        if not isInParser:
            lines.append("  %s:%d compares a verb or operation name with '%s' outside %s; work is chosen by the operation table"
                         % (AGENT_MAIN, line, literal, ARGUMENT_PARSER))
        elif literal not in words:
            lines.append("  %s:%d parses verb '%s', which no registry entry names" % (AGENT_MAIN, line, literal))
    if "findCommandLineVerb(" not in text[parser[0]:parser[1]]:
        lines.append("  %s resolves no verb through the registry" % ARGUMENT_PARSER)
    return lines


def operationTable(text):
    """The registry names main.cpp's operation table runs: `{ "ubq.ls", &listSessions }`."""
    return set(re.findall(r'\{\s*"([a-z][a-z0-9_.]*)"\s*,\s*&\w+\s*\}', text))


def bashCompletionVerbs(text):
    """(verbs, api subverbs) the bash script offers, from its two lists."""
    verbs = re.search(r'\blocal\s+verbs="((?:[^"\\]|\\[\s\S])*)"', text)
    api = re.search(r"\n\s*api\)\s*\n(?:[^\n]*\n){0,2}?[^\n]*compgen\s+-W\s+\"([^\"]*)\"", text)
    return (set(verbs.group(1).replace("\\\n", " ").split()) if verbs else set(),
            set(api.group(1).split()) if api else set())


def zshCompletionVerbs(text):
    """(verbs, api subverbs) the zsh script offers, from its two lists."""
    block = re.search(r"\bverbs=\(\s*\n(.*?)\n\s*\)", text, re.S)
    verbs = set(re.findall(r"^\s*'([\w-]+):", block.group(1), re.M)) if block else set()
    api = re.search(r"_values\s+'api verb'\s+([^\n]*)", text)
    return verbs, set(api.group(1).split()) if api else set()


def completionGaps(entries, scripts):
    """Each script's verb and api subverb lists, compared as sets with the registry's."""
    verbs = registered(entries, "commandLineVerb")
    wanted = {verb.split(" ")[0] for verb in verbs}
    wantedAPI = {verb.split(" ")[1] for verb in verbs if verb.startswith("api ")}
    lines = []
    for path, (offered, offeredAPI) in scripts:
        for verb in sorted(wanted - offered):
            lines.append("  command-line verb '%s' is missing from the verb list in %s" % (verb, path))
        for verb in sorted(offered - wanted):
            lines.append("  %s offers verb '%s', which no registry entry names" % (path, verb))
        for verb in sorted(wantedAPI - offeredAPI):
            lines.append("  command-line verb 'api %s' is missing from the api list in %s" % (verb, path))
        for verb in sorted(offeredAPI - wantedAPI):
            lines.append("  %s offers 'api %s', which no registry entry names" % (path, verb))
    return lines


def operationGaps(entries, table):
    """Verbs whose entry the operation table does not run, and table rows no entry names."""
    lines = []
    names = {entry["name"] for entry in entries}
    for entry in entries:
        if entry.get("commandLineVerb") and entry["name"] not in table:
            lines.append("  command-line verb '%s' (%s) is not run through the operation table in %s"
                         % (entry["commandLineVerb"], entry["name"], AGENT_MAIN))
    for name in sorted(table - names):
        lines.append("  the operation table in %s runs '%s', which no registry entry names" % (AGENT_MAIN, name))
    return lines


def findings(entries, host, tools):
    """Returns one line per operation exposed outside the registry, or advertised and unreachable."""
    control = registered(entries, "controlMethod")
    mcp = registered(entries, "mcpTool")
    lines = []
    for verb in sorted(host - control - HOST_ONLY_VERBS):
        lines.append("  host verb '%s' is handled in %s with no registry entry" % (verb, CONTROL_HOST))
    for tool in sorted(tools - mcp):
        lines.append("  MCP tool '%s' is dispatched in %s with no registry entry" % (tool, AGENT_MCP))
    for entry in entries:
        method = entry.get("controlMethod", "")
        route = entry.get("controlRoute", "")
        if method and route in ("", "NotServed"):
            lines.append("  registry entry '%s' names control method '%s' with no route to serve it" % (entry["name"], method))
        elif not method and route not in ("", "NotServed"):
            lines.append("  registry entry '%s' routes the control socket to no method name" % entry["name"])
        elif method and route not in SERVER_ROUTES and method not in host:
            lines.append("  registry entry routes control method '%s' to the host, which %s does not handle"
                         % (method, CONTROL_HOST))
    for tool in sorted(mcp - tools):
        lines.append("  registry entry names MCP tool '%s', which %s does not dispatch" % (tool, AGENT_MCP))
    for entry in entries:
        # Who may call over Sync, and under what scope, is stated on the
        # entry or the host has nothing to check a caller against.
        if entry.get("syncMethod") and not (entry.get("statesRoles") and entry.get("statesScope") and entry.get("statesTarget")):
            lines.append("  registry entry '%s' names Sync method '%s' without the roles that may call it, the "
                         "scope it needs and what it is addressed to" % (entry["name"], entry["syncMethod"]))
        elif not entry.get("syncMethod") and (entry.get("statesRoles") or entry.get("statesScope") or entry.get("statesTarget")):
            lines.append("  registry entry '%s' states roles, a scope or a target for a Sync call it does not serve" % entry["name"])
    names = [entry["name"] for entry in entries]
    for name in sorted({name for name in names if names.count(name) > 1}):
        lines.append("  registry name '%s' is given to more than one entry" % name)
    return lines


ENTRY = '''MethodDescriptor {
        .name = "%s",
        .controlMethod = "%s",
        .controlRoute = ControlRoute::%s,
        .commandLineVerb = "%s",
        .mcpTool = "%s",
    },'''

HOST_LS = 'func answer(verb: String) {\n        case "ls":\n        case "target":\n'

# main.cpp as the gate expects it: argv read only by the parser, the verb
# resolved through the registry, and the parser comparing registered verbs.
MAIN_PARSER = '''ParsedCommandLine parseCommandLine(int argc, char** argv)
{
    %s
    parsed.method = Control::findCommandLineVerb(parsed.verb);
    if (parsed.verb == "read" && argument == "--screen") {}
}
'''
MAIN_CLEAN = MAIN_PARSER % ""
MAIN_ENTRIES = [("ubq.read", "", "NotServed", "read", ""), ("ubq.kill", "", "NotServed", "kill", "")]

BASH_CLEAN = 'local verbs="read kill \\\napi"\n    case "$verb" in\n        api)\n            if [[ $COMP_CWORD -eq 2 ]]; then\n                COMPREPLY=( $(compgen -W "list" -- "$cur") )\n'
ZSH_CLEAN = "verbs=(\n        'read:read'\n        'kill:end'\n        'api:api'\n    )\n                        _values 'api verb' list\n"
COMPLETION_ENTRIES = [{"name": "ubq.read", "commandLineVerb": "read"}, {"name": "ubq.kill", "commandLineVerb": "kill"},
                      {"name": "ubq.api.list", "commandLineVerb": "api list"}]


def registryOf(rows):
    return registryEntries("\n".join(ENTRY % row for row in rows))


def mainCase(source, rows=None):
    return lambda: commandLineFindings(source, registryOf(rows or MAIN_ENTRIES))


def syncCase(name, *fields):
    """An entry reached from the command line, with the given Sync fields appended."""
    block = (ENTRY % (name, "", "NotServed", "wipe", "")).replace("    },", "".join("        %s\n" % field for field in fields) + "    },")
    return lambda: findings(registryEntries(block), set(), set())


def completionCase(bash, zsh):
    return lambda: completionGaps(COMPLETION_ENTRIES, [("bash", bashCompletionVerbs(bash)), ("zsh", zshCompletionVerbs(zsh))])


SELFTEST_CASES = (
    ("a dispatcher that serves a method by its name",
     lambda: serverFindings('if (method == "ls" || method == "wipe")'), True),
    ("a dispatcher that serves a method with the literal first",
     lambda: serverFindings('if ("wipe" == method) {}'), True),
    ("a dispatcher that serves a family of methods by prefix",
     lambda: serverFindings('if (method.starts_with("debug.")) {}'), True),
    ("a dispatcher that routes every method through its entry",
     lambda: serverFindings('switch (entry->controlRoute) {} const bool isDown = parameters.stringOr("direction") == "down";'), False),
    ("a host verb handled without an entry",
     lambda: findings(registryOf([("ls", "ls", "Host", "", "")]), hostVerbs(HOST_LS + '        case "erase":\n'), set()), True),
    ("a host verb handled as a second pattern of a case",
     lambda: findings(registryOf([("ls", "ls", "Host", "", "")]), hostVerbs(HOST_LS + '        case "erase", "wipe":\n'), set()), True),
    ("an MCP tool dispatched without an entry",
     lambda: findings(registryOf([("t", "", "NotServed", "", "terminal_screen")]), set(),
                      mcpTools('if (name == "terminal_screen") {} if (name == "terminal_exfiltrate") {}')), True),
    ("an MCP protocol method that is no part of MCP",
     lambda: mcpProtocolFindings('if (method == "tools/call") {} if (method == "resources/read") {}'), True),
    ("only MCP's own protocol methods answered",
     lambda: mcpProtocolFindings('if (method == "initialize") {} if (method == "tools/list") {} if (method == "tools/call") {}'), False),
    ("an entry routing a method to a host that does not handle it",
     lambda: findings(registryOf([("ls", "ls", "Host", "", ""), ("ghost", "ghost", "HostOpens", "", "")]), hostVerbs(HOST_LS), set()), True),
    ("an entry naming a control method with no route",
     lambda: findings(registryOf([("ls", "ls", "NotServed", "", "")]), hostVerbs(HOST_LS), set()), True),
    ("an entry with a route and no control method",
     lambda: findings(registryOf([("ls", "", "Handshake", "", "")]), set(), set()), True),
    ("a Sync method with no roles or scope stated",
     syncCase("pane.wipe", '.syncMethod = "pane.wipe",'), True),
    ("a Sync method stating its roles and no scope",
     syncCase("pane.wipe", '.syncMethod = "pane.wipe",', ".roles = anyAttachment,"), True),
    ("roles stated for an operation no connection calls",
     syncCase("ubq.wipe", ".roles = anyAttachment,"), True),
    ("a Sync method stating its roles and its scope",
     syncCase("pane.wipe", '.syncMethod = "pane.wipe",', ".roles = anyAttachment,", ".scope = Sync::Scope::Drive,",
               ".target = CallTarget::Pane,"), False),
    ("a Sync method not saying what it is addressed to",
     syncCase("pane.wipe", '.syncMethod = "pane.wipe",', ".roles = anyAttachment,", ".scope = Sync::Scope::Drive,"), True),
    ("two entries under one name",
     lambda: findings(registryOf([("ls", "ls", "Host", "", ""), ("ls", "list", "ListOperations", "", "")]), hostVerbs(HOST_LS), set()), True),
    ("every surface's operations registered and dispatched",
     lambda: findings(registryOf([("ping", "ping", "Handshake", "", ""), ("ls", "ls", "Host", "", ""),
                                  ("t", "", "NotServed", "", "terminal_screen")]), hostVerbs(HOST_LS),
                      mcpTools('name == "terminal_screen"')), False),
    ("a verb answered from argv before the parser",
     mainCase(MAIN_CLEAN + 'int main(int argc, char** argv) { if (argc > 1 && std::string_view(argv[1]) == "nuke") return 0; }'), True),
    ("a verb answered from argv by strcmp",
     mainCase(MAIN_CLEAN + 'int main(int argc, char** argv) { if (std::strcmp(argv[1], "nuke") == 0) return 0; }'), True),
    ("an alias the parser rewrites to a registered verb",
     mainCase(MAIN_PARSER % 'if (parsed.verb == "rm") parsed.verb = "kill";'), True),
    ("a registered verb run outside the operation table",
     mainCase(MAIN_CLEAN + 'int main() { if (parsed.verb == "kill") return killMyWay(); }'), True),
    ("a parser that compares only registered verbs and leaves work to the table",
     mainCase(MAIN_CLEAN + 'int main() { return report(invoke(*parsed.method, parsed.params, context)); } // if (verb == "nuke")'), False),
    ("a verb dispatched around the operation table",
     lambda: operationGaps([{"name": "ubq.ls", "commandLineVerb": "ls"}, {"name": "ubq.rm", "commandLineVerb": "rm"}], {"ubq.ls"}), True),
    ("an operation table row no entry names",
     lambda: operationGaps([{"name": "ubq.ls", "commandLineVerb": "ls"}], {"ubq.ls", "ubq.ghost"}), True),
    ("a verb missing from the bash list but mentioned elsewhere in the script",
     completionCase(BASH_CLEAN.replace("read kill", "read") + "\n        kill) flags=\"--x\" ;;\n# kill\n", ZSH_CLEAN), True),
    ("a verb missing from the zsh list but described elsewhere",
     completionCase(BASH_CLEAN, ZSH_CLEAN.replace("        'kill:end'\n", "") + "'run:kill a thing'\n"), True),
    ("an api subverb missing from the bash api list",
     completionCase(BASH_CLEAN.replace('-W "list"', '-W ""'), ZSH_CLEAN), True),
    ("a completion offering a verb no entry names",
     completionCase(BASH_CLEAN.replace("read kill", "read kill nuke"), ZSH_CLEAN), True),
    ("both completion lists exactly the registry's",
     completionCase(BASH_CLEAN, ZSH_CLEAN), False),
)


def selftest(verbose):
    """Runs every planted case; returns the failure count."""
    failures = 0
    for title, run, expected in SELFTEST_CASES:
        reported = len(run()) > 0
        arm = "A" if expected else "B"
        if reported != expected:
            failures += 1
            print("  FAIL  ARM %s: %s\n        reported=%s expected=%s" % (arm, title, reported, expected), file=sys.stderr)
        elif verbose:
            print("  PASS  ARM %s: %s" % (arm, title))
    positives = sum(1 for _, _, expected in SELFTEST_CASES if expected)
    print("selftest: %d ARM A + %d ARM B = %d cases, %d failures"
          % (positives, len(SELFTEST_CASES) - positives, len(SELFTEST_CASES), failures))
    return failures


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def main():
    if "--self-test" in sys.argv[1:] or "--selftest" in sys.argv[1:]:
        return 1 if selftest(verbose=True) else 0
    # Silently on every ordinary run: a gate that cannot catch its own planted
    # defect cannot tell a clean tree from one it stopped reading.
    if selftest(verbose=False):
        print("%s: the selftest above failed, so this run says nothing about the tree" % GATE, file=sys.stderr)
        return 2

    entries = registryEntries(read(REGISTRY))
    host = hostVerbs(read(CONTROL_HOST))
    mcpText = read(AGENT_MCP)
    tools = mcpTools(mcpText)
    mainText = read(AGENT_MAIN)
    table = operationTable(mainText)
    bash = bashCompletionVerbs(read(BASH_COMPLETION))
    zsh = zshCompletionVerbs(read(ZSH_COMPLETION))
    # An empty parse is a broken reader, not an empty product.
    routes = {entry["controlRoute"] for entry in entries if entry.get("controlRoute", "NotServed") != "NotServed"}
    for label, found in (("registry entries", entries), ("control routes", routes), ("host verbs", host),
                         ("MCP tools", tools), ("operation table rows", table), ("bash verbs", bash[0]),
                         ("bash api subverbs", bash[1]), ("zsh verbs", zsh[0]), ("zsh api subverbs", zsh[1])):
        if not found:
            print("%s: read no %s, which is a reader that stopped matching rather than a surface "
                  "with nothing on it" % (GATE, label), file=sys.stderr)
            return 1

    lines = serverFindings(read(SERVER))
    lines += findings(entries, host, tools)
    lines += mcpProtocolFindings(mcpText)
    lines += commandLineFindings(mainText, entries)
    lines += operationGaps(entries, table)
    lines += completionGaps(entries, [(BASH_COMPLETION, bash), (ZSH_COMPLETION, zsh)])
    if lines:
        print("%s: an operation is exposed outside the method registry" % GATE, file=sys.stderr)
        print("\n".join(lines), file=sys.stderr)
        print("\nGive it an entry in %s (name, description, schemas, an example, its principals),"
              " and reach it through the entry, or stop dispatching it." % REGISTRY, file=sys.stderr)
        return 1

    print("%s: ok (%d entries; %d control methods, %d MCP tools, %d command-line verbs, all registered)"
          % (GATE, len(entries), len(registered(entries, "controlMethod")), len(registered(entries, "mcpTool")),
             len(registered(entries, "commandLineVerb"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
