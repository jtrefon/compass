#!/bin/bash

# run.sh - Unified build and run script for Compass

PROJECT_NAME="Compass"
APP_PRODUCT_NAME="Compass"
SCHEME="Compass"
DERIVED_DATA_PATH_APP="./.build"
DERIVED_DATA_PATH_TEST="./.build-tests"

prepare_derived_data_packages() {
    local derived_data_path=$1
    xcodebuild -resolvePackageDependencies \
        -project "$PROJECT_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -derivedDataPath "$derived_data_path" \
        -skipPackagePluginValidation >/dev/null || true
}

collect_descendant_pids() {
    local root_pid=$1
    local children
    children=$(pgrep -P "$root_pid" || true)
    for child_pid in $children; do
        echo "$child_pid"
        collect_descendant_pids "$child_pid"
    done
}

collect_guarded_family_pids() {
    local root_pid=$1
    local root_pgid
    local derived_data_root
    root_pgid=$(ps -o pgid= -p "$root_pid" 2>/dev/null | awk '{print $1}')
    derived_data_root=$(cd "$DERIVED_DATA_PATH_TEST" 2>/dev/null && pwd -P)

    {
        echo "$root_pid"
        collect_descendant_pids "$root_pid"
        if [ -n "$root_pgid" ]; then
            ps -axo pid=,pgid=,comm= | awk -v pgid="$root_pgid" -v project_name="$PROJECT_NAME" -v derived_data_root="$derived_data_root" '
                function basename(path, parts, count) {
                    count = split(path, parts, "/")
                    return parts[count]
                }

                {
                    full_command = $3
                    command_name = basename(full_command)
                    is_project_process = 0
                    is_test_tool = 0
                    is_derived_data_app = 0

                    if (command_name == project_name ||
                        command_name == project_name "-Runner" ||
                        command_name == project_name "Tests" ||
                        command_name == project_name "HarnessTests") {
                        is_project_process = 1
                    }

                    if (command_name == "xcodebuild" || command_name == "xctest") {
                        is_test_tool = 1
                    }

                    if (derived_data_root != "" &&
                        index(full_command, derived_data_root) == 1 &&
                        is_project_process == 1) {
                        is_derived_data_app = 1
                    }

                    if (($2 == pgid && (is_test_tool == 1 || is_project_process == 1)) || is_derived_data_app == 1) {
                        print $1
                    }
                }
            '
        fi
    } | awk 'NF { if (!seen[$1]++) print $1 }'
}

describe_guarded_family() {
    local root_pid=$1
    local family_pids
    family_pids=$(collect_guarded_family_pids "$root_pid" | paste -sd, -)
    if [ -z "$family_pids" ]; then
        return
    fi

    ps -axo pid=,ppid=,pgid=,rss=,comm= | awk -v family_csv="$family_pids" '
        BEGIN {
            split(family_csv, pids, ",")
            for (pid_index in pids) {
                tracked[pids[pid_index]] = 1
            }
        }
        tracked[$1] {
            printf "%s(ppid=%s,pgid=%s,rss_mb=%d,comm=%s)", $1, $2, $3, int($4 / 1024), $5
        }
    ' | paste -sd';' -
}

sum_process_tree_rss_mb() {
    local root_pid=$1
    local rss_kb=0
    local pid

    for pid in $(collect_guarded_family_pids "$root_pid"); do
        local pid_rss
        pid_rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{s+=$1} END {print s+0}')
        rss_kb=$((rss_kb + pid_rss))
    done

    echo $((rss_kb / 1024))
}

kill_process_tree() {
    local root_pid=$1
    local pid

    for pid in $(collect_guarded_family_pids "$root_pid"); do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 2

    for pid in $(collect_guarded_family_pids "$root_pid"); do
        kill -KILL "$pid" 2>/dev/null || true
    done
}

