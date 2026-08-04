#!/bin/bash
#
# profile-local-model.sh
#
# Builds the app, launches it, and attaches CPU/GPU profilers.
# Reproduce your issue (send a message, trigger search_project, etc.)
# Then press ENTER to stop profiling and generate reports.
#
# Usage:
#   ./profile-local-model.sh
#
# Output:
#   /tmp/Compass-profile/  — all profiling artifacts
#   - sample.txt           — call stack samples (CPU hotspots)
#   - spindump.txt         — system-wide spin dump
#   - console.log          — all [LOCAL-MLX], [SEARCH-PROJECT], [TOOL-EXEC], [WEB-SEARCH] logs
#   - power.log            — GPU/CPU power metrics
#   - top-snapshots.txt    — periodic CPU/RAM snapshots
#

set -euo pipefail

APP_NAME="Compass"
APP_PATH="/Users/jack/Library/Developer/Xcode/DerivedData/Compass-eoaklgmzoruiukhbgdkrilmnzybq/Build/Products/Debug/Compass.app"
SCHEME="Compass"
OUTDIR="/tmp/Compass-profile"

echo "============================================"
echo "  Local Model Profiling Setup"
echo "============================================"

# Clean output dir
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Step 1: Build
echo ""
echo "[1/4] Building app..."
xcodebuild build -scheme "$SCHEME" -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /Users/jack/Library/Developer/Xcode/DerivedData/Compass-eoaklgmzoruiukhbgdkrilmnzybq \
    2>&1 | tail -3
if [ $? -ne 0 ]; then
    echo "BUILD FAILED"
    exit 1
fi
echo "Build OK."

# Step 2: Kill any existing instance
echo ""
echo "[2/4] Stopping any existing instance..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

# Step 3: Launch app and start profilers
echo ""
echo "[3/4] Launching app and attaching profilers..."

# Launch the app
open "$APP_PATH"
echo "App launched. Waiting for it to start..."
sleep 5

# Get the PID
PID=$(pgrep -x "$APP_NAME" | head -1)
if [ -z "$PID" ]; then
    echo "ERROR: Could not find $APP_NAME process. Is the app running?"
    exit 1
fi
echo "Found $APP_NAME PID: $PID"

# Start console log capture (stdout/stderr from the app process)
echo "Starting console log capture..."
# Capture app stdout/stderr via dtrace or direct redirection
# Since the app is already launched via `open`, we use log stream with broader filter
log stream --process "$PID" --style compact --predicate '
    eventMessage CONTAINS "[LOCAL-MLX]" OR
    eventMessage CONTAINS "[SEARCH-PROJECT]" OR
    eventMessage CONTAINS "[TOOL-EXEC]" OR
    eventMessage CONTAINS "[WEB-SEARCH]" OR
    eventMessage CONTAINS "[RAG]" OR
    eventMessage CONTAINS "memory_pressure" OR
    eventMessage CONTAINS "unload" OR
    eventMessage CONTAINS "[DIAG]" OR
    eventMessage CONTAINS "Compass"
' > "$OUTDIR/console.log" 2>&1 &
LOG_PID=$!

# Also capture os_log messages via separate stream
log stream --process "$PID" --style compact --level debug > "$OUTDIR/console-full.log" 2>&1 &
LOG2_PID=$!

# Start sampling profiler (runs in background, we stop it later)
echo "Starting CPU sampler..."
/usr/sbin/sample "$PID" 1200 -mayDie -file "$OUTDIR/sample.txt" &
SAMPLE_PID=$!

# Start periodic top snapshots (every 5 seconds)
echo "Starting resource monitor..."
(
    while true; do
        echo "=== $(date '+%H:%M:%S') ===" >> "$OUTDIR/top-snapshots.txt"
        top -l 1 -pid "$PID" -stats pid,command,cpu,mem,power 2>/dev/null >> "$OUTDIR/top-snapshots.txt" || true
        sleep 5
    done
) &
TOP_PID=$!

# Start power metrics (GPU/CPU usage)
echo "Starting power metrics..."
(
    while true; do
        echo "=== $(date '+%H:%M:%S') ===" >> "$OUTDIR/power.log"
        /usr/bin/powermetrics --samplers gpu_power,cpu_power,thermal -i 5000 -n 1 2>/dev/null >> "$OUTDIR/power.log" || true
        sleep 5
    done
) &
POWER_PID=$!

