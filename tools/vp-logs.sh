#!/usr/bin/env bash
# Pull the Spatial Card log files off the Vision Pro and print the newest one.
#
# The app mirrors every `print` into <Documents>/logs/spatialcard-<yyyyMMdd-HHmmss>.log (Sources/App/Log.swift),
# so a run that was not started with `devicectl … --console` (or one whose console scrolled away) can still be
# read afterwards. Requires a development build of the app on a paired, unlocked headset.
#
#   tools/vp-logs.sh                        # newest log, whole file
#   tools/vp-logs.sh --tail 200             # last 200 lines
#   tools/vp-logs.sh --grep '\[gate\] Σ'    # only the 5 s gate summaries
#   tools/vp-logs.sh --list                 # what is in the container, newest last
#   tools/vp-logs.sh --all --grep '\[mesh\]'  # across every pulled file
#   VP_UDID=… tools/vp-logs.sh              # another headset
set -euo pipefail

DEVICE="${VP_UDID:-}"
BUNDLE="${VP_BUNDLE:-org.spatialcard.spatialcard}"
TAIL=""
PATTERN=""
LIST=0
ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tail) TAIL="${2:-}"; shift 2 ;;
        --grep) PATTERN="${2:-}"; shift 2 ;;
        --list) LIST=1; shift ;;
        --all) ALL=1; shift ;;
        --device) DEVICE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

[ -n "$DEVICE" ] || { echo "Set VP_UDID or pass --device <device-id>." >&2; exit 2; }

DEST="$(mktemp -d "${TMPDIR:-/tmp}/vp-logs.XXXXXX")"
trap 'rm -rf "$DEST"' EXIT

echo "[vp-logs] pulling Documents/logs from $BUNDLE on $DEVICE …" >&2
# devicectl's JSON file is its only supported script interface (see `copy from --help`); the stderr text is kept
# so a genuine failure can be shown verbatim.
JSON="$DEST/.devicectl.json"
ERR="$DEST/.devicectl.stderr"
STATUS=0
xcrun devicectl device copy from \
    --device "$DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" \
    --source Documents/logs \
    --destination "$DEST" \
    --json-output "$JSON" >/dev/null 2>"$ERR" || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    # CoreDeviceError 7000 ("Failed to retrieve the file node for Documents/logs") means the container is reachable
    # but the app has not created the folder yet — installed, never run. That is the "no logs yet" case below, not a
    # failure. Anything else (device not found = 1000, unknown bundle id = -1, locked headset, missing/unreadable JSON)
    # is reported as is and keeps devicectl's exit status.
    CODE="$(plutil -extract error.code raw -o - "$JSON" 2>/dev/null || true)"
    DOMAIN="$(plutil -extract error.domain raw -o - "$JSON" 2>/dev/null || true)"
    if [ "$CODE" != "7000" ] || [ "$DOMAIN" != "com.apple.dt.CoreDeviceError" ]; then
        cat "$ERR" >&2
        echo "[vp-logs] devicectl copy failed (exit $STATUS)" >&2
        exit "$STATUS"
    fi
fi

# devicectl drops the folder itself into --destination; find the files wherever they landed.
FILES="$(find "$DEST" -type f -name 'spatialcard-*.log' | sort)"
if [ -z "$FILES" ]; then
    echo "[vp-logs] no spatialcard-*.log in the container yet (has the app run since it was installed?)" >&2
    exit 1
fi

if [ "$LIST" = "1" ]; then
    # shellcheck disable=SC2086
    (cd "$DEST" && find . -type f -name 'spatialcard-*.log' -exec ls -lh {} \; | sort -k9)
    exit 0
fi

if [ "$ALL" = "1" ]; then
    TARGETS="$FILES"
else
    TARGETS="$(echo "$FILES" | tail -1)"
fi

for f in $TARGETS; do
    echo "[vp-logs] ===== $(basename "$f") =====" >&2
    OUT="$(cat "$f")"
    if [ -n "$PATTERN" ]; then
        OUT="$(printf '%s\n' "$OUT" | grep -E -- "$PATTERN" || true)"
    fi
    if [ -n "$TAIL" ]; then
        OUT="$(printf '%s\n' "$OUT" | tail -n "$TAIL")"
    fi
    printf '%s\n' "$OUT"
done
