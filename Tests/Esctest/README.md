<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# External conformance target

The pinned esctest2 suite uses xterm as its closest target. The Ubiquitty
adapter runs the same case population and compares the failing set in both
directions. It does not add expected failures or suppress assertion failures.

- Rectangle observations explicitly request page one. DEC checksum page zero
  checks the whole page and ignores the rectangle; direct checksum test commands
  retain their original page argument.
- Reverse wrapping uses the suite's xterm 383 contract, which selects extended
  mode 1045. Legacy mode 45 remains covered by Core's own mode tests.
- Each case starts with RIS, then the upstream fixture. DECSTR alone preserves
  protected cells and DEC registers, so the upstream erase can leave another
  case's cells behind. Mode 40 is explicitly enabled for column-change tests.
  Reset tests still arrange their own state and execute their original commands.
- The implemented DEC registers use the suite's existing modifiable-mode helper:
  set, query, reset, query. A permanently-disabled answer fails these checks.
  The corresponding xterm known-bug annotations are removed, so assertion
  failures propagate. This also applies to independent ISO/DEC protection and
  DECNCSM, without enabling clipboard or the other window-operation tests.
- OSC 105 restores special colors from configured X resources. Ubiquitty exposes
  no such resources; Core's documented contract preserves assigned special
  colors. The four single/multiple OSC 4/5 cases therefore check exact assigned
  values before and after reset, rather than assuming an X resource exists.
  The dynamic-color case retains the upstream assertions.

The adapter refuses an unexpected upstream entry point. Its negative fixtures
check that immutable modes, wrong checksums, changed special colors, and failures
in implemented features still fail. Other known-bug and option annotations keep
upstream behavior. The runner records the target and arguments in provenance.

References: [DEC DECRQCRA](https://vt100.net/docs/vt510-rm/DECRQCRA.html),
[xterm OSC 105](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), and
`Tests/Core/test_conformance_color.cpp` in Core.