run_with_memory_guard() {
    local rss_limit_gb=$1
    shift
    local rss_limit_mb=$((rss_limit_gb * 1024))
    local check_interval_seconds="${HARNESS_MEMORY_CHECK_INTERVAL_SECONDS:-1}"
    local status_file
    status_file=$(mktemp)

    "$@" &
    local guarded_pid=$!

    cleanup_guarded_processes() {
        if [ -n "$monitor_pid" ]; then
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true
        fi
        if kill -0 "$guarded_pid" 2>/dev/null; then
            echo "[harness-memory] interruption detected, terminating harness process tree"
            kill_process_tree "$guarded_pid"
        fi
    }

    trap cleanup_guarded_processes INT TERM

    (
        while kill -0 "$guarded_pid" 2>/dev/null; do
            local rss_mb
            local family_description
            rss_mb=$(sum_process_tree_rss_mb "$guarded_pid")
            family_description=$(describe_guarded_family "$guarded_pid")
            echo "[harness-memory] pid=$guarded_pid rss_mb=$rss_mb limit_mb=$rss_limit_mb family=${family_description:-unavailable}"

            if [ "$rss_mb" -ge "$rss_limit_mb" ]; then
                echo "[harness-memory] limit exceeded, terminating harness test process tree"
                echo "killed" > "$status_file"
                kill_process_tree "$guarded_pid"
                break
            fi

            sleep "$check_interval_seconds"
        done
    ) &
    local monitor_pid=$!

    wait "$guarded_pid"
    local command_exit_code=$?
    trap - INT TERM
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    if grep -q "killed" "$status_file" 2>/dev/null; then
        rm -f "$status_file"
        echo "[harness-memory] harness terminated due to memory guard (limit ${rss_limit_gb}GB)"
        return 99
    fi

    rm -f "$status_file"
    return "$command_exit_code"
}

show_help() {
    echo "Usage: ./run.sh [command]"
    echo ""
    echo "Commands:"
    echo "  app    Build and launch the application"
    echo "  build  Build the application"
    echo "  test   Run unit tests [optional suite]"
    echo "         Examples: ./run.sh test | ./run.sh test JSONHighlighterTests | ./run.sh test json"
    echo "  harness Run headless harness tests (separate from CI test)"
    echo "         Examples: ./run.sh harness | ./run.sh harness ConversationSendCoordinatorTests"
    echo "  harness-online Run online production-parity harness suites"
    echo "         Examples: ./run.sh harness-online | ./run.sh harness-online AgenticHarnessTests"
    echo "  harness-offline Run offline-only harness suites"
    echo "         Examples: ./run.sh harness-offline | ./run.sh harness-offline StripMarkupTest"
    echo "  benchmark-offline Run offline inference benchmark harnesses"
    echo "         Examples: ./run.sh benchmark-offline | ./run.sh benchmark-offline sweep"
    echo "  benchmark-local  Run the local chat KPI benchmark (Qwen3.5-4B)"
    echo "         Example: COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE=512 ./run.sh benchmark-local"
    echo "  benchmark  Run the core benchmark suites (embeddings + metrics); JSON in .build-tests/benchmarks/"
    echo "  lint   Run SwiftLint locally (advisory — see .swiftlint.yml)"
    echo "  check-prompts Verify every prompt file under Prompts/ has a code reference (no orphan prompts)"
    echo "  e2e    Run UI (end-to-end) tests [optional suite]"
    echo "         Examples: ./run.sh e2e | ./run.sh e2e TerminalEchoUITests | ./run.sh e2e json"
    echo "  clean  Clean build artifacts"
    echo "  help   Show this help message"
}

copy_embedding_models() {
    local dest="$DERIVED_DATA_PATH_APP/Build/Products/Debug/$APP_PRODUCT_NAME.app/Contents/Resources/EmbeddingModels"
    mkdir -p "$dest"
    local src="$(pwd)/Compass/Resources/EmbeddingModels"
    if [ -d "$src/bge-small-en-v1.5.mlmodelc" ]; then
        rsync -aq --delete "$src/" "$dest/"
        echo "[EMB] Copied embedding models to bundle"
    else
        echo "[EMB] WARNING: No embedding models found at $src — RAG embeddings disabled"
    fi
}

build_app() {
    echo "Building $PROJECT_NAME..."
    # NOTE: no automatic clean here — incremental builds are much faster.
    # Run `./run.sh clean` manually when stale artifacts are suspected.
    xcodebuild -resolvePackageDependencies \
        -project "$PROJECT_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA_PATH_APP" \
        -skipPackagePluginValidation >/dev/null || true
    xcodebuild -quiet -project "$PROJECT_NAME.xcodeproj" \
               -scheme "$SCHEME" \
               -configuration Debug \
               -derivedDataPath "$DERIVED_DATA_PATH_APP" \
               -skipPackagePluginValidation \
               build
    copy_embedding_models
}

launch_app() {
    # Find the app bundle in derived data
    APP_PATH=$(find "$DERIVED_DATA_PATH_APP" -name "$APP_PRODUCT_NAME.app" -type d | head -n 1)
    
    if [ -z "$APP_PATH" ]; then
        echo "Error: Could not find built application. Please run './run.sh build' first."
        exit 1
    fi

    echo "Launching $APP_PATH..."
    open "$APP_PATH"
}

