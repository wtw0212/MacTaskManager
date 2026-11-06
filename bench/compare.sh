#!/bin/bash
# Builds the Swift/SwiftUI app and the Rust/GPUI app in release mode, then runs each one alone
# on the Performance page and on the Processes page and measures it with bench/measure.py.
#
# Each run opens the app's window in front for WARMUP + DURATION seconds, so run this when you
# aren't using the Mac (or in CI). Results go to $OUT (default bench/results/<timestamp>/).
#
#   DURATION=60 WARMUP=10 SCREENSHOTS=1 ./bench/compare.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${DURATION:-60}"
WARMUP="${WARMUP:-10}"
SCREENSHOTS="${SCREENSHOTS:-0}"
OUT="${OUT:-bench/results/$(date +%Y%m%d-%H%M%S)}"
RUST_FEATURES="${RUST_FEATURES:-}"
mkdir -p "$OUT"

echo "Building Swift (release)…"
swift build -c release
SWIFT_BIN="$(swift build -c release --show-bin-path)/TaskManager"

echo "Building Rust (release)…"
(cd rust-gpui && cargo build --release ${RUST_FEATURES:+--features "$RUST_FEATURES"})
RUST_BIN="rust-gpui/target/release/TaskManagerGPUI"

run() {
    local label="$1"; shift
    echo "Measuring $label…"
    "$@" >"$OUT/$label.log" 2>&1 &
    local pid=$!
    if [ "$SCREENSHOTS" = 1 ]; then
        (sleep "$WARMUP"; screencapture -x "$OUT/$label.png" || true) &
    fi
    python3 bench/measure.py sample --pid "$pid" --label "$label" \
        --warmup "$WARMUP" --duration "$DURATION" --out "$OUT/$label.json"
    # Memory by category (IOSurface, IOAccelerator, malloc, …) when the tool may inspect the app.
    footprint "$pid" >"$OUT/$label.footprint.txt" 2>&1 || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 2
}

# The Swift app keeps its page in UserDefaults ("selectedPage"); a launch argument overrides it
# for this run only, without changing the saved setting.
run swift-performance "$SWIFT_BIN" -selectedPage Performance
run rust-performance "$RUST_BIN" --page performance
run swift-processes "$SWIFT_BIN" -selectedPage Processes
run rust-processes "$RUST_BIN" --page processes

python3 bench/measure.py report \
    "$OUT/swift-performance.json" "$OUT/rust-performance.json" \
    "$OUT/swift-processes.json" "$OUT/rust-processes.json" \
    --sizes "$SWIFT_BIN" "$RUST_BIN" | tee "$OUT/report.md"
