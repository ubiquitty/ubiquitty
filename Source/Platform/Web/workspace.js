// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import createWasmModule from './ubiquitty.js';
import { loadTerminalFonts, prepareFont } from './fonts.js';
import { FontCatalog } from './rich-text.js';
import { layoutRects, leaves, projectMove } from './workspace-layout.js';
import { bindWorkspaceSearch } from './workspace-search.js';

const SYSTEM_FONT = '"SF Mono", SFMono-Regular, ui-monospace, Menlo, Consolas, monospace';
const defaults = {
    fontFamily: SYSTEM_FONT,
    fontSize: 12,
    lineSpacing: 2,
    padding: 4,
    theme: '',
    preferences: {},
};
const $ = (id) => document.getElementById(id);
function setText(node, value) {
    if (node.textContent !== value) node.textContent = value;
}
const escape = (value) =>
    String(value ?? '').replace(
        /[&<>"']/g,
        (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character],
    );
function recall(key, fallback) {
    try {
        return JSON.parse(localStorage.getItem(key)) ?? fallback;
    } catch {
        return fallback;
    }
}
function remember(key, value) {
    try {
        localStorage.setItem(key, JSON.stringify(value));
    } catch {
        /* Private storage can be unavailable. */
    }
}
const settings = { ...defaults, ...recall('ubiquitty.workspace.appearance', {}) };
const savedHosts = recall('ubiquitty.workspace.hosts', []);
let iconPoints = new Map(),
    programIcons = [],
    engine,
    carrier,
    host = null;
let tree = { complete: false, workspaces: [] },
    workspaceID = 0,
    tabID = 0,
    focusedID = 0;
let inspectorOpen = false,
    zoomedID = 0,
    pendingLayout = false,
    drag = null;
let generation = 0,
    framePending = false,
    processRequest = false,
    processSnapshot = null,
    processError = '';
let dialogKind = '',
    noticeTimer,
    sidebarMarkup = '',
    lastConnectionNotice = '',
    pendingSelection = 0;
let disposeDialog = null,
    findPaneID = 0;
let questionSignature = '',
    presentedQuestion = null;
let creatingWorkspace = false;
let launcherHosts = [],
    launcherCommand = '',
    launcherRefresh = false;
const hostSelections = new Map(),
    connectedHosts = new Map();
const hostKey = (item) => item?.key || item?.url;
const fontMetricsCache = new Map();
const fontCatalog = new FontCatalog(document);
const panes = new Map(),
    folded = new Set();
const icon = (name) =>
    `<span class="ph" aria-hidden="true">${String.fromCodePoint(iconPoints.get(name) || iconPoints.get('terminal-window') || 0xe682)}</span>`;
function paintIcons(root = document) {
    root.querySelectorAll('[data-icon]').forEach((node) => {
        node.innerHTML = icon(node.dataset.icon);
    });
}
function programIcon(pane, metadata) {
    const record = metadata?.records?.[metadata.primaryRecord];
    const candidates = [
        record?.effectiveApp,
        record?.app,
        pane.foreground,
        ...(pane.processChain || '').split(/\s*[▸◂]\s*/),
    ]
        .filter(Boolean)
        .map((value) => value.toLowerCase());
    const known = programIcons.find((item) =>
        item.names.some((name) => candidates.includes(name.toLowerCase())),
    );
    if (!known) return icon('terminal-window');
    return `<img class="program-icon ${known.ink === 'template' ? 'template' : ''}" alt="" src="process-icons/${encodeURIComponent(known.key)}.${known.extension || 'svg'}">`;
}
function notify(message) {
    $('notice').textContent = message;
    $('notice').hidden = false;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => {
        $('notice').hidden = true;
    }, 7000);
}
function currentWorkspace() {
    return tree.workspaces.find((item) => item.id === workspaceID);
}
function locate(id, workspace = currentWorkspace()) {
    for (const window of workspace?.windows || [])
        for (const tab of window.tabs) {
            const pane = tab.panes.find((item) => item.sessionID === id);
            if (pane) return { workspace, window, tab, pane };
        }
    return null;
}
function currentTab(workspace = currentWorkspace()) {
    return workspace?.windows.flatMap((window) => window.tabs).find((tab) => tab.id === tabID);
}
function tabWindow(id = tabID) {
    return currentWorkspace()?.windows.find((window) => window.tabs.some((tab) => tab.id === id));
}
function paneName(pane) {
    return pane.label || pane.title || pane.processChain || pane.foreground || `Session ${pane.sessionID}`;
}
function tabName(tab) {
    const primary = tab.panes[tab.focusedPane || 0] || tab.panes[0];
    return tab.label || primary?.tabTitle || tab.name || (primary ? paneName(primary) : 'Group');
}
function workspaceName(workspace) {
    return workspace?.label || workspace?.name || workspace?.defaultName || 'Workspace';
}
function directory(pane) {
    return pane.homeDirectory && pane.directory.startsWith(pane.homeDirectory)
        ? '~' + pane.directory.slice(pane.homeDirectory.length)
        : pane.directory;
}
function activeAPI() {
    return panes.get(focusedID)?.api;
}
function focusTerminal() {
    if (!$('dialog').open) activeAPI()?.focus();
}
function updateTheme(metadata = activeAPI()?.metadata) {
    if (!metadata?.background || !metadata?.foreground) return;
    document.documentElement.style.setProperty(
        '--terminal-background',
        `rgb(${metadata.background.join(' ')})`,
    );
    document.documentElement.style.setProperty(
        '--terminal-foreground',
        `rgb(${metadata.foreground.join(' ')})`,
    );
    const [r, g, b] = metadata.background;
    document.documentElement.style.colorScheme =
        r * 0.2126 + g * 0.7152 + b * 0.0722 > 150 ? 'light' : 'dark';
}
let focusSequence = 0;
async function publishFocus(found) {
    const sequence = ++focusSequence,
        connection = generation;
    if (carrier?.connectionState !== 'attached') return;
    try {
        if (found.window.tabs[found.window.activeTab]?.id !== found.tab.id)
            await carrier.hostCall('tab.activate', { tab: found.tab.id });
        if (sequence !== focusSequence || connection !== generation) return;
        if (found.tab.panes[found.tab.focusedPane]?.id !== found.pane.id)
            await carrier.hostCall('pane.focus', { pane: found.pane.id });
    } catch (error) {
        if (sequence === focusSequence && connection === generation) notify(error.message);
    }
}
function selectPane(id, { focus = true } = {}) {
    const found = locate(id);
    if (!found) return;
    tabID = found.tab.id;
    focusedID = id;
    zoomedID = 0;
    processSnapshot = null;
    processError = '';
    remember('ubiquitty.workspace.selection', { host: host?.url, workspaceID, tabID, focusedID });
    renderSidebar();
    renderLayout();
    renderInspector();
    void publishFocus(found);
    if (focus) requestAnimationFrame(focusTerminal);
}
function selectTab(tab) {
    selectPane(tab.panes[Math.min(tab.focusedPane || 0, tab.panes.length - 1)].sessionID);
}

