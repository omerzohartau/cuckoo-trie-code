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
RESULTS_DIR="$SCRIPT_DIR/benchmark_results"
DATASET_DIR="/specific/disk1/home/datasets"
DEFAULT_DATASET="$DATASET_DIR/rand_8_200m_escaped.bin"

RUNS=5
THREAD_COUNTS="1 2 4 8 12 16 24"
TIMESERIES_THREADS=4
# Small initial table: 1M cells -> ~8 doublings across 200M keys
SMALL_INITIAL_CELLS=1000000

if [[ "$1" == "--fast" ]]; then
    RUNS=2
    DATASET="rand-8"
    THREAD_COUNTS="1 4 8 16"
    echo "[fast mode] synthetic rand-8 dataset, $RUNS runs per config."
elif [[ ! -f "$DEFAULT_DATASET" ]]; then
    echo "WARNING: $DEFAULT_DATASET not found; using rand-8 (10M synthetic keys)."
    DATASET="rand-8"
else
    DATASET="$DEFAULT_DATASET"
fi

mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/run.log"
echo "Benchmark run started: $(date)" | tee "$LOG"
echo "Dataset: $DATASET" | tee -a "$LOG"
echo "" | tee -a "$LOG"

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

echo "--- Building benchmark_base (CT_ENABLE_GROWING=0) ---" | tee -a "$LOG"
(
  cd "$SCRIPT_DIR"
  cp config.h config.h.bak
  sed 's/#define CT_ENABLE_GROWING 1/#define CT_ENABLE_GROWING 0/' config.h.bak > config.h
  # shellcheck disable=SC2086
  $CC $FLAGS -o benchmark_base $ALL_SOURCES $LIBS 2>&1 | tee -a "$LOG"
  cp config.h.bak config.h
  rm config.h.bak
)

echo "--- Building benchmark_modified (CT_ENABLE_GROWING=1) ---" | tee -a "$LOG"
(
  cd "$SCRIPT_DIR"
  # shellcheck disable=SC2086
  $CC $FLAGS -o benchmark_modified $ALL_SOURCES $LIBS 2>&1 | tee -a "$LOG"
)

BASE="$SCRIPT_DIR/benchmark_base"
MODIFIED="$SCRIPT_DIR/benchmark_modified"
echo "Build done." | tee -a "$LOG"
echo "" | tee -a "$LOG"

# --------------------------------------------------------------------------
# Helper: run one benchmark, append matching lines to a result file
# run_bench LABEL RESULT_FILE BINARY [ARGS...]
# --------------------------------------------------------------------------
run_bench() {
    local label="$1"; shift
    local result_file="$1"; shift
    local binary="$1"; shift
    echo "" | tee -a "$LOG"
    echo ">> $label" | tee -a "$LOG"
    "$binary" "$@" 2>&1 | tee -a "$LOG" | grep "^RESULT:" >> "$result_file" || true
}

# --------------------------------------------------------------------------
# Benchmark 1: Insert throughput vs thread count
#
# Three configurations per thread count:
#   base          -- original code, no resize mechanics, auto-sized table
#   mod-no-resize -- modified code, auto-sized table (no resize fires)
#   mod-resize    -- modified code, small initial table (multiple resizes)
# --------------------------------------------------------------------------
THRU_FILE="$RESULTS_DIR/throughput_vs_threads.txt"
echo "=== BENCHMARK 1: Insert throughput vs thread count ===" | tee -a "$THRU_FILE" "$LOG"
echo "# label threads ops ms" >> "$THRU_FILE"

for t in $THREAD_COUNTS; do
    for run in $(seq 1 $RUNS); do
        echo "# base  t=$t run=$run" >> "$THRU_FILE"
        run_bench "base t=$t run=$run" "$THRU_FILE" \
            "$BASE" mt-insert --threads "$t" "$DATASET"

        echo "# mod-no-resize t=$t run=$run" >> "$THRU_FILE"
        run_bench "mod-no-resize t=$t run=$run" "$THRU_FILE" \
            "$MODIFIED" mt-insert --threads "$t" "$DATASET"

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
# (mw-insert-pos-lookup: insert threads + concurrent lookup threads)
# --------------------------------------------------------------------------
LOOKUP_FILE="$RESULTS_DIR/lookup_during_resize.txt"
echo "=== BENCHMARK 2: Lookup throughput during concurrent resize ===" \
    | tee -a "$LOOKUP_FILE" "$LOG"
echo "# label insert_threads lookup_threads ops ms" >> "$LOOKUP_FILE"

LOOKUP_THREAD_COUNTS="2 4 8 16"
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
# (modified binary only; TIMESERIES_SAMPLE / RESIZE_START / RESIZE_END lines)
# --------------------------------------------------------------------------
TS_FILE="$RESULTS_DIR/timeseries.txt"
echo "=== BENCHMARK 3: Insert throughput over time ===" | tee -a "$TS_FILE" "$LOG"

for run in $(seq 1 $RUNS); do
    echo "# run=$run threads=$TIMESERIES_THREADS" | tee -a "$TS_FILE"
    echo "" | tee -a "$LOG"
    echo ">> timeseries run=$run t=$TIMESERIES_THREADS" | tee -a "$LOG"
    "$MODIFIED" mt-insert-timeseries \
        --threads "$TIMESERIES_THREADS" \
        --trie-cells "$SMALL_INITIAL_CELLS" "$DATASET" \
        2>&1 | tee -a "$LOG" \
        | grep -E "^(TIMESERIES_SAMPLE|RESIZE_START|RESIZE_END|RESULT):" >> "$TS_FILE" || true
done
echo "" | tee -a "$LOG"
echo "Benchmark 3 complete." | tee -a "$LOG"

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== All benchmarks complete ===" | tee -a "$LOG"
echo "Results:" | tee -a "$LOG"
echo "  $THRU_FILE" | tee -a "$LOG"
echo "  $LOOKUP_FILE" | tee -a "$LOG"
echo "  $TS_FILE" | tee -a "$LOG"
echo "  $LOG" | tee -a "$LOG"
echo "Finished: $(date)" | tee -a "$LOG"
