// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// outline-rows.mjs — does the page's renderer draw the rows Core spells?
//
// Source/Platform/Web/outline.js draws a session outline's rows and is meant
// to decide nothing. The rows here are Tests/Core/App/outline-rows.json, which a
// Core test holds to App::outlineJSON byte for byte, so this reads the fields
// Core writes under the names Core writes them: a field Core renames leaves
// the fixture, and the row this draws from it goes missing here.
//
// The document is a stand-in of the dozen calls the renderer makes. An element
// records what was set on it, and has no innerHTML to set: text reaches it as
// textContent or not at all.
//
//   node Tests/Web/outline-rows.mjs

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const { renderOutlineRows, outlineIndentPixels } = await import(path.join(here, '../../Source/Platform/Web/outline.js'));
const coreRoot = process.env.UBIQUITTY_CORE_SOURCE_DIR || path.join(here, '../..');
const outline = JSON.parse(fs.readFileSync(path.join(coreRoot, 'Tests/Core/App/outline-rows.json'), 'utf8'));

class StubElement {
  constructor(tagName) {
    this.tagName = tagName;
    this.className = '';
    this.textContent = '';
    this.children = [];
    this.attributes = new Map();
    this.dataset = {};
    this.style = {};
    this.listeners = new Map();
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  addEventListener(type, listener) { this.listeners.set(type, listener); }
  click() { this.listeners.get('click')?.(); }
  // The first child of a class, and every child of one.
  one(className) { return this.children.find((child) => child.className.split(' ').includes(className)) ?? null; }
  all(className) { return this.children.filter((child) => child.className.split(' ').includes(className)); }
}
const stubDocument = { createElement: (tagName) => new StubElement(tagName) };

const failures = [];
const check = (condition, what) => { if (!condition) failures.push(what); };
const texts = (item, className) => item.all(className).map((element) => element.textContent);

const list = new StubElement('ul');
const toggled = [];
const opened = [];
const actions = { toggle: (row) => toggled.push(row), open: (row) => opened.push(row) };
renderOutlineRows(stubDocument, list, outline.rows, actions);

check(list.children.length === outline.rows.length, `${list.children.length} rows drawn for ${outline.rows.length} spelled`);
const [workspace, windowRow, pane, marked, recorded] = list.children;

// One li a row, indented by its depth, classed by its level.
for (const [index, item] of list.children.entries()) {
  const row = outline.rows[index];
  check(item.tagName === 'li', `row ${index} is a ${item.tagName}`);
  check(item.style.paddingLeft === `${row.depth * outlineIndentPixels}px`, `row ${index} is indented ${item.style.paddingLeft} at depth ${row.depth}`);
  check(item.className.split(' ').includes(`level-${row.level}`), `row ${index} is classed "${item.className}", not by its level ${row.level}`);
}

// The workspace: folded, labelled, tagged, with Core's words and colour.
check(workspace.dataset.id === 'workspace:9' && workspace.dataset.state === 'restored', 'the workspace row does not carry its identity and state');
const fold = workspace.one('fold');
check(fold !== null && fold.getAttribute('aria-expanded') === 'false' && fold.getAttribute('aria-label') === 'Expand work', 'a folded row has no fold control saying it is collapsed');
check(workspace.one('title')?.textContent === 'work', 'the workspace row is not titled work');
check(JSON.stringify(texts(workspace, 'label')) === '["nine"]', 'the workspace row does not show its label');
check(JSON.stringify(texts(workspace, 'tag')) === '["prod","eu"]', 'the workspace row does not show its tags in order');
const [prod, eu] = workspace.all('tag');
check(prod.className === 'tag loud' && prod.style.borderColor === '#c81e1e', 'a loud tag with a colour is not drawn loud in that colour');
check(eu.className === 'tag' && eu.style.borderColor === undefined, 'a quiet tag with no colour was given one');
const mark = workspace.one('status');
check(mark !== null && mark.dataset.kind === 'blocked' && mark.style.backgroundColor === '#204060', 'the status mark is not Core\'s colour for the row');
check(mark?.getAttribute('aria-label') === 'blocked 1/3: permission', 'the status mark does not say its status');
check(JSON.stringify(texts(workspace, 'status-words')) === '["blocked 1/3: permission"]', 'the status is not worded as Core words it');
check(JSON.stringify(texts(workspace, 'attendance')) === '["2 people, 1 agent"]', 'attendance is not worded as Core words it');
check(JSON.stringify(texts(workspace, 'holds')) === '["2 windows, 3 tabs, 5 panes"]', 'a folded row does not say what it holds');
check(JSON.stringify(texts(workspace, 'state')) === '["restored","ends when detached"]', 'the workspace row does not say its state');
check(workspace.one('progress') === null && workspace.one('badge') === null && workspace.one('grid') === null && workspace.one('age') === null
  && workspace.one('secondary') === null,
  'the workspace row was given an element for something it does not have');

// The window: unfolded and in front on the host.
check(windowRow.className.split(' ').includes('current'), 'the row the host has in front is not marked');
check(windowRow.one('fold')?.getAttribute('aria-expanded') === 'true' && windowRow.one('fold')?.getAttribute('aria-label') === 'Collapse ops', 'an unfolded row\'s control does not say so');

// The pane: a match, with every fact a pane row has.
check(pane.className.split(' ').includes('match'), 'a matching row is not marked');
check(pane.one('fold') === null, 'a row with nothing to fold has a fold control');
check(pane.one('secondary')?.textContent === 'make', 'the secondary title is missing');
check(JSON.stringify(texts(pane, 'progress')) === '["40%"]', 'progress is not worded as Core words it');
check(JSON.stringify(texts(pane, 'attention')) === '["bell","notified"]', 'attention nobody has seen is not shown');
check(pane.one('badge')?.textContent === 'x', 'the badge is missing');
check(pane.one('directory')?.textContent === '/srv/app' && pane.one('grid')?.textContent === '132x43', 'the directory and grid are missing');
check(JSON.stringify(texts(pane, 'age')) === '["out 2m","in now"]', 'the ages are not Core\'s words for them');
check(pane.one('state') === null && pane.one('holds') === null && pane.dataset.state === undefined, 'a live pane was given a state or a summary');

// An untitled tag is a dot of its colour, spoken by Core's words, not an
// empty chip.
check(marked.one('tag') === null, 'an untitled tag, or one whose rule hides its name, was drawn as a chip');
const [dot, hidden] = marked.all('tag-dot');
check(dot !== undefined && dot.textContent === '' && dot.style.backgroundColor === '#69b3ff', 'an untitled tag is not a dot of its colour');
check(dot?.getAttribute('aria-label') === 'Blue' && dot?.getAttribute('role') === 'img', 'an untitled tag\'s dot is not spoken by its colour');
// A tag whose rule hides its name is drawn as the untitled one is, and still
// heard by its name.
check(hidden !== undefined && hidden.textContent === '' && hidden.style.backgroundColor === '#1f6feb', 'a tag whose rule hides its name is not a dot of its colour');
check(hidden?.getAttribute('aria-label') === 'acme', 'a tag whose rule hides its name is not spoken by its name');

// Markup in a title is text.
check(marked.one('title')?.textContent === '<b>bold</b> & co', 'a title with markup in it was not set as text');
check(!('innerHTML' in marked.one('title')), 'the title was given markup');

// A row with no identity of its own cannot be opened, and can still be folded.
check(recorded.dataset.id === undefined && recorded.dataset.state === 'restorable', 'a recorded row carries an identity it does not have');
check(recorded.one('title')?.tagName === 'span' && pane.one('title')?.tagName === 'button', 'only a row with an identity is a control');
check(recorded.one('status') === null && recorded.one('status-words') === null, 'a row of no status was given a mark');

// A click hands back the row it was drawn from.
pane.one('title').click();
recorded.one('fold').click();
workspace.one('fold').click();
check(opened.length === 1 && opened[0] === outline.rows[2], 'opening a row did not hand back that row');
check(toggled.length === 2 && toggled[0] === outline.rows[4] && toggled[1] === outline.rows[0], 'folding a row did not hand back that row');

// Without the actions there is nothing to click.
const inert = new StubElement('ul');
renderOutlineRows(stubDocument, inert, outline.rows);
check(inert.children.every((item) => item.one('fold') === null && item.one('title')?.tagName === 'span'), 'a list with no actions has controls');

// What the embedder adds to a row goes after its facts, in a holder of its
// own, and only on the rows it adds to.
const withActions = new StubElement('ul');
renderOutlineRows(stubDocument, withActions, outline.rows, {
  rowActions: (row) => (row.id ? [stubDocument.createElement('button')] : []),
});
check(withActions.children.every((item, index) => {
  const holder = item.one('actions');
  return outline.rows[index].id ? holder !== null && holder.children.length === 1 && item.children.at(-1) === holder : holder === null;
}), 'the embedder\'s row actions are missing, misplaced, or added to a row it gave none');
check(list.children.every((item) => item.one('actions') === null), 'a list drawn without row actions has an actions holder');

// Drawing again replaces the rows; it does not add to them.
renderOutlineRows(stubDocument, list, outline.rows.slice(0, 2), actions);
check(list.children.length === 2, `a second drawing left ${list.children.length} rows where it drew 2`);
renderOutlineRows(stubDocument, list, [], actions);
check(list.children.length === 0, 'an empty outline left rows drawn');

if (failures.length > 0) {
  console.error('outline-rows: FAILED');
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`outline-rows: ${outline.rows.length} rows drawn as Core spells them, with its words and its colours`);
