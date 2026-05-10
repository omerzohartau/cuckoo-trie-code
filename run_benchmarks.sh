#!/bin/bash
# CT-Resize Project Benchmark Script
#
# Evaluates growt-style concurrent resize versus original (no-resize) Cuckoo Trie.
# Produces three result files:
#   throughput_vs_threads.txt  -- insert throughput vs thread count
#   lookup_during_resize.txt   -- lookup throughput during concurrent resize
#   timeseries.txt             -- insert throughput over time with resize events marked
#
# Usage:
#   ./run_benchmarks.sh           # full run (~hours)
#   ./run_benchmarks.sh --fast    # quick smoke test (rand-8, 2 runs)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_RESULTS_DIR="$SCRIPT_DIR/benchmark_results"
DATASET_DIR="/specific/disk1/home/datasets"

# Maximum seconds per individual benchmark invocation (100 min).
BENCH_TIMEOUT=6000

RUNS=3
THREAD_COUNTS="4 8 12 16 24"
TIMESERIES_THREADS=4
# Small initial table: 1M cells -> multiple doublings across 200M keys
SMALL_INITIAL_CELLS=1000000

if [[ "$1" == "--fast" ]]; then
    RUNS=2
    THREAD_COUNTS="1 4 8 16"
    DATASETS="rand-8"
    echo "[fast mode] synthetic rand-8 dataset, $RUNS runs per config."
elif [[ ! -d "$DATASET_DIR" ]]; then
    echo "WARNING: $DATASET_DIR not found; using rand-8 (10M synthetic keys)."
    DATASETS="rand-8"
else
    DATASETS="$DATASET_DIR/rand_8_200m_escaped.bin
$DATASET_DIR/rand_16_200m_escaped.bin
$DATASET_DIR/az_all_2014_shuf_uniq.bin
$DATASET_DIR/reddit_201809_shuf_uniq.bin
$DATASET_DIR/sosd_osm64_shuf_uniq_escaped.bin"
fi

mkdir -p "$BASE_RESULTS_DIR"
MASTER_LOG="$BASE_RESULTS_DIR/run.log"
echo "Benchmark run started: $(date)" | tee "$MASTER_LOG"
echo "" | tee -a "$MASTER_LOG"

# --------------------------------------------------------------------------
# Build two self-contained benchmark binaries.
# Compiling everything into a single binary avoids shared-library mismatch
# when config.h (CT_ENABLE_GROWING) differs between base and modified builds.
# --------------------------------------------------------------------------
ALL_SOURCES="main.c util.c verify_trie.c random.c atomics.c mt_debug.c
             benchmark.c dataset.c random_dist.c"
CC="${CC:-gcc}"
FLAGS="-march=haswell -Wreturn-type -Wuninitialized -Wunused-parameter \
       -O3 -fvisibility=hidden -fno-strict-aliasing -DNDEBUG"
LIBS="-lpthread -lm"

echo "--- Building benchmark_base (CT_ENABLE_GROWING=0) ---" | tee -a "$MASTER_LOG"
(
    set -e -o pipefail
    cd "$SCRIPT_DIR"
    cp config.h config.h.bak
    trap 'cp config.h.bak config.h 2>/dev/null; rm -f config.h.bak config.h.tmp' EXIT
    sed 's/#define CT_ENABLE_GROWING 1/#define CT_ENABLE_GROWING 0/' config.h.bak \
        > config.h.tmp && mv config.h.tmp config.h
    # shellcheck disable=SC2086
    $CC $FLAGS -o benchmark_base $ALL_SOURCES $LIBS 2>&1 | tee -a "$MASTER_LOG"
)
BASE="$SCRIPT_DIR/benchmark_base"
if [[ ! -x "$BASE" ]]; then
    echo "ERROR: benchmark_base build FAILED. Check $MASTER_LOG. Aborting." | tee -a "$MASTER_LOG"
    exit 1
fi