# ---------------------------------------------------------------------------
# Device quarantine: Xcode's DTDK tries to install developer services on every
# available device during `xcodebuild test` — a locked (passcode-protected)
# iPhone then stalls the hosted test launch with "device is passcode protected"
# retries, and every scheduled test fails without running. We unpair paired
# iPhone/iPad devices before testing and re-pair afterwards (best-effort).
# The phone stays physically connected and on Wi-Fi the whole time; pairing
# also auto-restores on next unlock even if the restore step is skipped.
# Opt out entirely with: COMPASS_QUARANTINE_DEVICES=0
# ---------------------------------------------------------------------------
quarantine_paired_ios_devices() {
    [ "${COMPASS_QUARANTINE_DEVICES:-1}" = "1" ] || { echo "[devices] quarantine disabled (COMPASS_QUARANTINE_DEVICES=0)"; return 0; }
    command -v xcrun >/dev/null 2>&1 || return 0
    echo "[devices] Unpairing paired iPhone/iPad devices so tests are not blocked by locked devices..."
    python3 - <<'PYEOF2'
import json, os, subprocess, sys, tempfile

def devicectl(*args, timeout=20):
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, timeout=timeout)

def list_devices():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        path = f.name
    try:
        r = devicectl("list", "devices", "--json-output", path)
        if r.returncode != 0:
            print(f"[devices] list failed: {r.stderr.strip()[:200]}", file=sys.stderr)
            return []
        return json.load(open(path)).get("result", {}).get("devices", [])
    except Exception as e:
        print(f"[devices] list error: {e}", file=sys.stderr)
        return []
    finally:
        os.unlink(path)

for d in list_devices():
    if d.get("visibilityClass") == "unavailable":
        continue
    dev_type = d.get("hardwareProperties", {}).get("deviceType", "")
    pairing = d.get("connectionProperties", {}).get("pairingState", "")
    if dev_type in ("iPhone", "iPad") and pairing == "paired":
        name = d.get("deviceProperties", {}).get("name", "?")
        ident = d["identifier"]
        try:
            r = devicectl("manage", "unpair", "--device", ident)
        except subprocess.TimeoutExpired:
            print(f"[devices] warning: unpair timed out for {name}", file=sys.stderr)
            continue
        if r.returncode == 0:
            print(f"[devices] quarantined {name} ({ident})")
        else:
            print(f"[devices] warning: could not unpair {name}: {r.stderr.strip()[:200]}", file=sys.stderr)
PYEOF2
}


# xcodebuild does not propagate env vars into the app-hosted test process, so
# the test profile dir is handed over via the app's standard defaults domain
# (see AppLaunchContext.detect). Set before a test run, removed afterwards so
# normal app launches never see it.
# The app is sandboxed and cfprefsd clobbers external defaults writes, so the
# test profile dir is handed over via a plain marker file inside the app's
# sandbox container (AppLaunchContext.detect reads it for test processes).
APP_PROFILE_MARKER_FILE="$HOME/Library/Application Support/compass-test-profile-path"

write_test_profile_defaults() {
    mkdir -p "$HOME/Library/Application Support"
    printf '%s' "$1" > "$APP_PROFILE_MARKER_FILE"
}

clear_test_profile_defaults() {
    rm -f "$APP_PROFILE_MARKER_FILE"
}

restore_quarantined_ios_devices() {
    [[ "${COMPASS_QUARANTINE_DEVICES:-1}" == "1" ]] || return 0
    command -v xcrun >/dev/null 2>&1 || return 0
    echo "[devices] Re-pairing quarantined iOS devices (best-effort; auto-pairs on next unlock)..."
    python3 - <<'PYEOF2'
import json, os, subprocess, sys, tempfile

def devicectl(*args, timeout=20):
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, timeout=timeout)

def list_devices():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        path = f.name
    try:
        r = devicectl("list", "devices", "--json-output", path)
        if r.returncode != 0:
            return []
        return json.load(open(path)).get("result", {}).get("devices", [])
    except Exception:
        return []
    finally:
        os.unlink(path)

for d in list_devices():
    if d.get("visibilityClass") == "unavailable":
        continue
    dev_type = d.get("hardwareProperties", {}).get("deviceType", "")
    pairing = d.get("connectionProperties", {}).get("pairingState", "")
    if dev_type in ("iPhone", "iPad") and pairing != "paired":
        ident = d["identifier"]
        name = d.get("deviceProperties", {}).get("name", "?")
        try:
            r = devicectl("manage", "pair", "--device", ident, timeout=15)
        except subprocess.TimeoutExpired:
            print(f"[devices] re-pair deferred for {name} (device locked?) — auto-pairs on next unlock")
            continue
        if r.returncode == 0:
            print(f"[devices] re-paired {name} ({ident})")
        else:
            print(f"[devices] re-pair deferred for {name} (device locked?) — auto-pairs on next unlock")
