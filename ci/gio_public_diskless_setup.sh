#!/usr/bin/env bash
set -euo pipefail
ORIG="$GITHUB_WORKSPACE/ci/gio_public_diskless_setup_orig.sh"
TMP="${RUNNER_TEMP:-/tmp}/gio_public_diskless_setup_inner.sh"
cp "$ORIG" "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('asset_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")','true')
s=s.replace('asset_headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )','true')
s=s.replace('nbd_args+=(header="Authorization: Bearer ${GITHUB_TOKEN}")','true')
s=s.replace('nbd_args+=( header="Authorization: Bearer ${GITHUB_TOKEN}" )','true')
s=s.replace("'.assets[]|select(.name==$n)|.url'","'.assets[]|select(.name==$n)|.browser_download_url'")
s=s.replace("'.assets[] | select(.name==$n) | .url'","'.assets[] | select(.name==$n) | .browser_download_url'")
# A failed remote-pack attempt can leave a forced/busy dm mapping alive briefly.
# Key the mapper by the monotonically advancing nbd index so an in-run retry
# never collides with a stale name. This changes only runner plumbing, not data.
s=s.replace('sudo dmsetup create "gio-public-pack-${id}"<"$table"; packdev="/dev/mapper/gio-public-pack-${id}"', 'dmname="gio-public-pack-${id}-${nbd}"; sudo dmsetup create "$dmname"<"$table"; packdev="/dev/mapper/$dmname"')
p.write_text(s)
PY
bash -n "$TMP"
cleanup_partial(){
 set +e
 sudo umount /mnt/gio-a14 >/dev/null 2>&1||true
 if [ -d /mnt/gio-lower ]; then for mp in /mnt/gio-lower/*; do [ -d "$mp" ]&&sudo umount -l "$mp" >/dev/null 2>&1||true; done; fi
 for pass in 1 2 3; do
  sudo dmsetup ls --noheadings -o name 2>/dev/null|awk '/^gio-public-pack-/ {print $1}'|xargs -r -n1 sudo dmsetup remove -f >/dev/null 2>&1||true
  sudo pkill -f 'nbdkit.*gio-public' >/dev/null 2>&1||true
  for dev in /dev/nbd*; do [ -b "$dev" ]||continue; timeout 3s sudo nbd-client -d "$dev" >/dev/null 2>&1||true; done
  sudo udevadm settle --timeout=5 >/dev/null 2>&1||true; sleep 1
 done
 sudo dmsetup ls --noheadings -o name 2>/dev/null|awk '/^gio-public-pack-/ {print $1}'|xargs -r -n1 sudo dmsetup remove -f >/dev/null 2>&1||true
 sudo rm -rf /mnt/gio-meta /mnt/gio-lower /mnt/gio-upper /mnt/gio-work /mnt/gio-local-packs
 set -e
}
cleanup_partial
rc=1
for attempt in 1 2 3 4 5 6 7 8; do
 echo "GIO_PUBLIC_FABRIC_ATTEMPT=$attempt"
 if bash "$TMP" "$@"; then exit 0; else rc=$?; fi
 echo "GIO_PUBLIC_FABRIC_TRANSIENT_FAILURE attempt=$attempt rc=$rc" >&2
 cleanup_partial
 [ "$attempt" -lt 8 ]&&sleep $((attempt < 4 ? attempt*15 : 45))
done
exit "$rc"
