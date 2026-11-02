// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

export function bindWorkspaceSearch(root, api, events) {
    const input = root.querySelector('input');
    const results = root.querySelector('[data-results]');
    const older = root.querySelector('[data-older]');
    const newer = root.querySelector('[data-newer]');
    function present(status) {
        older.disabled = newer.disabled = !input.value || !status.foundCount;
        if (!input.value) results.textContent = '';
        else if (status.isPatternInvalid) results.textContent = 'Invalid search pattern';
        else if (!status.isComplete) results.textContent = `Searching… ${status.foundCount} matches`;
        else results.textContent = status.foundCount
            ? `${status.foundCount}${status.isTruncated ? '+' : ''} ${status.foundCount === 1 ? 'match' : 'matches'}`
            : 'No matches';
    }
    const publish = (event) => present(event.detail);
    events.addEventListener('ubiquitty-search', publish);
    input.oninput = () => present(api.search(input.value));
    older.onclick = () => api.stepSearch('older');
    newer.onclick = () => api.stepSearch('newer');
    input.onkeydown = (event) => {
        if (event.key === 'Enter') {
            event.preventDefault();
            api.stepSearch(event.shiftKey ? 'older' : 'newer');
        }
    };
    present(api.search(''));
    input.focus();
    return () => {
        events.removeEventListener('ubiquitty-search', publish);
        api.search('');
    };
}