PYEOF2
}

run_tests() {
    local suite=$1
    local explicit_modules="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"
    # UI-heavy tests that create AppKit views — skipped from unit test run
    # to avoid spawning macOS services (linkd, etc.). These test in-process
    # UI components (NSTextView, NSOutlineView, CodeEditorTextView) and
    # are not XCUITest style.
    local skip_ui_tests=(
        # No UI import files remain in unit test target — all removed.
        # If you add a test that imports SwiftUI or AppKit, add it here.
    )
    echo "Running unit tests..."
    prepare_derived_data_packages "$DERIVED_DATA_PATH_TEST"
    quarantine_paired_ios_devices
    write_test_profile_defaults "$(pwd)/.build-tests/test-profile"
    local test_rc=0
    if [ -n "$suite" ]; then
        if [ "$suite" = "json" ]; then
            suite="JSONHighlighterTests"
        fi
        echo "Filtering by suite: $suite"
        xcodebuild -quiet -project "$PROJECT_NAME.xcodeproj" \
                   -scheme "$SCHEME" \
                   -configuration Debug \
                   -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                   -destination 'platform=macOS' \
                   ENABLE_PREVIEWS=NO \
                   SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                   "${skip_ui_tests[@]}" \
                   test -only-testing:CompassTests/"$suite" -skip-testing:CompassUITests -skip-testing:CompassHarnessTests
        test_rc=$?
    else
        xcodebuild -quiet -project "$PROJECT_NAME.xcodeproj" \
                   -scheme "$SCHEME" \
                   -configuration Debug \
                   -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                   -destination 'platform=macOS' \
                   ENABLE_PREVIEWS=NO \
                   SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                   "${skip_ui_tests[@]}" \
                   test -only-testing:CompassTests -skip-testing:CompassUITests -skip-testing:CompassHarnessTests
        test_rc=$?
    fi
    restore_quarantined_ios_devices
    clear_test_profile_defaults
    return $test_rc
}