echo "--- Building benchmark_modified (CT_ENABLE_GROWING=1) ---" | tee -a "$MASTER_LOG"
(
    set -e -o pipefail
    cd "$SCRIPT_DIR"
    # shellcheck disable=SC2086
    $CC $FLAGS -o benchmark_modified $ALL_SOURCES $LIBS 2>&1 | tee -a "$MASTER_LOG"
)
MODIFIED="$SCRIPT_DIR/benchmark_modified"
if [[ ! -x "$MODIFIED" ]]; then
    echo "ERROR: benchmark_modified build FAILED. Check $MASTER_LOG. Aborting." | tee -a "$MASTER_LOG"
    exit 1
fi

echo "Build done." | tee -a "$MASTER_LOG"
echo "" | tee -a "$MASTER_LOG"

# --------------------------------------------------------------------------
# Helper: run one benchmark with a hard timeout.
#
# run_bench LABEL RESULT_FILE BINARY [ARGS...]
#
# Captures output to a temp file first so grep doesn't affect the exit code.
# Warns if the benchmark timed out or exited non-zero; never aborts the script.
# --------------------------------------------------------------------------
run_bench() {
    local label="$1"; shift
    local result_file="$1"; shift
    local binary="$1"; shift
    local tmpout ec
    tmpout=$(mktemp)

    echo "" | tee -a "$LOG"
    echo ">> $label" | tee -a "$LOG"

    set +e
    timeout "$BENCH_TIMEOUT" "$binary" "$@" > "$tmpout" 2>&1
    ec=$?
    set -e

    cat "$tmpout" >> "$LOG"
    grep "^RESULT:" "$tmpout" >> "$result_file" || true
    rm -f "$tmpout"

    if [[ $ec -eq 124 ]]; then
        echo "WARNING: $label timed out after ${BENCH_TIMEOUT}s — no RESULT recorded" \
            | tee -a "$LOG"
    elif [[ $ec -ne 0 ]]; then
        echo "WARNING: $label exited with code $ec (crashed or overflow)" | tee -a "$LOG"
    fi
}

