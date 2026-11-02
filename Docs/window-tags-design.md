<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Window tags

A window tag is a marker for identifying a host, profile, or manually
labelled window. A tag has a color, a title, or both. A titled tag is a
labelled capsule; a rule with a color and no title is a dot of that color,
for a reader who knows what the color means on their own machines. Accessible
text names every tag, so a dot is never announced as nothing. Tags do not
change terminal configuration or grant access to a host.

## Configuration

Rules are `[[tags]]` entries in `~/.config/ubiquitty/config.toml`:

```toml
[[tags]]
name = "production"
color = "red"
match_host = "prod-*"
prominence = "loud"
icon = "flame"
```

| Field | Meaning |
|---|---|
| `name` | Display name; optional for a rule with a color, which then draws as a dot |
| `color` | A named color or `#rrggbb`; an unknown value leaves the marker without a color |
| `match_host` | Pattern matched against the resolved machine name or saved host label; an array of patterns, or several separated by commas, matches when any one does |
| `match_profile` | Pattern matched against the applied profile name |
| `prominence` | `quiet` for a labelled capsule; `loud` also requests a title-bar tint |
| `icon` | A Phosphor icon name (`database`, `cloud`, `flame`); drawn in the tag's color where the marker would otherwise be a dot or the host's globe. A name the catalog does not carry draws as if it were absent |
| `icon_weight` | `fill` (default) or `regular`: which of the icon's two weights it is drawn in |
| `show_name` | `true` (default) draws the name; `false` draws the icon alone, or the color's dot without one. The name is still spoken, shown in tooltips, and matched |
| `show_in_title_bar` | `true` (default) draws the tag in the title bar, its host chip and a loud tag's wash included |
| `show_in_tabs` | `true` (default) draws the tag before the tab's title |
| `show_in_pane_headers` | `true` (default) draws the tag before a pane header's title |

Rules draw in the order the file lists them: the first rule's tag comes first
in the title bar, on the tab, and in a pane's header. Settings > Tags lists the
rules in that order; dragging a rule onto another, or Move Up and Move Down in
its context menu and its accessibility actions, moves its block in the file
(`Session::moveTagRule`) with every key and comment it carries.

A rule needs a title, a color that resolves, or both
(`Session::isValidTagRule`); an entry with neither draws nothing and is
skipped. An untitled rule also needs a host or profile pattern, because
without one it marks no window and no window can be given it by hand. A missing `name`, an empty one, and one of only blanks are the same
untitled rule, and an untitled rule is written back without a `name` line.

Patterns match the whole value, ignoring ASCII case. `*` matches any run of
characters. When both host and profile constraints are present, both must
match. An entry with neither constraint does not apply automatically; it
defines a name, color, prominence, and icon for manually applied tags.

Named colors are red, orange, yellow, green, blue, purple, and gray.
Both `gray` and `grey` are accepted. Unknown prominence values resolve to
quiet, and unknown icon weights to fill.

The icons are Phosphor's (MIT), vendored in `Resources/phosphor/` by
`Scripts/import-phosphor.py`: the fill and regular fonts and a catalog of the
icons both fonts draw under one code point, with the tags and categories a
picker searches. The macOS app reads the fonts into fonts only it holds and
never registers them, because their glyphs sit in the Private Use Area where
a registered font would answer a terminal's own icon code points.

## Resolution and precedence

Window markers combine two sources in order:

1. Matching configuration rules, in file order.
2. Names applied manually to the window.

Names are deduplicated using ASCII case-insensitive literal comparison; the
first occurrence wins. A star in a tag name is literal, not a matching rule.
Untitled tags have no name to compare: two of the same color are one dot, and
an untitled tag never hides a titled one (`Session::isSameTag`). Only a rule
supplies an untitled tag; a blank manual name is dropped.

`Session::resolveWindowTags` composes the list every window surface draws from:
the title bar, the tab, a pane's header, and the title popover. Each tag
records whether a rule or a hand supplied it, the supplying rule's position,
and the rule's pattern. `Session::tagsDrawnOn` is the part of that list one
title surface draws, in the same order; the popover and the outlines show
every tag. `ResolvedTag::drawsName` says whether a marker carries the name.

For a manual tag, the first configuration entry with the same name supplies
its color, prominence, icon, `show_name`, and places. Otherwise the name itself
may identify a named color. A name with no color remains a labelled marker.

The host chip's tint comes from the first colored rule tag the title bar draws,
before manual tags are added. A manually chosen window color is not treated as
a fact about the host.

## Host identity

Host matching uses the same `Session::resolvePaneHost` result as the window's
host chip and title. `resolveTagsForPaneHost` considers both the machine name
and its saved label.

| Session | Host used for matching |
|---|---|
| Host session on this machine, including an adopted local shell | This machine's name |
| Host reached over SSH or QUIC | The dialled machine and its saved label |
| Shell connected by ordinary SSH | The machine identified by process inspection or shell location reports |
| tmux control connection over SSH | The dialled machine |
| Plain local shell | No host name |

Profile rules can still match a local shell. A window with multiple panes uses
the host of the pane represented by its title row. Location changes refresh
both host identity and tag resolution.

## Native presentation

Tags appear as labelled capsules before the window title. The capsule uses
the shared chrome label styling and chooses its text color through
`Themes::Contrast::labelColorOnFill`. An untitled tag is a filled dot slightly
smaller than the capsule's height, centred on the same cap band. Accessible
text names every tag: a titled tag by its title, an untitled one by
`Session::tagSpokenName` — its palette color's name, or the rule's pattern for
a `#rrggbb` color.

