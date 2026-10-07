#!/usr/bin/env bash
# One headset round from the Mac, in as few commands as possible.
#
#   tools/round.sh build                  # xcodegen + device build (Xcode-beta) into visionos/SpatialCard/build/dd-device
#   tools/round.sh install                # install that build (headset awake + unlocked; closes the running app)
#   tools/round.sh logs <name>            # newest headset log → visionos/SpatialCard/build/device-logs/<name>.log
#   tools/round.sh summary <name|path>    # one screen: perf windows, keys, tracking, pick-up, recognition, worlds, audit, hitches
#   tools/round.sh perf '<arg>' …         # cmd perf through the Hub, one arg per window ('-' = measure only);
#                                         # 9 s apart, 11 s after a rehearse (GAP=… / GAP_REHEARSE=… to change)
#
# The Hub is neither started nor stopped here: that needs the user's OK, and the main session runs it in its own
# terminal tab. Environment: VP_UDID (headset), HUB_URL (default http://localhost:8787).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPDIR=$ROOT/visionos/SpatialCard
DD=$APPDIR/build/dd-device
APP=$DD/Build/Products/Debug-xros/SpatialCard.app
LOGS=$APPDIR/build/device-logs
DEVICE=${VP_UDID:-}
HUB=${HUB_URL:-http://localhost:8787}
BETA=/Applications/Xcode-beta.app/Contents/Developer      # builds: the SDK the smokes ran on
RELEASE=/Applications/Xcode.app/Contents/Developer        # installs: the headset may run a newer visionOS than the beta

usage() { sed -n '2,13p' "$0"; }

cmd=${1:-help}
[ $# -gt 0 ] && shift

case "$cmd" in
build)
    mkdir -p "$APPDIR/build"
    if ! (cd "$APPDIR" && DEVELOPER_DIR=$BETA xcodegen >/dev/null &&
          DEVELOPER_DIR=$BETA xcodebuild -scheme SpatialCard -destination 'generic/platform=visionOS' \
              -derivedDataPath "$DD" build >"$APPDIR/build/round-build.log" 2>&1); then
        grep -E 'error:' "$APPDIR/build/round-build.log" | head -20 || tail -20 "$APPDIR/build/round-build.log"
        echo "[round] build failed (full log: visionos/SpatialCard/build/round-build.log)"
        exit 1
    fi
    n=$(find "$APP" -name '*.referenceobject' | wc -l | tr -d ' ')
    echo "[round] built $(git -C "$ROOT" log --oneline -1) (reference objects in the app: $n)"
    [ "$n" -ge 1 ] || echo "[round] WARNING: no .referenceobject in the app — it only exists in the active worktree"
    ;;

install)
    [ -n "$DEVICE" ] || { echo "Set VP_UDID before installing." >&2; exit 2; }
    [ -d "$APP" ] || { echo "[round] no build at $APP — run: tools/round.sh build"; exit 1; }
    line=$(DEVELOPER_DIR=$RELEASE xcrun devicectl list devices 2>/dev/null | grep -i 'vision pro' | grep -i physical || true)
    echo "[round] headset: ${line:-not listed}"
    case "$line" in
        *available*) ;;
        *) echo "[round] the headset is not available: wake it, unlock it, keep it on the same network"; exit 1 ;;
    esac
    out=$(DEVELOPER_DIR=$RELEASE xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 || true)
    if printf '%s' "$out" | grep -q 'App installed'; then
        echo "[round] installed $(git -C "$ROOT" log --oneline -1) — 装好了，可以从主屏打开 App"
    else
        printf '%s\n' "$out" | tail -15
        echo "[round] install failed"
        exit 1
    fi
    ;;

logs)
    name=${1:?usage: tools/round.sh logs <name>}
    mkdir -p "$LOGS"
    out=$LOGS/$name.log
    "$ROOT/tools/vp-logs.sh" >"$out" 2>/dev/null
    echo "[round] $(wc -l <"$out" | tr -d ' ') lines → ${out#"$ROOT"/}"
    head -1 "$out"
    ;;

