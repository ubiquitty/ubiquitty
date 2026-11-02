<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Screenshots

## Capture a window

On macOS, press **Shift-Command-4**, then **Space**, and click the window.
Keep the native shadow and PNG resolution. Crop empty margins evenly without
rescaling the window. Check visible text for information you do not want to
publish.

For a fixed theme, turn off `appearance.follow_system`. Use a separate demo
session when preparing commands or sample data.

## Render terminal examples

[`Tools/readme-screenshots.py`](../../Tools/readme-screenshots.py) prepares
terminal feeds and configuration files:

```sh
readme_stage=$(mktemp -d /tmp/ubiquitty-readme.XXXXXX)
python3 Tools/readme-screenshots.py --output-dir "$readme_stage"
```

Build the macOS app, then render with its executable:

```sh
readme_build_root=$(python3 Scripts/build_root.py .)
readme_binary="$readme_build_root/macos/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"
python3 Tools/readme-screenshots.py \
  --output-dir "$readme_stage" --binary "$readme_binary" --render
```

Use `--only NAME` for one example. Each run writes a manifest and renderer logs
in the staging directory. The renderer uses the supplied configuration rather
than your preferences.

| Name | Columns × rows | Contents |
|---|---:|---|
| `hero` | 96 × 30 | Truecolor strip, all 256 palette entries, code, borders, emoji, ligatures, Powerline |
| `tektronix` | 92 × 34 | Wireframe cube, latitude/longitude globe, sine mesh and Tek alpha labels; Tek mode stays active |
| `inline-image` | 84 × 28 | 560 × 300 Mandelbrot RGBA image scaled to 70 columns, with height derived from its aspect ratio |
| `dashboard` | 96 × 30 | Fixed sample CPU bars, braille histories, process table |
| `shell-integration` | 84 × 23 | Three OSC 133 command cycles, including one non-zero exit |
| `unicode` | 84 × 24 | Three border weights, blocks, sextants, octants, braille, five underline styles |
| `truecolor` | 88 × 31 | Half-block plasma and a DEC double-height/double-width banner |
| `polish` | 84 × 27 | Styled underlines, superscripts/subscripts, and assembled multiline mathematics |
| `proportional` | 96 × 31 | OSC 66 proportional prose, bold and italic text, monospace code and table |


## Demo sessions

Prepare a separate home directory for a remote-session capture:

```sh
python3 Tools/readme-screenshots.py --demo-home /path/to/demo-home
```

The script creates shell and Neovim configuration, sample projects and these
helpers in `bin/`:

- `status-run LABEL -- COMMAND…` runs a command and reports its progress and exit status.
- `pst-hook STATE [KIND]` reports Claude Code lifecycle events through its hooks.
- `bench-sync` runs the demo benchmark command.

Connect to the demo host, arrange its tabs and panes, and run the programs you
want to show. Program status and agent presence should come from those running
programs and attachments.

To check tab indicators against an app trace:

```sh
python3 Tools/readme-screenshots.py --check-status tab-accessory.log expected.json \
  --status-records status.json
```

Start the app with `UBIQUITTY_TAB_ACCESSORY_TRACE=1` to produce the trace.
`expected.json` names the expected marks by tab; `status.json` contains the
corresponding `ubq --json status -s SESSION` records.

## Review

Inspect images at native size for clipped text, wrapping, joined borders,
image placement and cursor position. Keep captions short and accurate. Copy
approved images into this directory and update their README links.
Documentation images are separate from `Tests/Snapshots/golden/`.
