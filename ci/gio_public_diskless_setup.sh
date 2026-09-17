#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper for public cross-repository Release assets.
# Metadata stays on the GitHub API with the ephemeral workflow token, while
# binary reads use each asset's stable public browser_download_url.
# Remote NBD reads are retried at the whole setup level as well: GitHub's
# public release backend can occasionally return an opaque transient server
# error while a pack is being attached. A fresh setup tears down partial NBD/
# dm state and obtains fresh release redirects without changing any source pin.
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
s = s.replace("'.assets[] | select(.name==$n) | .url'", "'.assets[] | select(.name==$n) | .browser_download_url'")
p.write_text(s)
PY

cleanup_partial() {
  set +e
  sudo umount /mnt/gio-a14 >/dev/null 2>&1 || true
  for mp in /mnt/gio-lower/*; do [ -d "$mp" ] && sudo umount "$mp" >/dev/null 2>&1 || true; done
  sudo dmsetup ls --noheadings -o name 2>/dev/null | awk '/^gio-public-pack-/ {print $1}' | xargs -r -n1 sudo dmsetup remove -f >/dev/null 2>&1 || true
  for dev in /dev/nbd*; do [ -b "$dev" ] && timeout 2s sudo nbd-client -d "$dev" >/dev/null 2>&1 || true; done
  sudo pkill -f nbdkit >/dev/null 2>&1 || true
  rm -rf /mnt/gio-meta /mnt/gio-lower /mnt/gio-upper /mnt/gio-work /mnt/gio-local-packs
  set -e
}

rc=1
for attempt in 1 2 3; do
  echo "GIO_PUBLIC_FABRIC_ATTEMPT=$attempt"
  if bash "$TMP" "$@"; then
    exit 0
  fi
  rc=$?
  echo "GIO_PUBLIC_FABRIC_TRANSIENT_FAILURE attempt=$attempt rc=$rc" >&2
  cleanup_partial
  [ "$attempt" -lt 3 ] && sleep $((attempt * 15))
done
exit "$rc"
