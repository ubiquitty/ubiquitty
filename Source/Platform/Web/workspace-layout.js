// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Presentation projections only. The host validates and commits every move;
// these copies never replace the authoritative tree or resize terminal grids.
export function leaves(tree) {
    return tree?.sessionID ? [tree.sessionID] : (tree?.children || []).flatMap(leaves);
}

export function removeLeaf(tree, id) {
    if (!tree || tree.sessionID === id) return null;
    if (tree.sessionID) return tree;
    const children = tree.children.map((child) => removeLeaf(child, id)).filter(Boolean);
    return children.length === 1 ? children[0] : { ...tree, children };
}

export function insertLeaf(tree, target, incoming, edge) {
    if (tree?.sessionID === target) {
        const first = edge === 'left' || edge === 'top';
        return {
            axis: edge === 'left' || edge === 'right' ? 'horizontal' : 'vertical',
            ratio: 0.5,
            children: first ? [incoming, tree] : [tree, incoming],
        };
    }
    return tree?.children
        ? { ...tree, children: tree.children.map((child) => insertLeaf(child, target, incoming, edge)) }
        : tree;
}

export function layoutRects(tree, box, gap = 6, output = new Map(), dividers = [], path = []) {
    if (!tree) return { panes: output, dividers };
    if (tree.sessionID) {
        output.set(tree.sessionID, box);
        return { panes: output, dividers };
    }
    const horizontal = tree.axis === 'horizontal';
    const size = horizontal ? 'width' : 'height',
        origin = horizontal ? 'left' : 'top';
    const extent = Math.max(0, box[size] - gap);
    const first = extent * Math.max(0.05, Math.min(0.95, tree.ratio || 0.5));
    const secondBox = { ...box, [origin]: box[origin] + first + gap, [size]: extent - first };
    dividers.push({ path, horizontal, box, position: box[origin] + first, extent });
    layoutRects(tree.children[0], { ...box, [size]: first }, gap, output, dividers, [...path, 0]);
    layoutRects(tree.children[1], secondBox, gap, output, dividers, [...path, 1]);
    return { panes: output, dividers };
}

export function projectMove(workspace, sourceID, targetID, edge) {
    const projected = structuredClone(workspace);
    let source, target;
    for (const window of projected.windows)
        for (const tab of window.tabs) {
            for (const pane of tab.panes) {
                if (pane.sessionID === sourceID) source = { tab, pane };
                if (pane.sessionID === targetID) target = { tab, pane };
            }
        }
    if (!source || !target || sourceID === targetID) return projected;
    const sourceFocus = source.tab.panes[source.tab.focusedPane || 0]?.sessionID;
    source.tab.split = removeLeaf(source.tab.split, sourceID);
    source.tab.panes = source.tab.panes.filter((pane) => pane.sessionID !== sourceID);
    target.tab.split = insertLeaf(target.tab.split, targetID, { sessionID: sourceID }, edge);
    target.tab.panes.push(source.pane);
    // Pane arrays have the same spatial order as the host's split-tree walk.
    // The inserted pane takes focus, which also supplies the group's title.
    for (const tab of new Set([source.tab, target.tab])) {
        const byID = new Map(tab.panes.map((pane) => [pane.sessionID, pane]));
        tab.panes = leaves(tab.split).map((id) => byID.get(id));
        tab.focusedPane = Math.max(
            0,
            tab.panes.findIndex((pane) => pane.sessionID === (tab === target.tab ? sourceID : sourceFocus)),
        );
    }
    for (const window of projected.windows) window.tabs = window.tabs.filter((tab) => tab.panes.length);
    projected.windows = projected.windows.filter((window) => window.tabs.length);
    return projected;
}
