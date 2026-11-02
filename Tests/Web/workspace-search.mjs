// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../../Source/Platform/Web/workspace-search.js', import.meta.url), 'utf8');
const { bindWorkspaceSearch } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const input = { value: '', focus() {} };
const results = { textContent: '' }, older = {}, newer = {};
const elements = { input, '[data-results]': results, '[data-older]': older, '[data-newer]': newer };
const events = new EventTarget();
const queries = [], steps = [];
const pending = { foundCount: 0, isComplete: false };
const api = {
    search(query) { queries.push(query); return pending; },
    stepSearch(direction) { steps.push(direction); },
};
const dispose = bindWorkspaceSearch({ querySelector: (name) => elements[name] }, api, events);
const publish = (status) => events.dispatchEvent(new CustomEvent('ubiquitty-search', { detail: status }));
assert.equal(older.disabled, true);
input.value = 'needle';
input.oninput();
assert.equal(queries.at(-1), 'needle');
publish({ foundCount: 3, isComplete: false });
assert.match(results.textContent, /Searching.*3 matches/);
publish({ foundCount: 3, isComplete: true });
assert.equal(results.textContent, '3 matches');
assert.equal(older.disabled, false);
older.onclick();
newer.onclick();
input.onkeydown({ key: 'Enter', shiftKey: true, preventDefault() {} });
assert.deepEqual(steps, ['older', 'newer', 'older']);
publish({ foundCount: 0, isComplete: true });
assert.equal(results.textContent, 'No matches');
assert.equal(newer.disabled, true);
publish({ foundCount: 0, isPatternInvalid: true });
assert.equal(results.textContent, 'Invalid search pattern');
dispose();
assert.equal(queries.at(-1), '', 'closing Find cancels its search');
publish({ foundCount: 12, isComplete: true });
assert.equal(results.textContent, 'Invalid search pattern', 'closed dialogs ignore late publications');
console.log('Workspace search: progress, completion, misses, navigation and close passed.');