# --------------------------------------------------------------------------
# Loop over every dataset
# --------------------------------------------------------------------------
while IFS= read -r DATASET; do
    [[ -z "$DATASET" ]] && continue

    # Derive a short name for directory/log labelling.
    DS_NAME="$(basename "$DATASET" .bin)"
    DS_NAME="${DS_NAME:-synthetic}"

    RESULTS_DIR="$BASE_RESULTS_DIR/$DS_NAME"
    mkdir -p "$RESULTS_DIR"
    LOG="$RESULTS_DIR/run.log"

    echo "========================================" | tee -a "$MASTER_LOG"
    echo "Dataset: $DATASET" | tee -a "$MASTER_LOG"
    echo "Results dir: $RESULTS_DIR" | tee -a "$MASTER_LOG"
    echo "Started: $(date)" | tee -a "$MASTER_LOG"
    echo "========================================" | tee -a "$MASTER_LOG"

    echo "Dataset: $DATASET" > "$LOG"
    echo "Started: $(date)" >> "$LOG"
    echo "" >> "$LOG"

    # Reset result files so re-runs don't accumulate stale data.
    : > "$RESULTS_DIR/throughput_vs_threads.txt"
    : > "$RESULTS_DIR/lookup_during_resize.txt"
    : > "$RESULTS_DIR/timeseries.txt"

    # --------------------------------------------------------------------------
    # Benchmark 1: Insert throughput vs thread count
    # --------------------------------------------------------------------------
    THRU_FILE="$RESULTS_DIR/throughput_vs_threads.txt"
    echo "=== BENCHMARK 1: Insert throughput vs thread count ===" | tee -a "$THRU_FILE" "$LOG"
    echo "# label threads ops ms" >> "$THRU_FILE"

    for t in $THREAD_COUNTS; do
        for run in $(seq 1 $RUNS); do
            echo "# base  t=$t run=$run" >> "$THRU_FILE"
            run_bench "base t=$t run=$run" "$THRU_FILE" \
                "$BASE" mt-insert --threads "$t" "$DATASET"

            echo "# mod-resize t=$t run=$run" >> "$THRU_FILE"
            run_bench "mod-resize t=$t run=$run" "$THRU_FILE" \
                "$MODIFIED" mt-insert --threads "$t" \
                --trie-cells "$SMALL_INITIAL_CELLS" "$DATASET"
        done
    done
    echo "" | tee -a "$LOG"
    echo "Benchmark 1 complete." | tee -a "$LOG"

    # --------------------------------------------------------------------------
    # Benchmark 2: Lookup throughput during concurrent resize
    # --------------------------------------------------------------------------
    LOOKUP_FILE="$RESULTS_DIR/lookup_during_resize.txt"
    echo "=== BENCHMARK 2: Lookup throughput during concurrent resize ===" \
        | tee -a "$LOOKUP_FILE" "$LOG"
    echo "# label insert_threads lookup_threads ops ms" >> "$LOOKUP_FILE"

    LOOKUP_THREAD_COUNTS="4 8 16"
    for t in $LOOKUP_THREAD_COUNTS; do
        for run in $(seq 1 $RUNS); do
            echo "# base-lookup t=$t run=$run" >> "$LOOKUP_FILE"
            run_bench "base-lookup t=$t run=$run" "$LOOKUP_FILE" \
                "$BASE" mw-insert-pos-lookup \
                --insert-threads "$t" --lookup-threads "$t" "$DATASET"

            echo "# mod-lookup-resize t=$t run=$run" >> "$LOOKUP_FILE"
            run_bench "mod-lookup-resize t=$t run=$run" "$LOOKUP_FILE" \
                "$MODIFIED" mw-insert-pos-lookup \
                --insert-threads "$t" --lookup-threads "$t" \
                --trie-cells "$SMALL_INITIAL_CELLS" "$DATASET"
        done
    done
    echo "" | tee -a "$LOG"
    echo "Benchmark 2 complete." | tee -a "$LOG"

    # --------------------------------------------------------------------------
    # Benchmark 3: Insert throughput over time with resize events marked
    # --------------------------------------------------------------------------
    TS_FILE="$RESULTS_DIR/timeseries.txt"
    echo "=== BENCHMARK 3: Insert throughput over time ===" | tee -a "$TS_FILE" "$LOG"

    for run in $(seq 1 $RUNS); do
        echo "# run=$run threads=$TIMESERIES_THREADS" | tee -a "$TS_FILE"
        echo "" | tee -a "$LOG"
        echo ">> timeseries run=$run t=$TIMESERIES_THREADS" | tee -a "$LOG"
        local_tmp=$(mktemp)
        set +e
        timeout "$BENCH_TIMEOUT" "$MODIFIED" mt-insert-timeseries \
            --threads "$TIMESERIES_THREADS" \
            --trie-cells "$SMALL_INITIAL_CELLS" "$DATASET" \
            > "$local_tmp" 2>&1
        ec=$?
        set -e
        cat "$local_tmp" >> "$LOG"
        grep -E "^(TIMESERIES_SAMPLE|RESIZE_START|RESIZE_END|RESULT):" "$local_tmp" \
            >> "$TS_FILE" || true
        rm -f "$local_tmp"
        if [[ $ec -eq 124 ]]; then
            echo "WARNING: timeseries run=$run timed out after ${BENCH_TIMEOUT}s" \
                | tee -a "$LOG"
        elif [[ $ec -ne 0 ]]; then
            echo "WARNING: timeseries run=$run exited with code $ec" | tee -a "$LOG"
        fi
    done
    echo "" | tee -a "$LOG"
    echo "Benchmark 3 complete." | tee -a "$LOG"

    echo "Dataset $DS_NAME finished: $(date)" | tee -a "$MASTER_LOG" "$LOG"
    echo "" | tee -a "$MASTER_LOG"

done <<< "$DATASETS"

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
echo "" | tee -a "$MASTER_LOG"
echo "=== All benchmarks complete ===" | tee -a "$MASTER_LOG"
echo "Results under: $BASE_RESULTS_DIR/" | tee -a "$MASTER_LOG"
echo "Finished: $(date)" | tee -a "$MASTER_LOG"