run_harness() {
    local suite=$1
    local explicit_modules="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"
    echo "Running headless harness tests..."
    prepare_derived_data_packages "$DERIVED_DATA_PATH_TEST"
    quarantine_paired_ios_devices
    local harness_rc=0
    local harness_memory_limit_gb="${HARNESS_MAX_RSS_GB:-6}"
    echo "Harness memory guard enabled: ${harness_memory_limit_gb}GB limit"
    local harness_memory_limit_mb=$((harness_memory_limit_gb * 1024))
    local local_model_memory_limit_mb="${COMPASS_LOCAL_MODEL_MAX_RSS_MB:-$((harness_memory_limit_mb - 512))}"
    echo "Local model in-process memory budget: ${local_model_memory_limit_mb}MB"
    local test_profile_dir
    test_profile_dir="${HARNESS_TEST_PROFILE_DIR:-$(pwd)/.build-tests/harness-test-profile}"
    mkdir -p "$test_profile_dir"
    write_test_profile_defaults "$test_profile_dir"
    echo "Harness test profile dir: $test_profile_dir"
    local online_harness_marker="$test_profile_dir/online-harness-enabled"
    if [[ -n "$COMPASS_RUN_ONLINE_HARNESS" ]]; then
        : > "$online_harness_marker"
    else
        rm -f "$online_harness_marker"
    fi
    # FIM benchmark knobs: app-hosted test processes cannot see env vars, so
    # forward COMPASS_FIM_* via a config file in the test profile dir.
    local fim_conf="$test_profile_dir/fim-bench.conf"
    : > "$fim_conf"
    local fim_key
    for fim_key in COMPASS_FIM_TEMPERATURE COMPASS_FIM_TOP_P COMPASS_FIM_REPETITION_PENALTY \
                   COMPASS_FIM_MAX_TOKENS COMPASS_FIM_CONTEXT_CHARS_PER_TOKEN \
                   COMPASS_FIM_MAX_SUGGESTIONS COMPASS_FIM_REPEAT_ROUNDS; do
        if [ -n "${!fim_key}" ]; then
            echo "${fim_key}=${!fim_key}" >> "$fim_conf"
        fi
    done
    # Local chat knobs: forwarded via local-bench.conf (app-hosted test
    # processes can't see the caller's env; LocalModelInferenceOverrides reads
    # both direct env and this conf file).
    local bench_conf="$test_profile_dir/local-bench.conf"
    : > "$bench_conf"
    local bench_key
    for bench_key in COMPASS_LOCAL_MODEL_TEMPERATURE COMPASS_LOCAL_MODEL_TOP_P \
                     COMPASS_LOCAL_MODEL_REPETITION_PENALTY COMPASS_LOCAL_MODEL_REPETITION_CONTEXT_SIZE \
                     COMPASS_LOCAL_MODEL_CONTEXT_LENGTH COMPASS_LOCAL_MODEL_MAX_KV_SIZE \
                     COMPASS_LOCAL_MODEL_MAX_OUTPUT_TOKENS COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE \
                     COMPASS_LOCAL_MODEL_KV_CACHE_4BIT COMPASS_LOCAL_MODEL_MLX_MEMORY_LIMIT_MB \
                     COMPASS_LOCAL_MODEL_DISABLE_PREFIX_CACHE; do
        if [ -n "${!bench_key}" ]; then
            echo "${bench_key}=${!bench_key}" >> "$bench_conf"
        fi
    done
    local prompts_root_default
    prompts_root_default="$(pwd)/Prompts"
    local resolved_prompts_root=""
    
    # Build environment variables to pass to test runner
    # Using TEST_RUNNER_ENV_ prefix to pass env vars through xcodebuild to the test process
    local env_args=()
    local runtime_env_args=("COMPASS_PROMPTS_ROOT=$resolved_prompts_root" "COMPASS_TEST_PROFILE_DIR=$test_profile_dir" "TEST_RUNNER_ENV_COMPASS_TEST_PROFILE_DIR=$test_profile_dir" "COMPASS_LOCAL_MODEL_MAX_RSS_MB=$local_model_memory_limit_mb")
    env_args+=("TEST_RUNNER_ENV_COMPASS_LOCAL_MODEL_MAX_RSS_MB=$local_model_memory_limit_mb")
    if [ -n "$COMPASS_DISABLE_HEAVY_INIT" ]; then
        env_args+=("TEST_RUNNER_ENV_COMPASS_DISABLE_HEAVY_INIT=$COMPASS_DISABLE_HEAVY_INIT")
        runtime_env_args+=("COMPASS_DISABLE_HEAVY_INIT=$COMPASS_DISABLE_HEAVY_INIT" "TEST_RUNNER_ENV_COMPASS_DISABLE_HEAVY_INIT=$COMPASS_DISABLE_HEAVY_INIT")
        echo "Heavy init disabled for test runtime"
    fi
    if [ -n "$COMPASS_ENABLE_PRODUCTION_PARITY_HARNESS" ]; then
        env_args+=("TEST_RUNNER_ENV_COMPASS_ENABLE_PRODUCTION_PARITY_HARNESS=$COMPASS_ENABLE_PRODUCTION_PARITY_HARNESS")
        echo "Production parity harness enabled"
    fi
    if [ -n "$HARNESS_MODEL_ID" ]; then
        env_args+=("TEST_RUNNER_ENV_HARNESS_MODEL_ID=$HARNESS_MODEL_ID")
        runtime_env_args+=("HARNESS_MODEL_ID=$HARNESS_MODEL_ID" "TEST_RUNNER_ENV_HARNESS_MODEL_ID=$HARNESS_MODEL_ID")
        echo "Using model: $HARNESS_MODEL_ID"
    fi
    local passthrough_test_envs=(
        "COMPASS_OFFLINE_BENCHMARK_CONTEXTS"
        "COMPASS_OFFLINE_BENCHMARK_MAX_OUTPUTS"
        "COMPASS_BACKGROUND_WORK_QUIET_MS"
        "COMPASS_BACKGROUND_WORK_CPU_LOAD_PER_CORE_THRESHOLD"
        "COMPASS_BACKGROUND_WORK_RSS_THRESHOLD_MB"
        "COMPASS_LOCAL_MODEL_TEMPERATURE"
        "COMPASS_LOCAL_MODEL_TOP_P"
        "COMPASS_LOCAL_MODEL_REPETITION_PENALTY"
        "COMPASS_LOCAL_MODEL_REPETITION_CONTEXT_SIZE"
        "COMPASS_LOCAL_MODEL_CONTEXT_LENGTH"
        "COMPASS_LOCAL_MODEL_MAX_KV_SIZE"
        "COMPASS_LOCAL_MODEL_MAX_OUTPUT_TOKENS"
        "COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE"
        "COMPASS_LOCAL_MODEL_KV_CACHE_4BIT"
        "COMPASS_LOCAL_MODEL_DISABLE_PREFIX_CACHE"
        "COMPASS_FIM_TEMPERATURE"
        "COMPASS_FIM_TOP_P"
        "COMPASS_FIM_REPETITION_PENALTY"
        "COMPASS_FIM_MAX_TOKENS"
        "COMPASS_FIM_CONTEXT_CHARS_PER_TOKEN"
        "COMPASS_FIM_MAX_SUGGESTIONS"
        "COMPASS_FIM_REPEAT_ROUNDS"
        "COMPASS_MINIMAL_TOOLSET"
        "COMPASS_DEGRADE_ON_TRANSPORT_FAILURE"
        "COMPASS_FALLBACK_MODEL_ID"
        "COMPASS_CIRCUIT_FAILURE_THRESHOLD"
        "COMPASS_CIRCUIT_COOLDOWN_SEC"
    )
    local env_name
    for env_name in "${passthrough_test_envs[@]}"; do
        if [ -n "${!env_name}" ]; then
            env_args+=("TEST_RUNNER_ENV_${env_name}=${!env_name}")
            runtime_env_args+=("${env_name}=${!env_name}" "TEST_RUNNER_ENV_${env_name}=${!env_name}")
        fi
    done
    env_args+=("TEST_RUNNER_ENV_COMPASS_TEST_PROFILE_DIR=$test_profile_dir")
    if [[ -n "$COMPASS_RUN_ONLINE_HARNESS" ]]; then
        env_args+=("TEST_RUNNER_ENV_COMPASS_RUN_ONLINE_HARNESS=$COMPASS_RUN_ONLINE_HARNESS")
        runtime_env_args+=("COMPASS_RUN_ONLINE_HARNESS=$COMPASS_RUN_ONLINE_HARNESS")
        echo "Online harness runtime enabled"
    fi
    if [ -n "$COMPASS_PROMPTS_ROOT" ]; then
        env_args+=("TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT=$COMPASS_PROMPTS_ROOT")
        resolved_prompts_root="$COMPASS_PROMPTS_ROOT"
        echo "Using prompt root from COMPASS_PROMPTS_ROOT: $COMPASS_PROMPTS_ROOT"
    elif [ -d "$prompts_root_default" ]; then
        env_args+=("TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT=$prompts_root_default")
        resolved_prompts_root="$prompts_root_default"
        echo "Using prompt root: $prompts_root_default"
    fi
    
    if [ -n "$suite" ]; then
        echo "Filtering by suite: $suite"
        # Do not change this to YES for online/provider-backed harnesses.
        # Parallel test execution floods the provider, triggers 429s, and risks account bans.
        run_with_memory_guard "$harness_memory_limit_gb" \
            env "${runtime_env_args[@]}" xcodebuild -project "$PROJECT_NAME.xcodeproj" \
                  -scheme "$SCHEME" \
                  -configuration Debug \
                  -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                  -destination 'platform=macOS' \
                  -parallel-testing-enabled NO \
                  ENABLE_PREVIEWS=NO \
                  SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                  "${env_args[@]}" \
                  test -only-testing:CompassHarnessTests/"$suite" -skip-testing:CompassUITests -skip-testing:CompassTests
        harness_rc=$?
    else
        local skip_online_args=()
        if [ -z "$COMPASS_RUN_ONLINE_HARNESS" ]; then
            skip_online_args+=("-skip-testing:CompassHarnessTests/PureAgenticHarnessTests")
            skip_online_args+=("-skip-testing:CompassHarnessTests/RAGPreventionHarnessTests")
            skip_online_args+=("-skip-testing:CompassHarnessTests/WebSearchHarnessTests")
            skip_online_args+=("-skip-testing:CompassHarnessTests/WordPressReviewReproductionTests")
            skip_online_args+=("-skip-testing:CompassHarnessTests/EmbeddingBenchmarkHarnessTests")
        fi
        # Do not change this to YES for online/provider-backed harnesses.
        # Parallel test execution floods the provider, triggers 429s, and risks account bans.
        run_with_memory_guard "$harness_memory_limit_gb" \
            env "${runtime_env_args[@]}" xcodebuild -project "$PROJECT_NAME.xcodeproj" \
                  -scheme "$SCHEME" \
                  -configuration Debug \
                  -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                  -destination 'platform=macOS' \
                  -parallel-testing-enabled NO \
                  ENABLE_PREVIEWS=NO \
                  SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                  "${env_args[@]}" \
                  "${skip_online_args[@]}" \
                  test \
                  -only-testing:CompassHarnessTests \
                  -skip-testing:CompassUITests \
                  -skip-testing:CompassTests
        harness_rc=$?
    fi
    restore_quarantined_ios_devices
    clear_test_profile_defaults
    return $harness_rc
}

