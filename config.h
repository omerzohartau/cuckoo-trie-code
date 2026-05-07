#define CUCKOO_BUCKET_SIZE 4
#define BITS_PER_SYMBOL 5
#define MAX_JUMP_SYMBOLS 8
#define TAG_BITS 4
#define MULTITHREADING

// --- Dynamic resize configuration ---

// Enable dynamic growth (only used when MULTITHREADING is defined)
#define CT_ENABLE_GROWING 1

// Factor by which to grow the number of cells when the table is full
#define CT_GROWTH_FACTOR 2

// Start growing when the entry count exceeds this percentage of raw cell capacity.
// Must be in [1, 100]. Lower values leave more headroom for phase-1 inserts to
// succeed on the old table without blocking; 90 is a reasonable default.
#define CT_GROW_THRESHOLD 90