// A pane keeps the canonical browser frontend and its native input/clipboard
// handlers. Every synchronous ABI call selects that pane in one shared module;
// only the hidden carrier owns a socket and the workspace attachment.
window.ubiquittyWorkspace = {
    async createModule(id) {
        await engine;
        const properties = {
            ubiquittyFontFamily: settings.fontFamily,
            ubiquittyPrepareFont: prepareFont,
            ubiquittyMeasurementDocument: document,
            ubiquittyFontMetricsCache: fontMetricsCache,
            ubiquittyFontCatalog: fontCatalog,
        };
        let created = false;
        function invoke(name, result, types = [], values = []) {
            // Construction measures fonts too. Publish this view's settings before
            // creating it, not only before calls on an already-created terminal.
            Object.assign(engine, properties);
            if (name === 'ubiquittyWebCreate') {
                if (id) {
                    if (
                        !engine.ccall(
                            'ubiquittyWebCreateWorkspacePane',
                            'number',
                            ['number', ...types],
                            [id, ...values],
                        )
                    )
                        throw new Error(`Could not create the renderer for session ${id}.`);
                } else engine.ccall('ubiquittyWebCreateWorkspace', null, types, values);
                created = true;
                return;
            }
            if (created && !engine.ccall('ubiquittyWebSelectWorkspacePane', 'number', ['number'], [id]))
                throw new Error(`Session ${id} no longer has a renderer.`);
            return engine.ccall(name, result, types, values);
        }
        return new Proxy(
            {},
            {
                get(_, property) {
                    if (property === 'ccall') return invoke;
                    if (property === 'cwrap')
                        return (name, result, types) =>
                            (...values) =>
                                invoke(name, result, types, values);
                    if (property in properties) return properties[property];
                    const value = engine[property];
                    return typeof value === 'function' ? value.bind(engine) : value;
                },
                set(_, property, value) {
                    properties[property] = value;
                    return true;
                },
            },
        );
    },
};
function terminalURL(id) {
    const url = new URL('index.html', location.href);
    url.search = new URLSearchParams({
        workspaceView: String(id),
        font: settings.fontFamily,
        size: String(settings.fontSize),
    });
    if (!id) url.searchParams.set('gpu', '0');
    return url;
}
async function frameAPI(frame) {
    await new Promise((resolve, reject) => {
        frame.addEventListener('load', resolve, { once: true });
        frame.addEventListener('error', () => reject(new Error('The terminal page could not load.')), {
            once: true,
        });
    });
    const api = frame.contentWindow.ubiquitty;
    if (!api) throw new Error('The terminal page did not initialize.');
    await api.ready;
    const style = frame.contentDocument.createElement('style');
    style.textContent =
        '#status,#sessions-open,#sessions{display:none!important}html,body{background:inherit}';
    frame.contentDocument.head.append(style);
    frame.contentWindow.addEventListener('keydown', shortcuts, true);
    return api;
}
const transport = {
    get readyState() {
        return carrier?.connectionState === 'attached' ? 1 : 0;
    },
    get bufferedAmount() {
        return carrier?.bufferedAmount || 0;
    },
    send(bytes) {
        carrier?.sendTransport(bytes);
    },
    close() {},
};
async function ensurePane(pane) {
    if (panes.has(pane.sessionID)) return panes.get(pane.sessionID);
    const element = document.createElement('section');
    element.className = 'pane';
    element.hidden = true;
    element.dataset.session = pane.sessionID;
    const header = document.createElement('header');
    header.innerHTML = `<span class="pane-program"></span><span class="pane-chain"></span><span class="pane-directory"></span><button class="icon-button" data-action="menu" title="Session actions" aria-label="Session actions">${icon('dots-three')}</button>`;
    const frame = document.createElement('iframe');
    frame.title = paneName(pane);
    frame.dataset.workspaceView = String(pane.sessionID);
    frame.dataset.fontFamily = settings.fontFamily;
    frame.src = terminalURL(pane.sessionID);
    frame.allow = 'clipboard-read; clipboard-write';
    element.append(header, frame);
    const entry = { element, header, frame, api: null, visible: false, disposed: false };
    panes.set(pane.sessionID, entry);
    header.addEventListener('pointerdown', (event) => {
        if (!event.target.closest('button')) {
            selectPane(pane.sessionID, { focus: false });
            beginDrag(event, pane.sessionID);
        }
    });
    header.addEventListener('dblclick', () => {
        focusedID = pane.sessionID;
        zoomedID = zoomedID === pane.sessionID ? 0 : pane.sessionID;
        renderLayout();
    });
    header.querySelector('[data-action=menu]').onclick = () => {
        selectPane(pane.sessionID, { focus: false });
        showSessionMenu(pane.sessionID);
    };
    const ready = frameAPI(frame);
    $('pane-layer').append(element);
    try {
        entry.api = await ready;
        if (entry.disposed) return entry;
        await entry.api.configure(settings);
        if (entry.disposed) return entry;
        entry.api.attachWorkspace(pane.sessionID, transport);
        entry.api.setVisible(entry.visible);
        frame.contentWindow.addEventListener('focus', () => {
            if (focusedID !== pane.sessionID) {
                selectPane(pane.sessionID, { focus: false });
            }
        });
        frame.contentDocument.addEventListener(
            'pointerdown',
            () => {
                if (focusedID !== pane.sessionID) {
                    selectPane(pane.sessionID, { focus: false });
                }
            },
            true,
        );
        renderLayout();
        if (focusedID === pane.sessionID) focusTerminal();
    } catch (error) {
        notify(error.message);
    }
    return entry;
}
function disposePane(id) {
    const entry = panes.get(id);
    if (!entry) return;
    if (findPaneID === id) closeDialog(false);
    entry.disposed = true;
    entry.element.remove();
    panes.delete(id);
    engine.ccall('ubiquittyWebDestroyWorkspacePane', null, ['number'], [id]);
}
function renderSidebar(workspace = currentWorkspace()) {
    setText($('workspace-switch').querySelector('.workspace-name'), workspaceName(workspace));
    $('new-tab').disabled = !workspace || pendingLayout;
    if (!workspace) {
        $('tree').innerHTML = '';
        sidebarMarkup = '';
        return;
    }
    const markup = workspace.windows
        .map(
            (window, windowIndex) => `<section class="window" data-window="${window.id}">
    <div class="window-heading"><button data-window-select="${window.id}">${escape(window.label || `Window ${windowIndex + 1}`)}</button><button class="icon-button" data-window-menu="${window.id}" aria-label="Window actions">${icon('dots-three')}</button></div>
    ${window.tabs
        .map(
            (
                tab,
            ) => `<div class="group" data-tab="${tab.id}"><div class="tree-row ${tab.id === tabID ? 'active' : ''}">
      ${tab.panes.length > 1 ? `<button class="icon-button" data-fold="${tab.id}" aria-label="${folded.has(tab.id) ? 'Expand' : 'Collapse'} group" aria-expanded="${!folded.has(tab.id)}">${icon(folded.has(tab.id) ? 'caret-right' : 'caret-down')}</button>` : ''}
      <button class="select" data-tab-select="${tab.id}">${tab.panes.length > 1 ? icon('folder-simple') : programIcon(tab.panes[0], panes.get(tab.panes[0].sessionID)?.api?.metadata)}<span class="name">${escape(tabName(tab))}</span><span class="${tab.panes.length > 1 ? 'group-count' : `status-dot ${escape(tab.panes[0].status)}`}">${tab.panes.length > 1 ? tab.panes.length : ''}</span></button>
      <button class="icon-button close" data-tab-menu="${tab.id}" aria-label="Group actions">${icon('dots-three')}</button></div>
      ${tab.panes.length > 1 && !folded.has(tab.id) ? tab.panes.map((pane) => `<div class="tree-row session ${pane.sessionID === focusedID ? 'active' : ''}" data-pane-row="${pane.sessionID}"><button class="select" data-pane-select="${pane.sessionID}">${programIcon(pane, panes.get(pane.sessionID)?.api?.metadata)}<span class="name ${!pane.title && !pane.label ? 'process-name' : ''}">${escape(paneName(pane))}</span><span class="status-dot ${escape(pane.status)}"></span></button><button class="icon-button close" data-pane-menu="${pane.sessionID}" aria-label="Session actions">${icon('dots-three')}</button></div>`).join('') : ''}
    </div>`,
        )
        .join('')}</section>`,
        )
        .join('');
    if (markup === sidebarMarkup) return;
    sidebarMarkup = markup;
    $('tree').innerHTML = markup;
    $('tree')
        .querySelectorAll('[data-tab-select]')
        .forEach((button) => {
            button.onclick = () => {
                const tab = workspace.windows
                    .flatMap((item) => item.tabs)
                    .find((item) => item.id === Number(button.dataset.tabSelect));
                if (tab) selectTab(tab);
            };
            button.onpointerdown = (event) => {
                const tab = workspace.windows
                    .flatMap((item) => item.tabs)
                    .find((item) => item.id === Number(button.dataset.tabSelect));
                if (tab?.panes.length === 1) beginDrag(event, tab.panes[0].sessionID);
                else beginTabDrag(event, Number(button.dataset.tabSelect));
            };
        });
    $('tree')
        .querySelectorAll('[data-pane-select]')
        .forEach((button) => {
            button.onclick = () => selectPane(Number(button.dataset.paneSelect));
            button.onpointerdown = (event) => beginDrag(event, Number(button.dataset.paneSelect));
        });
    $('tree')
        .querySelectorAll('[data-fold]')
        .forEach((button) => {
            button.onclick = () => {
                const id = Number(button.dataset.fold);
                folded.has(id) ? folded.delete(id) : folded.add(id);
                renderSidebar();
            };
        });
    $('tree')
        .querySelectorAll('[data-tab-menu]')
        .forEach((button) => {
            button.onclick = () => showTabMenu(Number(button.dataset.tabMenu));
        });
    $('tree')
        .querySelectorAll('[data-pane-menu]')
        .forEach((button) => {
            button.onclick = () => showSessionMenu(Number(button.dataset.paneMenu));
        });
    $('tree')
        .querySelectorAll('[data-window-menu]')
        .forEach((button) => {
            button.onclick = () => showWindowMenu(Number(button.dataset.windowMenu));
        });
    $('tree')
        .querySelectorAll('[data-window-select]')
        .forEach((button) => {
            button.onclick = () => {
                const window = workspace.windows.find(
                    (item) => item.id === Number(button.dataset.windowSelect),
                );
                if (window?.tabs.length) selectTab(window.tabs[window.activeTab] || window.tabs[0]);
            };
        });
}
function renderPaneHeaders() {
    for (const [id, view] of panes) {
        const pane = locate(id)?.pane;
        if (!pane) continue;
        const metadata = view.api?.metadata;
        const chain = metadata?.host?.processChain || pane.processChain || pane.foreground || 'Terminal';
        setText(view.header.querySelector('.pane-chain'), chain);
        view.header.querySelector('.pane-chain').title =
            metadata?.host?.processChainWithArguments || pane.processChainWithArguments || chain;
        const mark = programIcon(pane, metadata);
        if (view.mark !== mark) {
            view.mark = mark;
            view.header.querySelector('.pane-program').innerHTML = mark;
        }
        setText(view.header.querySelector('.pane-directory'), directory(pane));
        view.header.querySelector('.pane-directory').title = pane.directory;
        view.element.classList.toggle('focused', id === focusedID);
    }
    updateTheme();
}
function renderLayout(projected = null) {
    const workspace = projected || currentWorkspace();
    const tab = currentTab(workspace);
    $('empty').hidden = !!tab;
    const stage = $('stage').getBoundingClientRect();
    const split = zoomedID && !drag ? { sessionID: zoomedID } : tab?.split;
    const layout = layoutRects(split, {
        left: stage.left,
        top: stage.top,
        width: stage.width,
        height: stage.height,
    });
    for (const [id, view] of panes) {
        const box = layout.panes.get(id);
        view.element.hidden = !box;
        if (box) {
            const style = view.element.style;
            style.left = `${box.left}px`;
            style.top = `${box.top}px`;
            style.width = `${Math.max(0, box.width)}px`;
            style.height = `${Math.max(0, box.height)}px`;
        }
        // Preview changes the cards only: the fixed-size terminal is clipped inside
        // them, and the real iframe retains its exact pre-drag dimensions.
        if (!drag && view.visible !== !!box) {
            view.visible = !!box;
            view.api?.setVisible(view.visible);
        }
        if (!drag && box && view.api) view.api.repaint();
    }
    $('stage')
        .querySelectorAll('.divider')
        .forEach((node) => node.remove());
    if (tab && !zoomedID && !drag)
        for (const divider of layout.dividers) {
            const node = document.createElement('div');
            node.className = `divider ${divider.horizontal ? 'horizontal' : 'vertical'}`;
            node.tabIndex = 0;
            node.role = 'separator';
            node.setAttribute('aria-label', 'Resize split');
            node.setAttribute('aria-orientation', divider.horizontal ? 'vertical' : 'horizontal');
            node.style.left = `${(divider.horizontal ? divider.position : divider.box.left) - stage.left}px`;
            node.style.top = `${(divider.horizontal ? divider.box.top : divider.position) - stage.top}px`;
            node.style[divider.horizontal ? 'height' : 'width'] =
                `${divider.box[divider.horizontal ? 'height' : 'width']}px`;
            node.onpointerdown = (event) => beginDivider(event, divider);
            node.onkeydown = (event) => {
                const change =
                    event.key === 'ArrowLeft' || event.key === 'ArrowUp'
                        ? -0.05
                        : event.key === 'ArrowRight' || event.key === 'ArrowDown'
                          ? 0.05
                          : 0;
                if (change) {
                    event.preventDefault();
                    const nodeAt = divider.path.reduce((node, index) => node.children[index], tab.split);
                    mutate('divider.setRatio', {
                        window: tabWindow().id,
                        tab: tabID,
                        path: divider.path,
                        ratio: Math.max(0.05, Math.min(0.95, nodeAt.ratio + change)),
                        expectedRevision: workspace.revision,
                    });
                }
            };
            $('stage').append(node);
        }
    const window = tabWindow();
    setText(
        $('window-label'),
        window?.label || (workspace && window ? `Window ${workspace.windows.indexOf(window) + 1}` : ''),
    );
    renderPaneHeaders();
}
async function refresh() {
    framePending = false;
    if (!carrier) return;
    const latest = carrier.workspaceTree();
    if (latest.complete) tree = latest;
    if (creatingWorkspace && carrier.sessionID) {
        const created = tree.workspaces.find((workspace) =>
            workspace.windows.some((window) =>
                window.tabs.some((tab) => tab.panes.some((pane) => pane.sessionID === carrier.sessionID)),
            ),
        );
        if (created) {
            workspaceID = created.id;
            focusedID = carrier.sessionID;
            creatingWorkspace = false;
        }
    }
    tree.questions = latest.questions || [];
    const questions = JSON.stringify(tree.questions);
    if (questions !== questionSignature) {
        questionSignature = questions;
        $('people').setAttribute(
            'aria-label',
            tree.questions.length
                ? `People and agents · ${tree.questions.length} requests`
                : 'People and agents',
        );
        $('people').classList.toggle('has-requests', tree.questions.length > 0);
        if (dialogKind === 'people') showPeople();
        if (
            dialogKind === 'consent' &&
            presentedQuestion &&
            !tree.questions.some(
                (item) => item.request === presentedQuestion.request && item.kind === presentedQuestion.kind,
            )
        ) {
            closeDialog();
            notify('This request is no longer pending.');
        }
        if (tree.questions.length && !$('dialog').open) notify('A request is waiting in People and agents.');
    }
    if (workspaceID && !currentWorkspace() && latest.complete) {
        workspaceID = 0;
        tabID = 0;
        focusedID = 0;
    }
    const workspace = currentWorkspace();
    if (workspace) {
        const all = workspace.windows.flatMap((window) => window.tabs.flatMap((tab) => tab.panes));
        for (const id of panes.keys()) if (!all.some((pane) => pane.sessionID === id)) disposePane(id);
        if (pendingSelection && locate(pendingSelection)) {
            tabID = locate(pendingSelection).tab.id;
            focusedID = pendingSelection;
            pendingSelection = 0;
        }
        if (!currentTab()) {
            const window = workspace.windows[workspace.activeWindow] || workspace.windows[0];
            const tab = window?.tabs[window.activeTab] || window?.tabs[0];
            tabID = tab?.id || 0;
        }
        const tab = currentTab();
        if (tab && !tab.panes.some((pane) => pane.sessionID === focusedID))
            focusedID = tab.panes[tab.focusedPane]?.sessionID || tab.panes[0]?.sessionID || 0;
        // Background panes use Core's retained replicas; create browser renderers
        // only once visited, avoiding hundreds of WebGL contexts in a large host.
        for (const pane of tab?.panes || []) ensurePane(pane);
    }
    if (!drag) {
        renderSidebar();
        renderLayout();
    }
    updateConnection();
    renderInspector();
}
function queueRefresh() {
    if (!framePending) {
        framePending = true;
        requestAnimationFrame(refresh);
    }
}
function updateConnection() {
    const state = carrier?.connectionState || 'loading';
    $('connection').dataset.state = state;
    const suffix = state === 'attached' ? '' : ` · ${state}`;
    setText(
        $('connection-label'),
        host ? `${host.name || new URL(host.url).hostname}${suffix}` : 'Connect to a host',
    );
    $('connection').title = carrier?.connectionNotice || host?.url || 'Connect to host';
    const message = carrier?.connectionNotice || '';
    if (message && message !== lastConnectionNotice) notify(message);
    lastConnectionNotice = message;
    if (!currentTab()) {
        const connected = state === 'attached';
        setText($('empty').querySelector('h1'), connected ? 'Choose a workspace' : 'Your workspace, here.');
        setText(
            $('empty').querySelector('p'),
            connected
                ? 'Open a shared workspace or create one on this host. Private Mac windows appear after you share them from the app.'
                : 'Connect to a Ubiquitty host to open its windows and sessions.',
        );
        setText($('empty-connect'), connected ? 'Workspaces' : 'Connect to host');
    }
    if (!workspaceID && tree.complete && tree.workspaces.length && !$('dialog').open) showWorkspaces();
}
async function connectHost(next, selectedWorkspace = 0, workspaceName = '') {
    if (host) hostSelections.set(hostKey(host), { workspaceID, tabID, focusedID });
    generation++;
    connectedHosts.set(hostKey(next), next);
    host = next;
    workspaceID = selectedWorkspace;
    tabID = 0;
    focusedID = 0;
    zoomedID = 0;
    const selection = hostSelections.get(hostKey(next));
    if (selection?.workspaceID === selectedWorkspace) {
        tabID = selection.tabID;
        focusedID = selection.focusedID;
    }
    pendingSelection = 0;
    lastConnectionNotice = '';
    creatingWorkspace = !!workspaceName;
    for (const id of [...panes.keys()]) disposePane(id);
    tree = { complete: false, workspaces: [] };
    carrier.connect({
        url: next.url,
        token: next.token || '',
        workspaceID: selectedWorkspace,
        workspaceName,
        sessionID: 0,
        endsWhenDetached: false,
    });
    closeDialog(false);
    renderSidebar();
    renderLayout();
    updateConnection();
}
async function openWorkspace(id) {
    const existingTree = tree;
    await connectHost(host, id);
    tree = existingTree;
    // The new greeting rebinds every session on the same workspace carrier.
    queueRefresh();
}
async function mutate(method, parameters) {
    if (pendingLayout) {
        notify('Waiting for the host to finish the current change.');
        return null;
    }
    pendingLayout = true;
    renderSidebar();
    try {
        const result = await carrier.hostCall(method, parameters);
        if (
            ['workspace.addTab', 'workspace.addWindow', 'workspace.split'].includes(method) &&
            result?.session
        )
            pendingSelection = Number(result.session.split(':').pop());
        carrier.requestOutline();
        return result;
    } catch (error) {
        notify(error.message);
        carrier.requestOutline();
        return null;
    } finally {
        pendingLayout = false;
        queueRefresh();
    }
}
async function activateForChange(found) {
    if (!found) return false;
    const actual = found.window.tabs[found.window.activeTab];
    if (actual?.id === found.tab.id) return true;
    return !!(await mutate('tab.activate', { tab: found.tab.id }));
}
async function splitPane(id, orientation) {
    const found = locate(id);
    if (!(await activateForChange(found))) return;
    await mutate('workspace.split', { pane: found.pane.id, orientation, ratio: 0.5 });
}
function openDialog(title, html, kind = '') {
    disposeDialog?.();
    disposeDialog = null;
    findPaneID = 0;
    dialogKind = kind;
    $('dialog-title').textContent = title;
    $('dialog-content').innerHTML = html;
    if (!$('dialog').open) $('dialog').showModal();
    return $('dialog-content');
}
function closeDialog(focus = true) {
    disposeDialog?.();
    disposeDialog = null;
    findPaneID = 0;
    $('dialog').close();
    dialogKind = '';
    if (focus) requestAnimationFrame(focusTerminal);
}
function actionsDialog(title, actions) {
    const root = openDialog(
        title,
        `<div class="dialog-list">${actions.map((item, index) => `<button class="menu-item ${item.danger ? 'danger' : ''}" data-command="${index}">${escape(item.label)}${item.hint ? `<small>${escape(item.hint)}</small>` : ''}</button>`).join('')}</div>`,
    );
    root.querySelectorAll('[data-command]').forEach((button) => {
        button.onclick = () => {
            closeDialog(false);
            actions[Number(button.dataset.command)].run();
        };
    });
}
function askName(title, value, apply) {
    const root = openDialog(
        title,
        `<form><input class="search-input" name="name" aria-label="Name" maxlength="4096" value="${escape(value)}"><div class="dialog-actions"><button type="button" data-cancel>Cancel</button><button class="primary" type="submit">Save</button></div></form>`,
    );
    const input = root.querySelector('input');
    input.focus();
    input.select();
    root.querySelector('[data-cancel]').onclick = () => closeDialog();
    root.querySelector('form').onsubmit = (event) => {
        event.preventDefault();
        closeDialog();
        apply(input.value);
    };
}
function confirmClose(label, count, run) {
    const root = openDialog(
        `Close ${label}?`,
        `<p>This ends ${count === 1 ? 'the running session' : `all ${count} sessions`} and its processes on the host.</p><div class="dialog-actions"><button data-cancel>Cancel</button><button class="danger" data-confirm>Close ${escape(label)}</button></div>`,
    );
    root.querySelector('[data-cancel]').onclick = () => closeDialog();
    root.querySelector('[data-confirm]').onclick = () => {
        closeDialog(false);
        run();
    };
}
function showSessionMenu(id) {
    const found = locate(id);
    if (!found) return;
    const { pane, window, tab, workspace } = found;
    actionsDialog(paneName(pane), [
        { label: 'Split right', hint: '⌘D', run: () => splitPane(id, 'vertical') },
        { label: 'Split below', hint: '⌘⇧D', run: () => splitPane(id, 'horizontal') },
        {
            label: zoomedID === id ? 'Restore panes' : 'Focus this pane',
            run: () => {
                zoomedID = zoomedID === id ? 0 : id;
                focusedID = id;
                renderLayout();
                focusTerminal();
            },
        },
        {
            label: 'Move to its own tab',
            run: () =>
                mutate('pane.moveToNewTab', {
                    window: window.id,
                    pane: pane.id,
                    targetWindow: window.id,
                    expectedRevision: workspace.revision,
                }),
        },
        { label: 'Move to group…', run: () => showMoveTargets(id) },
        {
            label: 'Rename…',
            run: () =>
                askName('Session label', pane.label, (label) =>
                    mutate('label.set', { object: `pane:${pane.id}`, label }),
                ),
        },
        {
            label: 'Inspect',
            run: () => {
                focusedID = id;
                toggleInspector(true);
            },
        },
        {
            label: 'Close session…',
            danger: true,
            run: () => confirmClose('session', 1, () => mutate('workspace.closePane', { pane: pane.id })),
        },
    ]);
}
function showTabMenu(id) {
    const tab = currentWorkspace()
        ?.windows.flatMap((window) => window.tabs)
        .find((item) => item.id === id);
    if (!tab) return;
    const window = tabWindow(id),
        workspace = currentWorkspace();
    actionsDialog(tabName(tab), [
        { label: 'Open', run: () => selectTab(tab) },
        {
            label: 'Rename group…',
            run: () => askName('Group name', tab.name, (name) => mutate('tab.rename', { tab: id, name })),
        },
        {
            label: 'Balance panes',
            run: () =>
                mutate('tab.balance', { window: window.id, tab: id, expectedRevision: workspace.revision }),
        },
        {
            label: 'Move group…',
            run: () =>
                actionsDialog(
                    'Move group to window',
                    workspace.windows.map((item) => ({
                        label: item.label || `Window ${workspace.windows.indexOf(item) + 1}`,
                        run: () =>
                            mutate('tab.move', {
                                tab: id,
                                window: item.id,
                                index: item.tabs.filter((other) => other.id !== id).length,
                            }),
                    })),
                ),
        },
        {
            label: 'Close group…',
            danger: true,
            run: () =>
                confirmClose('group', tab.panes.length, () => mutate('workspace.closeTab', { tab: id })),
        },
    ]);
}
function showWindowMenu(id) {
    const workspace = currentWorkspace(),
        window = workspace?.windows.find((item) => item.id === id);
    if (!window) return;
    const pane = window.tabs[0]?.panes[0];
    actionsDialog(window.label || 'Window', [
        {
            label: 'New session',
            run: () => mutate('workspace.addTab', { window: id, ...(pane ? { pane: pane.id } : {}) }),
        },
        {
            label: 'New window',
            run: () =>
                mutate('workspace.addWindow', {
                    window: id,
                    pane: pane.id,
                    expectedRevision: workspace.revision,
                }),
        },
        {
            label: 'Rename…',
            run: () =>
                askName('Window label', window.label, (label) =>
                    mutate('label.set', { object: `window:${id}`, label }),
                ),
        },
        {
            label: 'Close window…',
            danger: true,
            run: () =>
                confirmClose(
                    'window',
                    window.tabs.reduce((sum, tab) => sum + tab.panes.length, 0),
                    () => mutate('window.close', { window: id, expectedRevision: workspace.revision }),
                ),
        },
    ]);
}
function showMoveTargets(id) {
    const source = locate(id);
    if (!source) return;
    actionsDialog(
        'Move session to group',
        currentWorkspace()
            .windows.flatMap((window) => window.tabs)
            .filter((tab) => tab.id !== source.tab.id)
            .map((tab) => ({
                label: tabName(tab),
                run: () =>
                    mutate('pane.moveToTab', {
                        window: source.window.id,
                        pane: source.pane.id,
                        tab: tab.id,
                        target: tab.panes[0].id,
                        orientation: 'vertical',
                        side: 'after',
                        insertTarget: 'root',
                        expectedRevision: currentWorkspace().revision,
                    }),
            })),
    );
}
async function showWorkspaces() {
    if (!host) {
        showConnection();
        return;
    }
    const root = openDialog(
        'Workspaces',
        `<p>${escape(host.name || new URL(host.url).hostname)}</p><div class="dialog-list">${tree.workspaces.map((workspace) => `<button data-workspace="${workspace.id}">${icon('stack')}<span class="label">${escape(workspaceName(workspace))}</span><small>${workspace.windows.length} windows${workspace.restorable ? ' · Restorable' : ''}</small></button>`).join('') || '<p>No workspaces are available on this host.</p>'}</div>${currentWorkspace() ? '<div class="dialog-actions"><button data-rename>Rename workspace…</button></div>' : ''}`,
        'workspaces',
    );
    root.querySelectorAll('[data-workspace]').forEach((button) => {
        button.onclick = () => openWorkspace(Number(button.dataset.workspace));
    });
    const create = document.createElement('button');
    create.className = 'quiet-button';
    create.textContent = 'New workspace…';
    create.onclick = () =>
        askName('New workspace', '', (name) => {
            if (name.trim()) connectHost(host, 0, name.trim());
        });
    root.append(create);
    const rename = root.querySelector('[data-rename]');
    if (rename)
        rename.onclick = () =>
            askName('Workspace name', currentWorkspace().name, (name) =>
                mutate('workspace.rename', { workspace: workspaceID, name }),
            );
}
async function refreshLauncher(announce = false) {
    if (launcherRefresh) return;
    launcherRefresh = true;
    try {
        const response = await fetch('sync-config', { cache: 'no-store', signal: AbortSignal.timeout(3000) });
        if (!response.ok) return;
        const configuration = await response.json();
        const next = (configuration.connections || (configuration.url ? [configuration] : [])).slice(0, 8);
        const added = next.filter(
            (item) => !launcherHosts.some((previous) => hostKey(previous) === hostKey(item)),
        );
        const changed = JSON.stringify(next) !== JSON.stringify(launcherHosts);
        launcherHosts = next;
        launcherCommand = configuration.launcherCommand || '';
        if (changed && dialogKind === 'hosts') showConnection();
        if (announce && added.length) {
            notify(
                `${added.map((item) => item.name).join(', ')} added. Choose a host below the workspace name.`,
            );
            if (dialogKind === 'add-host') showConnection();
        }
    } catch {
        /* A static deployment has no local launcher. Existing connections remain usable. */
    } finally {
        launcherRefresh = false;
    }
}
function availableHosts() {
    const items = new Map(connectedHosts);
    for (const item of launcherHosts) items.set(hostKey(item), item);
    return [...items.values()];
}
function showConnection() {
    const items = availableHosts();
    const root = openDialog(
        'Hosts',
        `<div class="dialog-list">${
            items
                .map((item, index) => {
                    const selected = hostKey(item) === hostKey(host);
                    const state = selected
                        ? carrier.connectionState === 'attached'
                            ? 'Connected'
                            : carrier.connectionState
                        : '';
                    return `<button data-host="${index}" ${selected ? 'aria-current="true"' : ''}>${icon(item.transport === 'local' ? 'desktop' : 'network')}<span class="label">${escape(item.name || new URL(item.url).hostname)}<small>${item.transport === 'ssh' ? 'SSH' : item.transport === 'local' ? 'This machine' : escape(new URL(item.url).hostname)}</small></span><small>${escape(state)}</small>${selected ? icon('check') : ''}</button>`;
                })
                .join('') || '<p>Add a local machine or connect over SSH to open its workspaces.</p>'
        }</div>${host && carrier.connectionNotice ? `<p class="form-error">${escape(carrier.connectionNotice)}</p>` : ''}<div class="host-actions"><button class="quiet-button" data-add>${icon('plus')}Add host…</button><span class="spacer"></span>${host ? '<button data-disconnect>Disconnect</button><button data-reconnect>Reconnect</button>' : ''}</div>`,
        'hosts',
    );
    root.querySelectorAll('[data-host]').forEach((button) => {
        button.onclick = () => {
            const next = items[Number(button.dataset.host)];
            if (hostKey(next) === hostKey(host) && carrier.connectionState === 'attached') {
                closeDialog();
                return;
            }
            connectHost(
                next,
                hostSelections.get(hostKey(next))?.workspaceID ||
                    (hostKey(next) === hostKey(host) ? workspaceID : 0),
            );
        };
    });
    root.querySelector('[data-add]').onclick = showAddHost;
    root.querySelector('[data-disconnect]')?.addEventListener('click', () => {
        carrier.detach();
        updateConnection();
        closeDialog();
    });
    root.querySelector('[data-reconnect]')?.addEventListener('click', () => connectHost(host, workspaceID));
    refreshLauncher();
}
function showAddHost() {
    const command = launcherCommand || 'Scripts/open-web.sh';
    const root = openDialog(
        'Add host',
        `<p>Run a command in a new terminal on this computer. The host will appear in this browser’s host picker.</p><div class="launch-section"><strong>This machine</strong><div class="launch-command"><code data-command="local"></code><button class="icon-button" data-copy="local" aria-label="Copy local host command">${icon('copy')}</button></div></div><div class="launch-section"><label for="ssh-host">Over SSH</label><input id="ssh-host" value="devbox" placeholder="SSH host or user@hostname" spellcheck="false" autocomplete="off" maxlength="255"><small>Uses your SSH configuration, keys and authentication.</small><div class="launch-command"><code data-command="ssh"></code><button class="icon-button" data-copy="ssh" aria-label="Copy SSH host command">${icon('copy')}</button></div><small>Ubiquitty must be installed on the remote machine.</small></div><p class="launch-note">Leave the first launcher running. Adding another host keeps the same browser tab; switching hosts leaves your terminal sessions running.</p><div class="dialog-actions"><button data-manual>WebSocket URL…</button><button class="primary" data-hosts>Back to hosts</button></div>`,
        'add-host',
    );
    const quote = (value) =>
        /^[A-Za-z0-9_][A-Za-z0-9_.@:\[\]-]*$/.test(value) ? value : `'${value.replace(/'/g, `'"'"'`)}'`;
    const update = () => {
        const name = root.querySelector('#ssh-host').value.trim();
        root.querySelector('[data-command=local]').textContent = `${command} local`;
        root.querySelector('[data-command=ssh]').textContent = `${command} ${quote(name || 'devbox')}`;
        root.querySelector('[data-copy=ssh]').disabled = !/^[A-Za-z0-9_][A-Za-z0-9_.@:\[\]-]*$/.test(name);
    };
    root.querySelector('#ssh-host').oninput = update;
    update();
    root.querySelectorAll('[data-copy]').forEach((button) => {
        button.onclick = async () => {
            const node = root.querySelector(`[data-command=${button.dataset.copy}]`);
            try {
                await navigator.clipboard.writeText(node.textContent);
                notify('Command copied. Run it in a new terminal on this computer.');
            } catch {
                const range = document.createRange();
                range.selectNodeContents(node);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                notify('Command selected. Copy it with your browser’s Copy command.');
            }
        };
    });
    root.querySelector('[data-manual]').onclick = showManualConnection;
    root.querySelector('[data-hosts]').onclick = showConnection;
}
function showManualConnection() {
    const root = openDialog(
        'Connection',
        `<form class="form-stack"><label>Host name<input name="name" autocomplete="off" placeholder="MacBook Pro" value="${escape(host?.name || '')}"></label><label>Sync WebSocket URL<input name="url" type="url" required spellcheck="false" autocomplete="off" placeholder="wss://host.example/sync" value="${escape(host?.url || '')}"></label><label>Access token<input name="token" type="password" autocomplete="off" value="${escape(host?.token || '')}"></label><small>Connects to a host, then lets you choose its workspace. Tokens are kept only for this page.</small><div class="form-error" role="alert"></div><div class="dialog-actions">${host ? '<button type="button" data-disconnect>Disconnect</button>' : ''}<button type="submit" class="primary">Connect</button></div></form>${savedHosts.length ? `<div class="inspect-section">Recent hosts</div><div class="dialog-list">${savedHosts.map((item, index) => `<button data-saved="${index}"><span class="label">${escape(item.name || item.url)}</span><small>${escape(new URL(item.url).hostname)}</small></button>`).join('')}</div>` : ''}`,
        'connection',
    );
    root.querySelector('form').onsubmit = (event) => {
        event.preventDefault();
        const data = new FormData(event.target);
        try {
            const url = new URL(data.get('url'));
            if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password)
                throw new Error('Use a ws:// or wss:// Sync endpoint without credentials in the URL.');
            if (location.protocol === 'https:' && url.protocol !== 'wss:')
                throw new Error('This page needs a secure wss:// connection.');
            const next = { name: data.get('name').trim(), url: url.href, token: data.get('token') };
            const index = savedHosts.findIndex((item) => item.url === next.url);
            if (index >= 0) savedHosts.splice(index, 1);
            savedHosts.unshift({ name: next.name, url: next.url });
            savedHosts.splice(8);
            remember('ubiquitty.workspace.hosts', savedHosts);
            connectHost(next);
        } catch (error) {
            root.querySelector('.form-error').textContent = error.message;
        }
    };
    root.querySelector('[data-disconnect]')?.addEventListener('click', () => {
        carrier.detach();
        updateConnection();
        closeDialog();
    });
    root.querySelectorAll('[data-saved]').forEach((button) => {
        button.onclick = () => {
            const item = savedHosts[Number(button.dataset.saved)];
            root.querySelector('[name=name]').value = item.name;
            root.querySelector('[name=url]').value = item.url;
            root.querySelector('[name=token]').value = '';
            root.querySelector('[name=token]').focus();
        };
    });
}
function showSettings() {
    fontCatalog.refresh();
    const { themes, rendering = [] } = carrier.settingsCatalog();
    const labels = {
        'font.proportional_family': ['Proportional font', 'Blank uses the system sans serif font.'],
        'font.proportional_size': [
            'Proportional size',
            '0 follows the terminal font with the app’s optical size adjustment.',
        ],
        'font.ligatures': ['Ligatures', 'Combine supported character sequences.'],
        'font.features': ['OpenType features', 'For example: liga=1, ss01=1, zero=1'],
        'font.character_spacing': ['Character spacing', 'Extra space between terminal columns.'],
        'font.weight': ['Regular weight', '0 uses the font’s own weight.'],
        'font.bold_weight': ['Bold weight', '0 uses the font’s own bold face.'],
        'underline.thickness': ['Thickness', 'Multiplier of the font’s underline thickness.'],
        'underline.offset': ['Offset', 'Move the underline below its default position.'],
        'underline.skip_ink': ['Skip descenders', 'Leave a gap where the underline meets a glyph.'],
        'underline.follows_ink': ['Follow glyph ink', 'Use glyph bounds for underline placement.'],
        'underline.skip_ink_pad': ['Gap around ink', 'Space around the skipped part of a glyph.'],
        'underline.links': ['Underline links', 'Mark detected links in terminal text.'],
    };
    const preferenceRows = (prefix) =>
        rendering
            .filter((item) => item.key.startsWith(prefix))
            .map((item) => {
                const [label, help] = labels[item.key];
                const value = settings.preferences?.[item.key] ?? item.value;
                const id = `setting-${item.key.replace('.', '-')}`;
                const input =
                    typeof value === 'boolean'
                        ? `<input id="${id}" data-preference="${item.key}" type="checkbox" ${value ? 'checked' : ''}>`
                        : typeof value === 'number'
                          ? `<input id="${id}" data-preference="${item.key}" type="number" min="${item.min}" max="${item.max}" step="${item.step}" value="${value}"><span class="muted">${escape(item.unit === 'pt' ? 'px' : item.unit)}</span>`
                          : `<input id="${id}" data-preference="${item.key}" type="text" maxlength="256" spellcheck="false" value="${escape(value)}">`;
                return `<div class="field"><label for="${id}">${label}<small>${help}</small></label><div class="control">${input}</div></div>`;
            })
            .join('');
    const root = openDialog(
        'Settings',
        `<p>Appearance is saved in this browser and applies to every session.</p>
    <div class="field"><label for="font-family">Terminal font<small>${fontCatalog.scope === 2 ? 'Local fonts and loaded page fonts.' : 'Loaded page fonts.'}</small></label><div class="control"><select id="font-family"><option value="system">System monospace</option>${fontCatalog.families.map((name) => `<option value="${escape(name)}">${escape(name)}</option>`).join('')}<option value="monospace">Browser monospace</option><option value="custom">Custom font…</option></select></div></div>
    ${fontCatalog.canRequestSystemFonts ? `<div class="field"><span>Local font access<small>Make installed fonts available in the picker and to terminal font discovery.</small></span><button id="local-font-access">${fontCatalog.scope === 2 ? 'Refresh local fonts' : 'Allow local fonts…'}</button></div>` : ''}
    <div class="field" id="custom-font-row" hidden><label for="custom-font">Font family<small>Uses an installed font; otherwise falls back.</small></label><input id="custom-font" type="text" maxlength="256" spellcheck="false"></div>
    <div class="field"><label for="font-size">Font size</label><div class="control"><input id="font-size" type="number" min="6" max="96" step="0.25" value="${settings.fontSize}"><span class="muted">px</span></div></div>
    <div class="field"><label for="line-spacing">Line spacing<small>Extra space between terminal rows.</small></label><div class="control"><input id="line-spacing" type="number" min="0" max="16" step="0.25" value="${settings.lineSpacing}"><span class="muted">px</span></div></div>
    <div class="field"><label for="padding">Pane padding</label><div class="control"><input id="padding" type="number" min="0" max="64" step="1" value="${settings.padding}"><span class="muted">px</span></div></div>
    <div class="field"><label for="theme">Theme<small>The sidebar follows the terminal colors.</small></label><div class="control"><select id="theme"><option value="">Follow host</option>${themes.map((name) => `<option value="${escape(name)}">${escape(name)}</option>`).join('')}</select></div></div>
    <details class="settings-section"><summary>Proportional text and font features</summary>${preferenceRows('font.')}</details>
    <details class="settings-section"><summary>Underlines</summary>${preferenceRows('underline.')}</details>
    <div class="font-preview" aria-label="Font preview"><span class="green">~/projects/ubiquitty</span><br>❯ git status<br><span class="muted">0123456789 · Il1 O0 → ▸ ◂</span></div><div class="form-error" role="alert"></div><div class="dialog-actions"><button id="reset-settings">Reset appearance</button><button class="primary" id="settings-done">Done</button></div>`,
        'settings',
    );
    const family = root.querySelector('#font-family');
    const localFonts = root.querySelector('#local-font-access');
    if (localFonts) localFonts.onclick = async () => {
        localFonts.disabled = true;
        try {
            await fontCatalog.requestSystemFonts();
            showSettings();
        } catch (error) {
            localFonts.disabled = false;
            root.querySelector('.form-error').textContent = error.message;
        }
    };
    family.value =
        settings.fontFamily === SYSTEM_FONT
            ? 'system'
            : [...family.options].some((option) => option.value === settings.fontFamily)
              ? settings.fontFamily
              : 'custom';
    root.querySelector('#custom-font').value = settings.fontFamily;
    root.querySelector('#custom-font-row').hidden = family.value !== 'custom';
    root.querySelector('#theme').value = settings.theme;
    let applySequence = 0;
    async function apply() {
        const sequence = ++applySequence;
        const next = {
            fontFamily:
                family.value === 'system'
                    ? SYSTEM_FONT
                    : family.value === 'custom'
                      ? root.querySelector('#custom-font').value.trim()
                      : family.value,
            fontSize: Number(root.querySelector('#font-size').value),
            lineSpacing: Number(root.querySelector('#line-spacing').value),
            padding: Number(root.querySelector('#padding').value),
            theme: root.querySelector('#theme').value,
            preferences: {},
        };
        for (const input of root.querySelectorAll('[data-preference]')) {
            if (!input.checkValidity()) {
                input.reportValidity();
                return;
            }
            next.preferences[input.dataset.preference] =
                input.type === 'checkbox'
                    ? input.checked
                    : input.type === 'number'
                      ? Number(input.value)
                      : input.value.trim();
        }
        root.querySelector('#custom-font-row').hidden = family.value !== 'custom';
        if (
            !next.fontFamily ||
            next.fontSize < 6 ||
            next.fontSize > 96 ||
            next.lineSpacing < 0 ||
            next.lineSpacing > 16 ||
            next.padding < 0 ||
            next.padding > 64
        )
            return;
        try {
            await document.fonts.load(
                `${next.fontSize}px ${next.fontFamily.includes(',') || next.fontFamily === 'monospace' ? next.fontFamily : JSON.stringify(next.fontFamily)}`,
            );
            if (sequence !== applySequence) return;
            Object.assign(settings, next);
            // The shared module rasterizes in this document, where the chosen face
            // has finished loading; each view rebuilds its own cached metrics.
            await carrier.configure(next);
            await Promise.all([...panes.values()].map((view) => view.api?.configure(next)));
            if (sequence !== applySequence) return;
            remember('ubiquitty.workspace.appearance', settings);
            document.documentElement.style.setProperty('--mono', next.fontFamily);
            const preview = root.querySelector('.font-preview');
            preview.style.fontFamily = next.fontFamily;
            preview.style.fontSize = `${next.fontSize}px`;
            preview.style.lineHeight = `${next.fontSize * 1.2 + next.lineSpacing}px`;
            root.querySelector('.form-error').textContent = '';
            updateTheme();
        } catch (error) {
            root.querySelector('.form-error').textContent = error.message;
        }
    }
    root.querySelectorAll('input,select').forEach((input) => input.addEventListener('change', apply));
    root.querySelector('.font-preview').style.fontFamily = settings.fontFamily;
    root.querySelector('.font-preview').style.fontSize = `${settings.fontSize}px`;
    root.querySelector('#reset-settings').onclick = async () => {
        Object.assign(settings, defaults, {
            preferences: Object.fromEntries(rendering.map((item) => [item.key, item.default])),
        });
        await carrier.configure(settings);
        await Promise.all([...panes.values()].map((view) => view.api?.configure(settings)));
        remember('ubiquitty.workspace.appearance', settings);
        showSettings();
    };
    root.querySelector('#settings-done').onclick = () => closeDialog();
}
let inspectorSignature = '';
function toggleInspector(open = !inspectorOpen) {
    inspectorOpen = open;
    $('inspector').hidden = !open;
    inspectorSignature = '';
    renderLayout();
    renderInspector();
    if (open) refreshProcesses();
}
function renderInspector() {
    if (!inspectorOpen) return;
    const pane = locate(focusedID)?.pane,
        metadata = activeAPI()?.metadata;
    if (!pane) {
        $('inspector-content').textContent = 'Select a session to inspect it.';
        return;
    }
    const signature = JSON.stringify([pane, metadata, processSnapshot, processError]);
    if (signature === inspectorSignature) return;
    inspectorSignature = signature;
    const records = metadata?.records || [],
        primary = records[metadata?.primaryRecord];
    const field = (name, value, mono = false) =>
        `<div class="inspect-field"><small>${escape(name)}</small><div class="${mono ? 'mono' : ''}">${escape(value || '—')}</div></div>`;
    const processRows = [];
    const processes = processSnapshot?.sessionID === focusedID ? processSnapshot.processes : [];
    const seen = new Set();
    function visit(process, depth) {
        if (seen.has(process.pid)) return;
        seen.add(process.pid);
        processRows.push(
            `<div class="process-row" style="--indent:${Math.min(depth, 5) * 10}px"><div>${icon(process.foreground ? 'terminal-window' : 'circle')}<code title="${escape(process.executable)}">${escape(process.name)}</code><span class="pid">${escape(process.pid)}</span></div><small>${process.foreground ? 'Foreground · ' : ''}${escape(process.state)}${process.leader ? ' · Session leader' : ''}</small><small class="mono">${escape(process.command)}</small></div>`,
        );
        processes
            .filter((child) => child.parentPID === process.pid)
            .forEach((child) => visit(child, depth + 1));
    }
    processes
        .filter((process) => !processes.some((parent) => parent.pid === process.parentPID))
        .forEach((process) => visit(process, 0));
    processes.forEach((process) => visit(process, 0));
    $('inspector-content').innerHTML =
        `<div class="inspect-heading">${programIcon(pane, metadata)}<div><strong>${escape(primary?.title || pane.label || pane.title || pane.foreground || 'Terminal')}</strong><small class="mono">${escape(pane.processChain || '')}</small></div></div>
    ${records.length ? `<div class="inspect-section">Program status</div>${records.map((record) => `<div class="status-line">${icon(record.state === 'blocked' ? 'hand-palm' : record.state === 'working' ? 'circle-notch' : 'circle')}<span>${escape(record.title || record.effectiveApp || record.app)} · ${escape(record.state)}</span></div>${record.message ? `<p>${escape(record.message)}</p>` : ''}${record.progress !== null ? `<progress max="100" value="${record.progress}"></progress>` : ''}`).join('')}` : ''}
    <div class="inspect-section">Processes ${processes.length ? `· ${processes.length}` : ''}</div>
    ${processRows.join('') || `<p class="muted">${escape(processError || (processSnapshot?.available === false ? 'Process information is unavailable on this host.' : 'Reading processes…'))}</p>`}
    ${processSnapshot?.complete === false && processSnapshot?.available ? '<small>The host returned a partial process tree.</small>' : ''}
    <div class="inspect-section">Context</div>${field('Working directory', pane.directory, true)}${field('App-provided title', metadata?.programTitle || pane.title)}${field('Shell prompt', metadata?.host?.isAtPrompt ? 'Ready for a command' : 'Program running')}${field('Last exit status', metadata?.exitStatus === null || metadata?.exitStatus === undefined ? '—' : String(metadata.exitStatus), true)}
    <div class="inspect-section">Connection</div><div class="inspect-pair"><span>Host</span><span>${escape(metadata?.host?.hostName || host?.name || '')}</span></div><div class="inspect-pair"><span>Workspace</span><span>${escape(workspaceName(currentWorkspace()))}</span></div><div class="inspect-pair"><span>Session</span><span class="mono">${pane.sessionID}</span></div><div class="inspect-pair"><span>Size</span><span class="mono">${pane.columns} × ${pane.rows}</span></div>`;
}
async function refreshProcesses() {
    if (!inspectorOpen || processRequest || carrier?.connectionState !== 'attached') return;
    const paneHandle = activeAPI()?.metadata?.host?.paneHandle;
    if (!paneHandle) return;
    const sessionID = focusedID,
        requestGeneration = generation;
    processRequest = true;
    try {
        const result = await carrier.hostCall('pane.processes', { pane: paneHandle });
        if (generation === requestGeneration && sessionID === focusedID) {
            processSnapshot = { ...result, sessionID };
            processError = '';
        }
    } catch (error) {
        if (generation === requestGeneration && sessionID === focusedID) processError = error.message;
    } finally {
        processRequest = false;
        renderInspector();
    }
}
function showPeople() {
    const peers = tree.attendees || [];
    const root = openDialog(
        'People and agents',
        `<p>${escape(workspaceName(currentWorkspace()))}</p>${peers.map((peer, index) => `<div class="person">${icon(peer.agent ? 'robot' : 'user-circle')}<div class="label">${escape(peer.self ? 'You' : peer.label || peer.process || (peer.agent ? 'Agent' : 'Person'))}<small>${peer.driver ? 'Can type' : 'Viewing'} · ${peer.live ? 'Connected' : 'Reconnecting'}${peer.geometryOwner ? ' · Owns size' : ''}</small></div>${peer.self ? '' : `<button data-disconnect-peer="${index}" class="quiet-button">Disconnect</button>`}</div>`).join('') || '<p>No shared attachment details are available.</p>'}<div class="inspect-section">Joining this workspace</div><p>Other people and agents connect to this host and choose <strong>${escape(workspaceName(currentWorkspace()))}</strong>. The host controls access and approval.</p><div class="inspect-pair"><span>Workspace ID</span><span class="mono">${workspaceID || '—'}</span></div>`,
        'people',
    );
    root.querySelectorAll('[data-disconnect-peer]').forEach((button) => {
        button.onclick = () => {
            const peer = peers[Number(button.dataset.disconnectPeer)],
                session = peer.sessions[0];
            if (!session) return;
            closeDialog(false);
            mutate('consent.revoke', {
                session: `session:${session}`,
                action: 'disconnect',
                attachment: peer.id,
            });
        };
    });
    if (tree.questions?.length) {
        const requests = document.createElement('div');
        requests.className = 'dialog-list';
        requests.innerHTML = `<div class="inspect-section">Requests · ${tree.questions.length}</div>${tree.questions.map((question, index) => `<button data-question="${index}">${icon('hand-palm')}<span class="label">${escape(question.question)}<small>${escape(question.process || 'Identity unavailable')}</small></span>${icon('caret-right')}</button>`).join('')}`;
        root.prepend(requests);
        requests.querySelectorAll('[data-question]').forEach((button) => {
            const question = tree.questions[Number(button.dataset.question)];
            button.onclick = () => showConsent(question);
        });
    }
}
function showConsent(question) {
    presentedQuestion = question;
    const root = openDialog(
        'Access request',
        `<p><strong>${escape(question.question)}</strong></p><div class="inspect-field"><small>Verified requester</small>${escape(question.process || 'Not available')}</div>${question.label ? `<div class="inspect-field"><small>Self-reported name</small>${escape(question.label)}</div>` : ''}<div class="inspect-field"><small>Session</small>${question.session}</div>${question.method ? `<div class="inspect-field"><small>Exact operation</small><code>${escape(question.method)}</code><pre class="request-parameters">${escape(question.parameters)}</pre></div>` : ''}<p>Allow once approves only this request.</p><div class="form-error" role="alert"></div><div class="dialog-actions"><button data-deny>Deny</button><button data-allow>Allow once</button></div>`,
        'consent',
    );
    const answer = async (decision) => {
        root.querySelectorAll('button').forEach((button) => {
            button.disabled = true;
        });
        try {
            await carrier.hostCall('consent.respond', {
                request: question.request,
                kind: question.kind,
                decision,
            });
            if (dialogKind === 'consent' && presentedQuestion === question) closeDialog();
        } catch (error) {
            root.querySelector('.form-error').textContent = error.message;
            root.querySelectorAll('button').forEach((button) => {
                button.disabled = false;
            });
        }
    };
    root.querySelector('[data-deny]').onclick = () => answer('deny');
    root.querySelector('[data-allow]').onclick = () => answer('once');
    root.querySelector('[data-deny]').focus();
}
function showFind() {
    if (!activeAPI()) return;
    const root = openDialog(
        'Find in terminal',
        '<input class="search-input" aria-label="Search terminal" placeholder="Find text…"><div class="dialog-actions"><button data-older>Previous</button><button data-newer>Next</button></div><p class="muted" data-results></p>',
        'find',
    );
    findPaneID = focusedID;
    disposeDialog = bindWorkspaceSearch(root, activeAPI(), panes.get(focusedID).frame.contentWindow);
}
function showBeam() {
    const workspace = currentWorkspace();
    const commands = [
        { label: 'Connect to host…', icon: 'plug', run: showConnection },
        { label: 'Switch workspace…', icon: 'stack', run: showWorkspaces },
        { label: 'Settings…', icon: 'gear-six', run: showSettings },
        ...(workspace
            ? [
                  { label: 'New session', icon: 'plus', run: newTab },
                  {
                      label: 'Split right',
                      icon: 'columns',
                      hint: '⌘D',
                      run: () => splitPane(focusedID, 'vertical'),
                  },
                  {
                      label: 'Split below',
                      icon: 'rows',
                      hint: '⌘⇧D',
                      run: () => splitPane(focusedID, 'horizontal'),
                  },
                  { label: 'Inspector', icon: 'info', run: () => toggleInspector() },
                  { label: 'People and agents', icon: 'users', run: showPeople },
                  ...workspace.windows.flatMap((window) =>
                      window.tabs.flatMap((tab) =>
                          tab.panes.map((pane) => ({
                              label: paneName(pane),
                              detail: `${tabName(tab)} · ${directory(pane)}`,
                              icon: 'terminal-window',
                              run: () => selectPane(pane.sessionID),
                          })),
                      ),
                  ),
              ]
            : []),
    ];
    const root = openDialog(
        'Beam',
        '<input class="search-input" aria-label="Search commands and sessions" placeholder="Search sessions or run a command…"><div class="dialog-list"></div>',
        'beam',
    );
    const input = root.querySelector('input'),
        list = root.querySelector('.dialog-list');
    let selected = 0,
        results = [];
    function draw() {
        const query = input.value.toLowerCase();
        results = commands.filter((item) =>
            `${item.label} ${item.detail || ''}`.toLowerCase().includes(query),
        );
        selected = Math.min(selected, Math.max(0, results.length - 1));
        list.innerHTML =
            results
                .map(
                    (item, index) =>
                        `<button data-result="${index}" style="${index === selected ? 'background:var(--hover)' : ''}">${icon(item.icon)}<span class="label">${escape(item.label)}${item.detail ? `<small style="display:block">${escape(item.detail)}</small>` : ''}</span><kbd>${escape(item.hint || '')}</kbd></button>`,
                )
                .join('') || '<p>No matching sessions or commands.</p>';
        list.querySelectorAll('button').forEach((button) => {
            button.onclick = () => {
                const item = results[Number(button.dataset.result)];
                closeDialog(false);
                item.run();
            };
        });
    }
    input.oninput = () => {
        selected = 0;
        draw();
    };
    input.onkeydown = (event) => {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            selected =
                (selected + (event.key === 'ArrowDown' ? 1 : -1) + results.length) %
                Math.max(1, results.length);
            draw();
            list.children[selected]?.scrollIntoView({ block: 'nearest' });
        } else if (event.key === 'Enter' && results[selected]) {
            event.preventDefault();
            const item = results[selected];
            closeDialog(false);
            item.run();
        }
    };
    draw();
    input.focus();
}
function newTab() {
    const found = locate(focusedID);
    if (found) mutate('workspace.addTab', { window: found.window.id, pane: found.pane.id });
}
function shortcuts(event) {
    if (event.isComposing || !(event.metaKey || (event.ctrlKey && event.shiftKey))) return;
    const key = event.key.toLowerCase();
    let action;
    if (key === 'p' && event.shiftKey) action = showBeam;
    else if (event.metaKey && key === ',') action = showSettings;
    else if (!$('dialog').open && event.metaKey) {
        if (key === 't') action = newTab;
        else if (key === 'd') action = () => splitPane(focusedID, event.shiftKey ? 'horizontal' : 'vertical');
        else if (key === 'f') action = showFind;
        else if (key === 'i' && event.shiftKey) action = () => toggleInspector();
        else if (key === 'b')
            action = () => {
                document.body.classList.toggle('sidebar-hidden');
                renderLayout();
            };
        else if (/^[1-9]$/.test(key))
            action = () => {
                const tab = tabWindow()?.tabs[Number(key) - 1];
                if (tab) selectTab(tab);
            };
    }
    if (action) {
        event.preventDefault();
        event.stopImmediatePropagation();
        action();
    }
}
function freezePanes() {
    document.body.classList.add('dragging');
    for (const view of panes.values()) {
        if (!view.api || view.element.hidden) continue;
        const rect = view.frame.getBoundingClientRect();
        view.frame.style.width = `${rect.width}px`;
        view.frame.style.height = `${rect.height}px`;
    }
}
function thawPanes() {
    document.body.classList.remove('dragging');
    for (const view of panes.values()) {
        view.frame.style.width = '';
        view.frame.style.height = '';
        view.element.classList.remove('drop-preview');
    }
}
function trackPointer(event, start, move, finish) {
    if (event.button !== 0 || pendingLayout) return;
    const x = event.clientX,
        y = event.clientY;
    let began = false;
    const onMove = (next) => {
        if (!began && Math.hypot(next.clientX - x, next.clientY - y) > 5) {
            began = true;
            start();
        }
        if (began) {
            next.preventDefault();
            move(next);
        }
    };
    const end = (next) => {
        document.removeEventListener('pointermove', onMove);
        document.removeEventListener('pointerup', end);
        document.removeEventListener('pointercancel', cancel);
        document.removeEventListener('keydown', key);
        if (began) finish(next.type !== 'pointercancel');
    };
    const cancel = (next) => end(next);
    const key = (next) => {
        if (next.key === 'Escape') {
            next.preventDefault();
            end({ type: 'pointercancel' });
        }
    };
    document.addEventListener('pointermove', onMove, { passive: false });
    document.addEventListener('pointerup', end);
    document.addEventListener('pointercancel', cancel);
    document.addEventListener('keydown', key);
}
function beginDrag(event, id) {
    const source = locate(id);
    if (!source) return;
    let shield,
        label,
        target = null,
        originalTab = tabID;
    trackPointer(
        event,
        () => {
            drag = { source: id };
            zoomedID = 0;
            freezePanes();
            shield = document.createElement('div');
            shield.className = 'drag-shield';
            document.body.append(shield);
            label = document.createElement('div');
            label.className = 'drag-label';
            label.textContent = paneName(source.pane);
            document.body.append(label);
        },
        (next) => {
            label.style.left = `${next.clientX + 12}px`;
            label.style.top = `${next.clientY + 12}px`;
            target = null;
            const row = [...$('tree').querySelectorAll('[data-pane-row],.group')].reverse().find((node) => {
                const rect = node.getBoundingClientRect();
                return (
                    next.clientX >= rect.left &&
                    next.clientX < rect.right &&
                    next.clientY >= rect.top &&
                    next.clientY < rect.bottom
                );
            });
            if (row) {
                const tab = currentWorkspace()
                    .windows.flatMap((window) => window.tabs)
                    .find((item) => item.id === Number(row.closest('.group').dataset.tab));
                const targetID = Number(row.dataset.paneRow) || tab.panes[0]?.sessionID;
                if (targetID && targetID !== id) target = { id: targetID, edge: 'right' };
            } else {
                const stage = $('stage').getBoundingClientRect(),
                    tab = currentTab();
                const boxes = layoutRects(tab?.split, {
                    left: stage.left,
                    top: stage.top,
                    width: stage.width,
                    height: stage.height,
                }).panes;
                for (const [targetID, box] of boxes)
                    if (
                        targetID !== id &&
                        next.clientX >= box.left &&
                        next.clientX <= box.left + box.width &&
                        next.clientY >= box.top &&
                        next.clientY <= box.top + box.height
                    ) {
                        const x = (next.clientX - box.left) / box.width,
                            y = (next.clientY - box.top) / box.height;
                        const edges = [
                            ['left', x],
                            ['right', 1 - x],
                            ['top', y],
                            ['bottom', 1 - y],
                        ].sort((a, b) => a[1] - b[1]);
                        target = { id: targetID, edge: edges[0][0] };
                        break;
                    }
            }
            if (target) {
                const found = locate(target.id);
                tabID = found.tab.id;
                const projected = projectMove(currentWorkspace(), id, target.id, target.edge);
                renderSidebar(projected);
                renderLayout(projected);
                panes.get(id)?.element.classList.add('drop-preview');
            } else {
                tabID = originalTab;
                renderSidebar();
                renderLayout();
            }
        },
        async (commit) => {
            const chosen = target;
            shield?.remove();
            label?.remove();
            drag = null;
            thawPanes();
            if (!commit || !chosen) {
                tabID = originalTab;
                renderSidebar();
                renderLayout();
                return;
            }
            const destination = locate(chosen.id);
            if (!destination) {
                tabID = originalTab;
                renderLayout();
                return;
            }
            focusedID = id;
            const parameters = {
                window: source.window.id,
                pane: source.pane.id,
                tab: destination.tab.id,
                target: destination.pane.id,
                orientation: ['left', 'right'].includes(chosen.edge) ? 'vertical' : 'horizontal',
                side: ['left', 'top'].includes(chosen.edge) ? 'before' : 'after',
                insertTarget: 'pane',
                expectedRevision: source.workspace.revision,
            };
            await mutate('pane.moveToTab', parameters);
            renderLayout();
            focusTerminal();
        },
    );
}
function beginTabDrag(event, id) {
    let target = null,
        shield;
    const workspace = currentWorkspace();
    trackPointer(
        event,
        () => {
            drag = { tab: id };
            freezePanes();
            shield = document.createElement('div');
            shield.className = 'drag-shield';
            document.body.append(shield);
        },
        (next) => {
            const row = [...$('tree').querySelectorAll('.group')].find((node) => {
                const rect = node.getBoundingClientRect();
                return (
                    next.clientX >= rect.left &&
                    next.clientX < rect.right &&
                    next.clientY >= rect.top &&
                    next.clientY < rect.bottom
                );
            });
            if (!row || Number(row.dataset.tab) === id) return;
            const destinationID = Number(row.dataset.tab),
                destinationWindow = workspace.windows.find((window) =>
                    window.tabs.some((tab) => tab.id === destinationID),
                );
            const copy = structuredClone(workspace),
                source = copy.windows.find((window) => window.tabs.some((tab) => tab.id === id)),
                tab = source.tabs.find((tab) => tab.id === id);
            source.tabs = source.tabs.filter((item) => item.id !== id);
            const destination = copy.windows.find((window) => window.id === destinationWindow.id),
                rect = row.getBoundingClientRect();
            const index =
                destination.tabs.findIndex((item) => item.id === destinationID) +
                (next.clientY > rect.top + rect.height / 2 ? 1 : 0);
            destination.tabs.splice(index, 0, tab);
            target = { tab: id, window: destination.id, index };
            renderSidebar(copy);
        },
        async (commit) => {
            shield?.remove();
            drag = null;
            thawPanes();
            renderSidebar();
            renderLayout();
            if (commit && target) await mutate('tab.move', target);
        },
    );
}
function beginDivider(event, divider) {
    const workspace = currentWorkspace(),
        window = tabWindow(),
        tab = currentTab();
    let ratio = 0.5,
        shield;
    trackPointer(
        event,
        () => {
            drag = { divider };
            freezePanes();
            shield = document.createElement('div');
            shield.className = 'drag-shield';
            shield.style.cursor = divider.horizontal ? 'col-resize' : 'row-resize';
            document.body.append(shield);
        },
        (next) => {
            ratio = Math.max(
                0.08,
                Math.min(
                    0.92,
                    ((divider.horizontal ? next.clientX : next.clientY) -
                        divider.box[divider.horizontal ? 'left' : 'top']) /
                        divider.extent,
                ),
            );
            const projected = structuredClone(workspace),
                projectedTab = currentTab(projected),
                split = divider.path.reduce((node, index) => node.children[index], projectedTab.split);
            split.ratio = ratio;
            renderLayout(projected);
        },
        async (commit) => {
            shield?.remove();
            drag = null;
            thawPanes();
            if (commit)
                await mutate('divider.setRatio', {
                    window: window.id,
                    tab: tab.id,
                    path: divider.path,
                    ratio,
                    expectedRevision: workspace.revision,
                });
            renderLayout();
        },
    );
}
async function initialize() {
    const [phosphor, catalog] = await Promise.all([
        fetch('phosphor/catalog.json').then((response) => response.json()),
        fetch('process-icons/catalog.json').then((response) => response.json()),
    ]);
    iconPoints = new Map(phosphor.icons.map((item) => [item.name, item.codePoint]));
    programIcons = catalog.icons;
    // The catalog's source names PNG exceptions; its generated icon list is
    // staged with explicit extensions by the build, rather than guessed here.
    const extensions = await fetch('process-icons/files.json').then((response) => response.json());
    programIcons.forEach((item) => {
        item.extension = extensions[item.key] || 'svg';
    });
    paintIcons();
    await document.fonts.ready;
    await Promise.all([...document.fonts].map((face) => face.load().catch(() => {})));
    const coverage = await loadTerminalFonts();
    engine = await createWasmModule();
    engine.ubiquittyFontCoverage = coverage;
    document.documentElement.style.setProperty('--mono', settings.fontFamily);
    const frame = document.createElement('iframe');
    frame.id = 'carrier';
    frame.dataset.workspaceView = '0';
    frame.dataset.fontFamily = settings.fontFamily;
    frame.title = 'Workspace connection';
    frame.tabIndex = -1;
    frame.setAttribute('aria-hidden', 'true');
    frame.src = terminalURL(0);
    const ready = frameAPI(frame);
    document.body.append(frame);
    carrier = await ready;
    await carrier.configure(settings);
    frame.contentWindow.addEventListener('ubiquitty-workspace-frame', queueRefresh);
    $('connection').onclick = showConnection;
    $('empty-connect').onclick = () =>
        carrier.connectionState === 'attached' ? showWorkspaces() : showConnection();
    $('workspace-switch').onclick = showWorkspaces;
    $('settings-open').onclick = showSettings;
    $('people').onclick = showPeople;
    $('beam-open').onclick = showBeam;
    $('new-tab').onclick = newTab;
    $('find-open').onclick = showFind;
    $('inspector-open').onclick = () => toggleInspector();
    $('inspector-close').onclick = () => toggleInspector(false);
    $('sidebar-toggle').onclick = () => {
        document.body.classList.toggle('sidebar-hidden');
        renderLayout();
    };
    $('dialog-close').onclick = () => closeDialog();
    $('dialog').addEventListener('cancel', (event) => {
        event.preventDefault();
        closeDialog();
    });
    document.addEventListener('keydown', shortcuts, true);
    new ResizeObserver(() => {
        if (!drag) renderLayout();
    }).observe($('stage'));
    setInterval(() => {
        updateConnection();
        if (!document.hidden) {
            renderPaneHeaders();
            refreshProcesses();
        }
    }, 1000);
    // Launcher credentials live only in page memory. Adding a host never changes
    // the active terminal beneath someone who is typing.
    await refreshLauncher();
    if (launcherHosts.length) await connectHost(launcherHosts[0], launcherHosts[0].workspaceID || 0);
    setInterval(() => {
        if (!document.hidden && launcherCommand) refreshLauncher(true);
    }, 3000);
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) refreshLauncher(true);
    });
    updateConnection();
}
initialize().catch((error) => {
    $('empty').querySelector('h1').textContent = 'Could not open Ubiquitty';
    $('empty').querySelector('p').textContent = error.message;
    console.error(error);
});
