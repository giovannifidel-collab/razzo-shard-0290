#!/usr/bin/env bash
set -euo pipefail

AOSP_ROOT="${1:-/mnt/gio-a14}"
cd "$AOSP_ROOT"

python3 - <<'PY'
from pathlib import Path

path = Path('frameworks/base/services/java/com/android/server/SystemServer.java')
text = path.read_text()
marker = '// GIO_OS_PRIVATE_CORE_JAR_HOOK_V1'
if marker not in text:
    anchors = [
        'private void startOtherServices(@NonNull TimingsTraceAndSlog t) {',
        'private void startOtherServices(TimingsTraceAndSlog t) {',
    ]
    anchor = next((a for a in anchors if a in text), None)
    if anchor is None:
        raise SystemExit('unsupported SystemServer startOtherServices anchor')
    hook = '''\n        // GIO_OS_PRIVATE_CORE_JAR_HOOK_V1\n        try {\n            mSystemServiceManager.startServiceFromJar(\n                    "com.android.server.gioos.GioOsManagerService",\n                    "/system/framework/gioos-services.jar");\n        } catch (RuntimeException e) {\n            Slog.i(TAG, "GIO OS private Secure Core is not installed in this public base");\n        }\n'''
    path.write_text(text.replace(anchor, anchor + hook, 1))
verify = path.read_text()
required = [
    marker,
    'startServiceFromJar(',
    'com.android.server.gioos.GioOsManagerService',
    '/system/framework/gioos-services.jar',
]
if not all(x in verify for x in required):
    raise SystemExit('generic GIO jar hook verification failed')
print('GIO_PUBLIC_PRIVATE_CORE_HOOK=PASS')
PY

# Public compile workers must never contain the private GIO implementation or signing material.
test ! -e vendor/gioos
test ! -e frameworks/base/services/core/java/com/android/server/gioos
