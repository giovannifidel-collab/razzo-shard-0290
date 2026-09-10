#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper for public cross-repository Release assets.
# Metadata stays on the GitHub API with the ephemeral workflow token, but
# binary reads use each asset's stable public browser_download_url. This is
# important for remote/NBD range reads: sibling-repo API asset URLs can return
# 403 with a repo-scoped token, while anonymously retrying a pre-resolved API
# redirect can age into 500/403 failures. The stable public URL lets GitHub
# issue a fresh release-asset redirect for each request/range read.
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
# Binary asset fetches/mounts must use the stable public release URL rather
# than the API asset endpoint. Release metadata itself still comes from API.
s = s.replace("'.assets[] | select(.name==$n) | .url'", "'.assets[] | select(.name==$n) | .browser_download_url'")
p.write_text(s)
PY

exec bash "$TMP" "$@"
