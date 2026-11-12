#!/bin/bash
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Download verified CI artifacts, then sign and publish them on this Mac.
# The local publisher is configured once with git config ubiquitty.releasePublisher.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    echo 'Usage: Scripts/release.sh vMAJOR.MINOR.PATCH [--run ID]'
    echo '       Scripts/release.sh --check'
    echo 'Signing, notarization and publication run locally using the configured publisher.'
    exit 0
fi
publisher="${UBIQUITTY_RELEASE_PUBLISHER:-$(git -C "$root" config --get ubiquitty.releasePublisher || true)}"
if [ -z "$publisher" ] || [ ! -f "$publisher" ]; then
    echo 'release: configure the local publisher with git config ubiquitty.releasePublisher /path/to/publisher' >&2
    exit 2
fi
export UBIQUITTY_RELEASE_CONFIG_ROOT="$root"
python="${UBIQUITTY_RELEASE_PYTHON:-python3}"
if [ -z "${UBIQUITTY_RELEASE_PYTHON:-}" ] && [ -x /opt/homebrew/bin/python3 ]; then
    python=/opt/homebrew/bin/python3
fi
"$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else "release: Python 3.11 or newer is required")'
exec "$python" "$publisher" "$@"