# Step 4: Wait for user to reproduce
echo ""
echo "============================================"
echo "  [4/4] PROFILING IN PROGRESS"
echo "============================================"
echo ""
echo "  The app is running. Now reproduce the issue:"
echo "  1. Open a project (e.g. sandbox/todo-app)"
echo "  2. Send a message that triggers tool use"
echo "  3. Watch for slow generation, high CPU, model unloading"
echo ""
echo "  Profilers are running:"
echo "    - CPU call stack sampling → $OUTDIR/sample.txt"
echo "    - Console telemetry       → $OUTDIR/console.log"
echo "    - Resource snapshots      → $OUTDIR/top-snapshots.txt"
echo "    - GPU/Power metrics       → $OUTDIR/power.log"
echo ""
echo "  Press ENTER when done to stop and generate reports..."
echo ""

read -r

# Stop all profilers
echo ""
echo "Stopping profilers..."
kill "$SAMPLE_PID" 2>/dev/null || true
kill "$LOG_PID" 2>/dev/null || true
kill "$LOG2_PID" 2>/dev/null || true
kill "$TOP_PID" 2>/dev/null || true
kill "$POWER_PID" 2>/dev/null || true

# Capture a final spindump (instantaneous)
echo "Capturing final spindump..."
/usr/sbin/spindump "$PID" 5 -file "$OUTDIR/spindump.txt" 2>/dev/null || true

# Also grab a full system powermetrics snapshot
echo "Capturing final powermetrics..."
/usr/bin/powermetrics --samplers gpu_power,cpu_power,thermal,tasks -i 1000 -n 1 2>/dev/null > "$OUTDIR/powermetrics-final.txt" || true

echo ""
echo "============================================"
echo "  PROFILING COMPLETE"
echo "============================================"
echo ""
echo "  Artifacts in $OUTDIR/:"
echo ""

# List files with sizes
for f in "$OUTDIR"/*; do
    if [ -f "$f" ]; then
        SIZE=$(du -h "$f" | cut -f1)
        echo "    $(basename "$f") ($SIZE)"
    fi
done

echo ""
echo "  Quick analysis:"
echo ""

# Count telemetry events
MLX_LOGS=$(grep -c '\[LOCAL-MLX\]' "$OUTDIR/console.log" 2>/dev/null || echo "0")
UNLOAD_LOGS=$(grep -c 'unload' "$OUTDIR/console.log" 2>/dev/null || echo "0")
SEARCH_LOGS=$(grep -c '\[SEARCH-PROJECT\]' "$OUTDIR/console.log" 2>/dev/null || echo "0")
TOOL_LOGS=$(grep -c '\[TOOL-EXEC\]' "$OUTDIR/console.log" 2>/dev/null || echo "0")
WEB_LOGS=$(grep -c '\[WEB-SEARCH\]' "$OUTDIR/console.log" 2>/dev/null || echo "0")
PERF_LOGS=$(grep -c '\[LOCAL-MLX-PERF\]' "$OUTDIR/console.log" 2>/dev/null || echo "0")

echo "    [LOCAL-MLX] events:       $MLX_LOGS"
echo "    [LOCAL-MLX-PERF] events:  $PERF_LOGS"
echo "    Unload events:            $UNLOAD_LOGS"
echo "    [SEARCH-PROJECT] events:  $SEARCH_LOGS"
echo "    [TOOL-EXEC] events:       $TOOL_LOGS"
echo "    [WEB-SEARCH] events:      $WEB_LOGS"
echo ""

# Show top CPU hotspots from sample
if [ -f "$OUTDIR/sample.txt" ]; then
    echo "  Top CPU hotspots (from sample):"
    grep -A 20 'depth 0' "$OUTDIR/sample.txt" 2>/dev/null | head -25 || true
    echo ""
fi

# Show key perf lines
if [ "$PERF_LOGS" -gt 0 ]; then
    echo "  Inference performance summary:"
    grep '\[LOCAL-MLX-PERF\]' "$OUTDIR/console.log" 2>/dev/null || true
    echo ""
fi

# Show unload events
if [ "$UNLOAD_LOGS" -gt 0 ]; then
    echo "  Model unload events:"
    grep 'unload' "$OUTDIR/console.log" 2>/dev/null | head -20 || true
    echo ""
fi

# Show search events
if [ "$SEARCH_LOGS" -gt 0 ]; then
    echo "  Search project events:"
    grep '\[SEARCH-PROJECT\]' "$OUTDIR/console.log" 2>/dev/null | head -20 || true
    echo ""
fi

echo "  Full logs: $OUTDIR/"
echo "  To view sample in Instruments: open $OUTDIR/sample.txt"
echo ""
