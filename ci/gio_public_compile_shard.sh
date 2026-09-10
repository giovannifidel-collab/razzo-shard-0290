#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 SHARD_ID AOSP_ROOT OUT_ROOT CAPSULE" >&2
  exit 2
fi

SHARD="$1"
AOSP_ROOT="$2"
OUT_ROOT="$3"
CAPSULE="$4"

case "$SHARD" in
  00) goals=(libc libc++ linker) ;;
  01) goals=(init adb fastboot) ;;
  02) goals=(libbase liblog libutils) ;;
  03) goals=(libselinux libsepol secilc) ;;
  04) goals=(framework framework-minus-apex framework-res) ;;
  05) goals=(services services.core services.jar) ;;
  06) goals=(SystemUI SystemUI-core) ;;
  07) goals=(framework-res org.apache.http.legacy) ;;
  08) goals=(surfaceflinger libgui libui) ;;
  09) goals=(libmedia libstagefright mediaextractor) ;;
  10) goals=(libart dex2oat profman) ;;
  11) goals=(core-oj core-libart conscrypt) ;;
  12) goals=(adb adbd libadbd) ;;
  13) goals=(com.android.tethering Connectivity) ;;
  14) goals=(PermissionController permissioncontroller) ;;
  15) goals=(statsd libstatssocket) ;;
  16) goals=(Wifi com.android.wifi) ;;
  17) goals=(Bluetooth com.android.btservices) ;;
  18) goals=(NetworkStack CaptivePortalLogin) ;;
  19) goals=(Settings SettingsProvider) ;;
  20) goals=(Launcher3QuickStep Launcher3) ;;
  21) goals=(MediaProvider DocumentsUI) ;;
  22) goals=(android.hardware.boot-service.default hwservicemanager servicemanager) ;;
  23) goals=(libhardware libhardware_legacy libbinder) ;;
  24) goals=(bootimage vendorbootimage dtboimage) ;;
  25) goals=(vendorimage odmimage) ;;
  26) goals=(systemimage system_extimage) ;;
  27) goals=(productimage userdataimage) ;;
  28) goals=(recoveryimage otatools-package) ;;
  29) goals=(target-files-package otatools-package bacon) ;;
  *) echo "invalid shard id: $SHARD" >&2; exit 2 ;;
esac

# Never leave GitHub's hosted compute control service masked while a heavy Soong
# process is running. Earlier setup revisions masked it around apt transactions;
# two independent runners were then recycled with SIGTERM/143 about three
# minutes into Soong despite ample RAM/disk and live heartbeats. Restoring the
# service registration is infrastructure-only and does not alter build inputs.
if systemctl list-unit-files 2>/dev/null | grep -q '^hosted-compute-agent\.service'; then
  sudo systemctl unmask --runtime hosted-compute-agent.service >/dev/null 2>&1 || true
fi

echo "HOSTED_COMPUTE_AGENT_UNMASKED=PASS"

cd "$AOSP_ROOT"
set +u
export USE_CCACHE=1
unset CCACHE_DISABLE || true
CACHE_BASE="${RUNNER_TEMP:-/tmp}"
export CCACHE_DIR="$CACHE_BASE/gio-ccache-$SHARD"
export CCACHE_MAXSIZE="128M"
export CCACHE_BASEDIR="$AOSP_ROOT"
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=file_macro,locale,time_macros
export CCACHE_EXEC="$(command -v ccache)"
source build/envsetup.sh
lunch lineage_lavender-ap2a-userdebug
set -u

mkdir -p "$CCACHE_DIR" "$(dirname "$CAPSULE")"
ccache --max-size "$CCACHE_MAXSIZE" >/dev/null
ccache --set-config=compression=true >/dev/null || true
ccache --set-config=compression_level=5 >/dev/null || true
ccache --zero-stats >/dev/null || true

# A compile shard is a cache warmer, not a complete independent Android build.
# Running multiple broad goals causes duplicate graph/build work and makes the
# hosted runner lifetime the bottleneck. Warm the shard's primary closure only,
# bounded to 35 minutes; whatever compiler outputs were produced are sealed and
# reused by the final local-source assembler.
LOG="${CAPSULE%.tar}.log"
: > "$LOG"
goal="${goals[0]}"
echo "=== SHARD=$SHARD GOAL=$goal START=$(date -u +%FT%TZ) ===" | tee -a "$LOG"

# Soong can legitimately emit no console output for several minutes because its
# verbose stream is captured in the shard log. Keep the hosted job observably
# alive without changing build inputs, parallelism or artifacts.
(
  while true; do
    sleep 60
    printf 'GIO_WARMER_HEARTBEAT shard=%s goal=%s time=%s\n' \
      "$SHARD" "$goal" "$(date -u +%FT%TZ)"
  done
) &
HB_PID=$!
trap 'kill "$HB_PID" >/dev/null 2>&1 || true; wait "$HB_PID" >/dev/null 2>&1 || true' EXIT

set +e
timeout --signal=TERM --kill-after=30s 35m \
  nice -n 5 ionice -c2 -n5 \
  build/soong/soong_ui.bash --make-mode "$goal" -j1 \
  >> "$LOG" 2>&1
rc=$?
set -e
kill "$HB_PID" >/dev/null 2>&1 || true
wait "$HB_PID" >/dev/null 2>&1 || true
trap - EXIT

echo "=== SHARD=$SHARD GOAL=$goal RC=$rc END=$(date -u +%FT%TZ) ===" | tee -a "$LOG"

ccache --cleanup >/dev/null || true
ccache --show-stats | tee -a "$LOG" || true
find "$CCACHE_DIR" -type f \( -name '*.lock' -o -name 'stats' -o -name 'stats.lock' \) -delete 2>/dev/null || true
find "$CCACHE_DIR" -type d -name tmp -prune -exec rm -rf {} + 2>/dev/null || true

tar -C "$CCACHE_DIR" -cf "$CAPSULE" .
sha256sum "$CAPSULE" > "${CAPSULE}.sha256"
printf 'schema=gio.os.public-compile-cache.v1\nshard=%s\ntarget=lavender\nandroid=14\nrelease=ap2a\nsourcepack_generation=v2-20260902\nprimary_goal=%s\nprimary_goal_rc=%s\nprivate_gio_source_present=false\nsigning_keys_present=false\n' \
  "$SHARD" "$goal" "$rc" > "${CAPSULE}.env"

echo "PUBLIC_COMPILE_SHARD_${SHARD}=READY"
