#!/usr/bin/env bash
# Validation gate for firmware/ai-passport-card (adapted from FoloToy/ai-passport tools/validate.sh).
#   --static    host tests (cmake/ctest, no ESP-IDF) + asset checks
#   --firmware  isolated ESP-IDF build + merge-bin + merged-image layout verification
#   --all       both (default)
set -euo pipefail

mode="${1:---all}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

run_static_checks() {
    # generated assets must be present and complete
    for f in assets/cues/celebrate.pcm assets/cues/tick.pcm assets/cues/connect.pcm \
             assets/fonts/font_digits_36.c assets/fonts/font_digits_20.c \
             assets/images/theme_base.c assets/images/theme_neon_city.c assets/images/theme_data_nebula.c; do
        [[ -s "$f" ]] || { echo "missing asset: $f" >&2; exit 1; }
    done
    for size in 36 20; do
        glyphs=$(grep -c '^    /\* U+' "assets/fonts/font_digits_${size}.c")
        [[ "$glyphs" == "19" ]] || { echo "font_digits_${size}.c has ${glyphs} glyphs, expected 19" >&2; exit 1; }
    done
    for t in base neon_city data_nebula; do
        grep -q "const lv_image_dsc_t theme_${t} = {" "assets/images/theme_${t}.c" || { echo "theme_${t}.c: missing descriptor" >&2; exit 1; }
        grep -q '.header.cf = LV_COLOR_FORMAT_RGB565' "assets/images/theme_${t}.c" || { echo "theme_${t}.c: not RGB565" >&2; exit 1; }
        grep -q '.data_size = 153600' "assets/images/theme_${t}.c" || { echo "theme_${t}.c: data_size != 240*320*2" >&2; exit 1; }
    done
    # cue generator must be deterministic
    tmp="$(mktemp -d)"
    cp assets/cues/*.pcm "${tmp}/"
    python3 tools/gen_cues.py >/dev/null
    for f in celebrate tick connect; do
        cmp -s "assets/cues/${f}.pcm" "${tmp}/${f}.pcm" || { echo "gen_cues.py is not deterministic (${f})" >&2; exit 1; }
    done
    rm -rf "${tmp}"

    cmake -S tests -B build-host >/dev/null
    cmake --build build-host >/dev/null
    ctest --test-dir build-host --output-on-failure
    echo "Host tests: PASS"
}

run_firmware_checks() (
    if ! command -v idf.py >/dev/null 2>&1; then
        echo "ERROR: idf.py is not available; source ~/esp/esp-idf-v5.5.3/export.sh first." >&2
        return 1
    fi
    dir="$(mktemp -d /tmp/spatialcard-firmware.XXXXXX)"
    trap 'case "${dir}" in /tmp/spatialcard-firmware.*) rm -rf -- "${dir}" ;; esac' EXIT
    idf.py -B "${dir}" -D "SDKCONFIG=${dir}/sdkconfig" -D "SDKCONFIG_DEFAULTS=${root}/sdkconfig.defaults" build
    idf.py -B "${dir}" merge-bin -o "${dir}/spatialcard-full.bin"
    python3 tools/verify_firmware.py "${dir}"
    mkdir -p build
    install -m 0644 "${dir}/spatialcard-full.bin" build/spatialcard-full.bin
    echo "Firmware build: PASS (build/spatialcard-full.bin)"
)

case "${mode}" in
    --all) run_static_checks; run_firmware_checks ;;
    --static) run_static_checks ;;
    --firmware) run_firmware_checks ;;
    *) echo "Usage: $0 [--all|--static|--firmware]" >&2; exit 2 ;;
esac
