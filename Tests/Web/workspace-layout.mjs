// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(
    new URL('../../Source/Platform/Web/workspace-layout.js', import.meta.url),
    'utf8',
);
const { projectMove, leaves, layoutRects } = await import(
    'data:text/javascript;base64,' + Buffer.from(source).toString('base64')
);
const workspace = {
    id: 1,
    revision: '9007199254740993',
    windows: [
        {
            id: 2,
            tabs: [
                {
                    id: 3,
                    panes: [
                        { id: 1, sessionID: 10 },
                        { id: 2, sessionID: 20 },
                    ],
                    split: {
                        axis: 'horizontal',
                        ratio: 0.6,
                        children: [{ sessionID: 10 }, { sessionID: 20 }],
                    },
                },
                { id: 4, panes: [{ id: 3, sessionID: 30 }], split: { sessionID: 30 } },
            ],
        },
    ],
};
const baseline = JSON.stringify(workspace);
for (const edge of ['left', 'right', 'top', 'bottom']) {
    const projection = projectMove(workspace, 10, 30, edge);
    assert.equal(JSON.stringify(workspace), baseline, 'preview never writes host state');
    assert.equal(projection.revision, workspace.revision, 'revision remains lossless');
    const [source, destination] = projection.windows[0].tabs;
    assert.deepEqual(leaves(source.split), [20]);
    assert.deepEqual(new Set(leaves(destination.split)), new Set([10, 30]));
    assert.deepEqual(
        destination.panes.map((pane) => pane.sessionID),
        leaves(destination.split),
        'sidebar preview follows spatial pane order',
    );
    assert.equal(
        destination.panes[destination.focusedPane].sessionID,
        10,
        'the moved pane supplies the destination focus',
    );
    assert.equal(destination.split.axis, ['left', 'right'].includes(edge) ? 'horizontal' : 'vertical');
    const rectangles = layoutRects(destination.split, { left: 0, top: 0, width: 1000, height: 600 });
    assert.equal(rectangles.panes.size, 2);
    assert.equal(rectangles.dividers.length, 1);
    const first = rectangles.panes.get(10),
        second = rectangles.panes.get(30);
    assert.ok(first.width > 0 && second.height > 0);
    if (edge === 'left') assert.ok(first.left < second.left);
    if (edge === 'bottom') assert.ok(first.top > second.top);
}
const within = projectMove(workspace, 10, 20, 'bottom');
assert.deepEqual(leaves(within.windows[0].tabs[0].split), [20, 10]);
const across = projectMove(workspace, 30, 10, 'top');
assert.equal(across.windows[0].tabs.length, 1);
assert.deepEqual(new Set(leaves(across.windows[0].tabs[0].split)), new Set([10, 20, 30]));
assert.equal(JSON.stringify(projectMove(workspace, 10, 10, 'left')), baseline);
console.log(
    'Workspace projections: nested splits, all four edges, empty-source cleanup, immutable host state passed.',
);
