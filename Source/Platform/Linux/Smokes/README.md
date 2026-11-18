<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Linux smokes

The desktop's headless smoke implementations live here. The standalone padding
and skip-ink checks compile as ordinary source files. The shell fixtures are
private implementation headers included at their declaration sites in
`../main.cpp`: they exercise the same private application state and callbacks
as the running frontend, without exporting them or building a second shell.

The command dispatcher remains in `main.cpp`. `Scripts/run-linux-smokes.sh`
derives its test inventory from that dispatcher.