summary)
    arg=${1:?usage: tools/round.sh summary <name|path>}
    if [ -f "$arg" ]; then f=$arg; else f=$LOGS/$arg.log; fi
    [ -f "$f" ] || { echo "[round] no log at $f"; exit 1; }
    section() { printf '\n== %s\n' "$1"; }
    head -1 "$f"
    section "perf windows (line · window · avg fps · worst)"
    grep -nE '^\[perf(:[a-z0-9]+)?\] .*frames in' "$f" |
        sed -E 's/^([0-9]+):\[perf(:[a-z0-9]+)?\] /\1 · /; s/: [0-9]+ frames in [0-9.]+ s, avg / · /; s/ fps, worst / · /; s/, [0-9]+ frames > 13\.3 ms//' || true
    section "scene census at the end of perf windows (first 5)"
    grep -nE '^\[perf(:[a-z0-9]+)?\] scene: ' "$f" | head -5 | cut -c1-170 || true
    section "keys"
    echo "presses: $(grep -c '^\[keys\]' "$f" || true); ignored:"
    grep -n '^\[keys\].*ignored' "$f" | cut -c1-170 || true
    section "tracking"
    grep -nE '^\[track\] segment' "$f" | cut -c1-190 || true
    grep -nE '^\[track\] in view but untracked ended' "$f" | cut -c1-120 || true
    section "pick-up"
    grep -nE '^\[pickup\] (a pick-up|not a pick-up|lost on the desk|guarded)|pick-up fold: the card goes' "$f" | cut -c1-170 || true
    section "recognition"
    grep -nE "^\[v4\] recognition #[0-9]+: |fallback|^\[v4\] hand reveal: the card" "$f" | cut -c1-170 || true
    section "worlds"
    grep -nE '^\[world\] (entering .*\(|inside |back |aborted|prebuilt root)|prebuilt .* dropped' "$f" | cut -c1-170 || true
    section "audit (footprint findings)"
    grep -cE '^\[footprint\] [^ ]+ +inside' "$f" || true
    section "frame hitches ≥ 50 ms"
    grep -nE '^\[v4\] frame hitch [0-9]+ ms' "$f" | awk '{ for (i = 1; i <= NF; i++) if ($i == "hitch") { ms = $(i + 1) } } ms + 0 >= 50' | cut -c1-150 || true
    section "error lines"
    grep -niE '\berror\b' "$f" | grep -viE 'error type|no error|errors? 0' | head -10 | cut -c1-170 || true
    ;;

perf)
    [ $# -gt 0 ] || { echo "usage: tools/round.sh perf '<arg>' … ('-' = measure only)"; exit 1; }
    gap=${GAP:-9}
    gap_rehearse=${GAP_REHEARSE:-11}
    failed=0
    for a in "$@"; do
        if [ "$a" = "-" ]; then body='{"c":"perf"}'; else body=$(printf '{"c":"perf","arg":"%s"}' "$a"); fi
        printf '%s  %-60s ' "$(date '+%H:%M:%S')" "${a}"
        reply=$(curl -s -m 5 -X POST "$HUB/api/cmd" -H 'content-type: application/json' -d "$body" || true)
        case "$reply" in
            *'"ok":true'*) echo "${reply:0:60}" ;;
            "") echo "(no reply: is the Hub running?)"; failed=$((failed + 1)) ;;
            *) echo "FAILED: ${reply:0:120}"; failed=$((failed + 1)) ;;
        esac
        case "$a" in *rehearse*) sleep "$gap_rehearse" ;; *) sleep "$gap" ;; esac
    done
    echo "[round] perf sequence done $(date '+%H:%M:%S') — $failed of $# commands not accepted"
    [ "$failed" -eq 0 ]
    ;;

help | -h | --help) usage ;;
*) echo "unknown command: $cmd"; usage; exit 2 ;;
esac