run_harness_online() {
    local suite=$1
    if [ -n "$suite" ]; then
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "$suite"
    else
        echo "Running online harness suites..."
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "PureAgenticHarnessTests"
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "RAGPreventionHarnessTests"
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "WebSearchHarnessTests"
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "WordPressReviewReproductionTests"
        COMPASS_RUN_ONLINE_HARNESS=1 run_harness "EmbeddingBenchmarkHarnessTests"
    fi
}

run_harness_offline() {
    local suite=$1
    if [ -n "$suite" ]; then
        run_harness "$suite"
    else
        echo "Running offline harness suites..."
        run_harness "StripMarkupTest"
        run_harness "LocalMultiTurnHarnessTests"
        run_harness "LocalToolExecutionTests"
        run_harness "LocalPrefixCacheTests"
        run_harness "LocalChatTwoTurnReproTests"
    fi
}

run_benchmark() {
    local explicit_modules="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"
    echo "Running benchmark suites (EmbeddingBenchmarkHarnessTests + BenchmarkMetricsTests)..."
    prepare_derived_data_packages "$DERIVED_DATA_PATH_TEST"
    quarantine_paired_ios_devices
    local bench_rc=0
    xcodebuild -quiet -project "$PROJECT_NAME.xcodeproj" \
               -scheme "$SCHEME" \
               -configuration Debug \
               -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
               -destination 'platform=macOS' \
               -parallel-testing-enabled NO \
               ENABLE_PREVIEWS=NO \
               SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
               test \
               -only-testing:CompassHarnessTests/EmbeddingBenchmarkHarnessTests \
               -only-testing:CompassHarnessTests/BenchmarkMetricsTests \
               -skip-testing:CompassUITests \
               -skip-testing:CompassTests
    bench_rc=$?
    restore_quarantined_ios_devices
    echo "[BENCH] JSON results: .build-tests/benchmarks/latest.json"
    return $bench_rc
}

