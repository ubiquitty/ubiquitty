// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// outline.js — draws a session outline's rows.
//
// The rows are Core's (App::outlineJSON): what each is called, how deep it
// sits, whether it folds, its status and the colour of its mark, and the words
// for its status, its progress, how long ago it wrote and who is attached.
// This draws them and decides nothing: no title is composed, no status ranked,
// no colour chosen, no age worded and no count pluralised here. A row's words
// are in `row.words`; a row with none of a thing gets no element for it.
//
// Every text goes in through textContent. A title is bytes a program on the
// host chose, a label and a tag what a person typed, and this must never be
// the thing that renders either as markup.
//
// Nothing here reads the page: the document and the list are handed in, so
// the same function draws the page's own list, a sidebar embedding it, and
// the rows a test hands a stand-in document.

/// How far a level is indented under the one above it, in CSS pixels.
export const outlineIndentPixels = 16;

/// Draws `rows` as the children of `list`, replacing what it held.
///
/// - `document`: the document elements are made in.
/// - `list`: the element whose children become the rows, one `li` each.
/// - `rows`: the `rows` of an outline as Core spells it.
/// - `actions`: what a click does. `toggle(row)` for a row's fold, `open(row)`
///   for its title. A row is given neither control when the action is absent,
///   nor a fold when it holds nothing to fold. `rowActions(row)` returns the
///   elements the embedder adds to a row, after its facts; none when absent.
export function renderOutlineRows(document, list, rows, actions = {}) {
  const made = [];
  for (const row of rows) {
    const item = document.createElement('li');
    item.className = ['outline-row', `level-${row.level}`, row.match ? 'match' : '', row.hostCurrent ? 'current' : '']
      .filter((name) => name !== '').join(' ');
    item.style.paddingLeft = `${row.depth * outlineIndentPixels}px`;
    if (row.id) item.dataset.id = row.id;
    if (row.state !== 'live') item.dataset.state = row.state;

    const text = (className, words) => {
      const element = document.createElement('span');
      element.className = className;
      element.textContent = words;
      item.append(element);
      return element;
    };

    if (row.expandable && actions.toggle) {
      const fold = document.createElement('button');
      fold.type = 'button';
      fold.className = 'fold';
      fold.textContent = row.expanded ? '▾' : '▸';
      fold.setAttribute('aria-expanded', row.expanded ? 'true' : 'false');
      // The label says which row it folds: a column of unlabelled triangles is
      // one control read many times to anyone not looking at the row beside it.
      fold.setAttribute('aria-label', `${row.expanded ? 'Collapse' : 'Expand'} ${row.title}`);
      fold.addEventListener('click', () => actions.toggle(row));
      item.append(fold);
    }

    // The mark is Core's colour for the row's status; a row of no status has
    // no mark, and one with words for it says them to a reader who cannot see
    // a colour.
    if (row.status.kind !== '') {
      const mark = text('status', '');
      mark.dataset.kind = row.status.kind;
      mark.style.backgroundColor = row.statusColor;
      if (row.words.status) mark.setAttribute('aria-label', row.words.status);
    }

    if (row.id && actions.open) {
      const title = document.createElement('button');
      title.type = 'button';
      title.className = 'title';
      title.textContent = row.title;
      title.addEventListener('click', () => actions.open(row));
      item.append(title);
    } else {
      text('title', row.title);
    }
    if (row.secondaryTitle !== '') text('secondary', row.secondaryTitle);
    for (const label of row.labels) text('label', label);
    for (const tag of row.tags) {
      if (tag.name === '' || tag.showName === false) {
        // An untitled tag, or one whose rule hides its name, is a dot of its
        // colour, spoken by Core's words for it; an empty bordered chip would
        // say nothing to anyone.
        const dot = text('tag-dot', '');
        dot.setAttribute('role', 'img');
        dot.setAttribute('aria-label', tag.label);
        dot.setAttribute('title', tag.label);
        if (tag.color) dot.style.backgroundColor = tag.color;
        continue;
      }
      const chip = text(tag.loud ? 'tag loud' : 'tag', tag.name);
      if (tag.color) chip.style.borderColor = tag.color;
    }

    if (row.words.status) text('fact status-words', row.words.status);
    if (row.words.progress) text('fact progress', row.words.progress);
    if (row.status.bell) text('fact attention', 'bell');
    if (row.status.notification) text('fact attention', 'notified');
    if (row.badge !== '') text('badge', row.badge);
    if (row.directory !== '') text('fact directory', row.directory);
    if (row.columns > 0 && row.rows > 0) text('fact grid', `${row.columns}x${row.rows}`);
    if (row.words.sinceOutput) text('fact age output', `out ${row.words.sinceOutput}`);
    if (row.words.sinceInput) text('fact age input', `in ${row.words.sinceInput}`);
    if (row.words.attendance) text('fact attendance', row.words.attendance);
    if (row.words.collapsed) text('fact holds', row.words.collapsed);
    if (row.words.state) text('fact state', row.words.state);
    if (row.endsWhenDetached) text('fact state', 'ends when detached');
    if (actions.rowActions) {
      const added = actions.rowActions(row);
      if (added.length > 0) {
        const holder = document.createElement('span');
        holder.className = 'actions';
        holder.append(...added);
        item.append(holder);
      }
    }
    made.push(item);
  }
  list.replaceChildren(...made);
}