A tag whose rule sets `show_name = false` is drawn the way an untitled tag is:
its icon in the circle, or the dot without one. Its accessible text, tooltip,
and the popover's token stay its name.

The Connect outline, the iOS host label, and the web outline draw an untitled
tag, and a tag whose rule hides its name, as a dot of its color with the same
spoken name; the plain-text outline writes an untitled tag as `●` and its
spoken name, and a hidden-name tag as `#` and its name.

The first loud tag with a color supplies the title-bar tint. Further loud
tags retain their capsules but do not combine competing background tints.
Quiet tags do not tint the title bar.

Tag colors in the title bar and on tabs are drawn at `[appearance]
tag_color_opacity` (Settings > Tags > Tag Color Strength, 50% by default), so a
tag reads as its color without outshining the title beside it, and a
translucent window's blur shows through. Text and icons inside a capsule take
the ink Core's contrast rule picks for the color as it actually composites over
the row. A loud tag's title-bar wash is not drawn at that opacity: it is the
tag's color mixed, three parts in ten, into the title bar's own untagged
ground (`Themes::Contrast::loudTagWash`), so a dark theme's title bar stays
dark under it and a light theme's light.

On macOS, when a rule gives the window's host a color, the host chip and that
tag are one capsule filled with the tag's color: the tag's icon in place of
the globe (the place symbol when the tag has none), the machine name, and the
tag's title when it has one, all in the readable ink for that fill. The tag is
not drawn again as a separate marker. The fill holds whatever the link is
doing; a link that is not steady shows a status dot at the icon's corner, and
the tooltip and spoken description say the state and name the tag. Over a
title bar washed in the same color, the capsule keeps a hairline border. A
titled marker draws its icon before its title; an untitled one draws its icon
in the tag's color in place of the dot.

A tab's title leads with every tag the tab draws, in order, the way a browser
tab leads with its site's icon: each tag's icon in its color, 16 points as a
site icon is, or a dot about the size of the label's lowercase letters when
the tag has none, a few points apart and a few points before the text, all
centred together. A tag with no
color is drawn in the title's ink. A tab holds at most three marks; past that
it draws the first three and a count of the rest ("+2") in the title's ink, and
its tooltip and spoken description name every tag. Once marks lead, a long
title truncates in its middle so they stay, as labels with pin or host marks
do. The accessory stays at the trailing edge.

A pane header leads its title with the same marks, for the tags the header
draws: the window's rules matched against that pane's own host, the window's
profile, and the window's hand-set names.

A tab and a pane's header draw what tells them apart
(`Session::resolveSurfaceTags`, through `resolveTabTags` and
`resolvePaneHeaderTags`). When the window is attached to a host over Sync, and
for a tab when its group's tabs are all on that host, a tag the connection
itself earns, by its host or by the window's profile, is left to the title
bar's host chip and not drawn on every tab or pane header again. A tab or a
header still draws a tag it gets from elsewhere: from another machine its pane
went on to by `ssh` (`Session::surfaceTagHost`, from the pane's own location),
or set on the window by hand. Over a Sync link the host's pane facts name the
host's own machine and carry nothing a pane's shell reports, so a hosted pane
is matched as the connection's wherever its shell has gone. A local window, or
a group whose tabs are on several hosts, draws every tag on every tab and
header, since those tags are how they are told apart. Each still names every tag it is placed to show, the
ones the chip carries included: its title leads with an attachment whose
description says them, no wider than nothing when it draws no mark, so
VoiceOver hears them in the title, and a tab's tooltip lists them too. The
rule's `show_in_tabs` or `show_in_pane_headers` applies first.

Tag placement is fixed before the title. Connection health, agent presence,
secure input, and broadcasting remain separate state indicators.

## Manual editing and persistence

The title-actions popover edits manual tags for both local and remote windows.
Its seven color controls toggle the corresponding named tag, and the token
field accepts arbitrary names. It shows the window's effective tags, the same
`Session::resolveWindowTags` list the title bar draws: tags a rule supplies
lead the token field as square tokens, which a deletion does not remove, and
each rule color's control wears a dashed ring, reports a mixed state, and
names the rule in its tooltip and accessible label ("From rule: prod-*").
Core has no way to suppress a rule's tag on one window, so pressing a color
that only a rule supplies changes nothing; the rule is edited in Settings.
**Rules…** opens Settings on the first rule the window matched, or on a new
rule prefilled with the window's remote-host key when none matched.

Manual tag names are stored in the saved layout's `UBLayoutTab.tags` array.
Capture records the manual names, not the resolved rule list; restoration
reapplies them to newly opened windows. If an arrangement brings an already
open session forward, that live window keeps its current manual tags.

A configuration reload recomputes rule-derived markers and manual tag colors.
Changing a tag's prominence in Settings must preserve the selected value when
the configuration is saved.

Window tags are not Finder tags. These controls do not write file-system tag
metadata or modify a remote host's files. Host workspace labels and tags are
also distinct from this window-local presentation.

## Source contracts

- [Tag matching, color lookup, and precedence](../Source/Core/Session/Tags.h)
- [Host identity](../Source/Core/Session/SessionLocation.h)
- Window tag composition: [Source/Platform/macOS/App/Windowing/TerminalWindowController+TitlebarIdentity.swift](../Source/Platform/macOS/App/Windowing/TerminalWindowController%2BTitlebarIdentity.swift)
- [Capsule rendering](../Source/Platform/macOS/App/TerminalView/TitlebarTagChip.swift)
- [Tab tag dot](../Source/Platform/macOS/App/Windowing/TabTagDots.swift)
- [Capture and restoration](../Source/Platform/macOS/App/Windowing/TerminalWindows.swift)