run_benchmark_local() {
    local explicit_modules="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"
    echo "Running local chat benchmark (LocalBenchmarkHarnessTests)..."
    prepare_derived_data_packages "$DERIVED_DATA_PATH_TEST"
    quarantine_paired_ios_devices
    local harness_memory_limit_gb="${HARNESS_MAX_RSS_GB:-10}"
    echo "Harness memory guard enabled: ${harness_memory_limit_gb}GB limit"
    local harness_memory_limit_mb=$((harness_memory_limit_gb * 1024))
    local local_model_memory_limit_mb="${COMPASS_LOCAL_MODEL_MAX_RSS_MB:-$((harness_memory_limit_mb - 512))}"
    local test_profile_dir
    test_profile_dir="${HARNESS_TEST_PROFILE_DIR:-$(pwd)/.build-tests/harness-test-profile}"
    mkdir -p "$test_profile_dir"
    write_test_profile_defaults "$test_profile_dir"
    # Local-chat benchmark knobs: app-hosted test processes cannot see env
    # vars, so forward COMPASS_LOCAL_MODEL_* via a conf file in the test
    # profile dir (read by LocalModelInferenceOverrides).
    local bench_conf="$test_profile_dir/local-bench.conf"
    : > "$bench_conf"
    local bench_key
    for bench_key in COMPASS_LOCAL_MODEL_TEMPERATURE COMPASS_LOCAL_MODEL_TOP_P \
                     COMPASS_LOCAL_MODEL_REPETITION_PENALTY COMPASS_LOCAL_MODEL_REPETITION_CONTEXT_SIZE \
                     COMPASS_LOCAL_MODEL_CONTEXT_LENGTH COMPASS_LOCAL_MODEL_MAX_KV_SIZE \
                     COMPASS_LOCAL_MODEL_MAX_OUTPUT_TOKENS COMPASS_LOCAL_MODEL_PREFILL_STEP_SIZE \
                     COMPASS_LOCAL_MODEL_KV_CACHE_4BIT COMPASS_LOCAL_MODEL_MLX_MEMORY_LIMIT_MB \
                     COMPASS_LOCAL_MODEL_DISABLE_PREFIX_CACHE; do
        if [ -n "${!bench_key}" ]; then
            echo "${bench_key}=${!bench_key}" >> "$bench_conf"
        fi
    done
    local prompts_root_default
    prompts_root_default="$(pwd)/Prompts"
    local runtime_env_args=("COMPASS_PROMPTS_ROOT=$prompts_root_default" "COMPASS_TEST_PROFILE_DIR=$test_profile_dir" "TEST_RUNNER_ENV_COMPASS_TEST_PROFILE_DIR=$test_profile_dir" "COMPASS_LOCAL_MODEL_MAX_RSS_MB=$local_model_memory_limit_mb")
    if [ -n "$LOCAL_BENCH_TASKS" ]; then
        echo "LOCAL_BENCH_TASKS=$LOCAL_BENCH_TASKS" >> "$bench_conf"
    fi
    if [ -n "$LOCAL_BENCH_ITERATIONS" ]; then
        echo "LOCAL_BENCH_ITERATIONS=$LOCAL_BENCH_ITERATIONS" >> "$bench_conf"
    fi
    local bench_rc=0
    run_with_memory_guard "$harness_memory_limit_gb" \
        env "${runtime_env_args[@]}" xcodebuild -project "$PROJECT_NAME.xcodeproj" \
              -scheme "$SCHEME" \
              -configuration Debug \
              -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
              -destination 'platform=macOS' \
              -parallel-testing-enabled NO \
              ENABLE_PREVIEWS=NO \
              SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
              test \
              -only-testing:CompassHarnessTests/LocalBenchmarkHarnessTests \
              -skip-testing:CompassUITests \
              -skip-testing:CompassTests
    bench_rc=$?
    restore_quarantined_ios_devices
    echo "[LOCAL-BENCH] rows: <project>/.ide/logs/local-bench.ndjson"
    return $bench_rc
}

