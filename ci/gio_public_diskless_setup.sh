#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper for public cross-repository Release assets.
# GITHUB_TOKEN is intentionally retained for release metadata API calls, but
# must not be sent to binary asset endpoints owned by sibling public repos:
# GitHub can reject that repo-scoped token with HTTP 403. The underlying
# source-pack integrity remains enforced by the recorded asset digest/SHA256.
ORIG="$GITHUB_WORKSPACE/ci/gio_public_diskless_setup_orig.sh"
TMP="${RUNNER_TEMP:-/tmp}/gio_public_diskless_setup_inner.sh"
cp "$ORIG" "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '  asset_headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )'
new = '  : # public cross-repo binary assets are fetched anonymously'
if old not in s:
    raise SystemExit('asset Authorization hook not found')
s = s.replace(old, new, 1)
old = '        nbd_args+=( header="Authorization: Bearer ${GITHUB_TOKEN}" )'
new = '        : # public cross-repo NBD assets are fetched anonymously'
if old not in s:
    raise SystemExit('nbd Authorization hook not found')
s = s.replace(old, new, 1)
p.write_text(s)
PY

exec bash "$TMP" "$@"