run_e2e() {
    local suite=$1
    local explicit_modules="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"
    echo "Running UI tests..."
    prepare_derived_data_packages "$DERIVED_DATA_PATH_TEST"
    quarantine_paired_ios_devices
    local e2e_rc=0
    if [ -n "$suite" ]; then
        if [ "$suite" = "json" ]; then
            suite="JSONHighlighterUITests"
        fi
        echo "Filtering by suite: $suite"
        xcodebuild -project "$PROJECT_NAME.xcodeproj" \
                   -scheme "$SCHEME" \
                   -configuration Debug \
                   -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                   -destination 'platform=macOS' \
                   ENABLE_PREVIEWS=NO \
                   SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                   test -only-testing:CompassUITests/"$suite" -skip-testing:CompassTests
        e2e_rc=$?
    else
        xcodebuild -project "$PROJECT_NAME.xcodeproj" \
                   -scheme "$SCHEME" \
                   -configuration Debug \
                   -derivedDataPath "$DERIVED_DATA_PATH_TEST" \
                   -destination 'platform=macOS' \
                   ENABLE_PREVIEWS=NO \
                   SWIFT_ENABLE_EXPLICIT_MODULES="$explicit_modules" \
                   test -only-testing:CompassUITests -skip-testing:CompassTests
        e2e_rc=$?
    fi
    restore_quarantined_ios_devices
    return $e2e_rc
}

clean() {
    echo "Cleaning build artifacts..."
    rm -rf "$DERIVED_DATA_PATH_APP" "$DERIVED_DATA_PATH_TEST"
    xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME" clean
}

COMMAND=$1

run_lint() {
    # Local static analysis (replaces hosted Codacy/Sonar for Swift):
    # runs the repo's own .swiftlint.yml, including DESIGN_STANDARDS guardrails
    # that hosted tools never apply. Advisory today — the codebase carries
    # ~150 pre-existing errors; gate the build once the debt is burned down.
    if ! command -v swiftlint >/dev/null 2>&1; then
        echo "[lint] swiftlint not found — install with: brew install swiftlint"
        return 1
    fi
    swiftlint lint
}

check_prompts() {
    # Guardrail: every prompt file under Prompts/ must be referenced by code.
    # Orphan prompts are direction-change debris — fix prompts rot silently.
    local orphan_count=0
    local checked_count=0
    while IFS= read -r file; do
        checked_count=$((checked_count + 1))
        local key="${file#Prompts/}"
        key="${key%.md}"
        if ! rg -q --fixed-strings --glob '*.swift' "$key" Compass; then
            echo "[check-prompts] ORPHAN: $key (no code reference)"
            orphan_count=$((orphan_count + 1))
        fi
    done < <(find Prompts -name '*.md' | sort)
    echo "[check-prompts] checked $checked_count prompt files, $orphan_count orphan(s)"
    [ "$orphan_count" -eq 0 ]
}

case "$COMMAND" in
    app)
        build_app
        if [ $? -eq 0 ]; then
            launch_app
        fi
        ;;
    build)
        build_app
        ;;
    test)
        run_tests "$2"
        ;;
    harness)
        run_harness "$2"
        ;;
    harness-online)
        run_harness_online "$2"
        ;;
    harness-offline)
        run_harness_offline "$2"
        ;;
    benchmark-offline)
        run_benchmark_offline "$2"
        ;;
    benchmark-local)
        run_benchmark_local
        ;;
    check-prompts)
        check_prompts
        ;;
    lint)
        run_lint
        ;;
    benchmark)
        run_benchmark
        ;;
    e2e)
        run_e2e "$2"
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        if [ -z "$COMMAND" ]; then
            show_help
        else
            echo "Unknown command: $COMMAND"
            show_help
            exit 1
        fi
        ;;
esac
