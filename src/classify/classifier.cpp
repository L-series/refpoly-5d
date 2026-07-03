/**
 * classifier.cpp — Main polytope classification engine
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Reads CWS from Parquet files, computes polytope normal forms via PALP,
 * deduplicates using xxHash128 + hash map, and writes unique polytopes
 * with frequency counts to an output database.
 *
 * Architecture:
 *   ┌──────────┐    ┌──────────────┐    ┌─────────────┐    ┌──────────┐
 *   │ Parquet  │───>│ Thread Pool  │───>│  Hash Map   │───>│  Output  │
 *   │  Reader  │    │ (PALP NF)    │    │  (dedup)    │    │ Parquet  │
 *   └──────────┘    └──────────────┘    └─────────────┘    └──────────┘
 *
 * Build: see CMakeLists.txt
 * Usage: ./classifier --input <dir> --output <dir> [--threads N]
 * ═══════════════════════════════════════════════════════════════════════════
 */

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdlib>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <numeric>
#include <queue>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <unistd.h>  /* sysconf, _SC_PAGESIZE */

#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <arrow/io/api.h>
#include <parquet/arrow/reader.h>
#include <parquet/arrow/writer.h>
#include <parquet/properties.h>

/* ── xxHash — bundled single-header implementation ───────────────────────── */
#define XXH_INLINE_ALL
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"

/* ── PALP C API ──────────────────────────────────────────────────────────── */
#include "palp_api.h"
#include "geometry_backend.h"

namespace fs = std::filesystem;

/* ═══════════════════════════════════════════════════════════════════════════
 *  SLURM GPU helper
 * ═══════════════════════════════════════════════════════════════════════════ */

// Return the CUDA device index allocated to this process by SLURM.
// When SLURM sets CUDA_VISIBLE_DEVICES the runtime remaps the physical
// GPU(s) to indices 0, 1, ..., so device 0 is always the right choice.
// When only SLURM_JOB_GPUS is present (no CUDA_VISIBLE_DEVICES remapping),
// use the first physical ordinal listed there.
static int slurm_default_cuda_device() {
    if (const char *cvd = std::getenv("CUDA_VISIBLE_DEVICES"))
        if (cvd[0] != '\0' && std::string(cvd) != "NoDevFiles")
            return 0;
    if (const char *sjg = std::getenv("SLURM_JOB_GPUS"))
        if (sjg[0] != '\0')
            try { return std::stoi(std::string(sjg)); } catch (...) {}
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Configuration
 * ═══════════════════════════════════════════════════════════════════════════ */

struct Config {
    std::string input_dir;
    std::string output_dir;
    std::string checkpoint_dir;
    int         n_threads       = 0;   /* 0 = hardware_concurrency */
    int64_t     batch_size      = 8192;
    int64_t     checkpoint_rows = 50'000'000;  /* rows between checkpoints  */
    int         start_file      = -1;  /* -1 = all files            */
    int         end_file        = -1;
    int         name_offset     = -1;  /* global index offset for checkpoint naming */
    bool        resume          = false;
    bool        assume_sorted   = false;  /* skip Phase 1, treat all shards as sorted */
    bool        non_reflexive   = false;  /* input is non-reflexive IP WS: omit the
                                             reflexive-only Hodge/dual output columns */
    bool        benchmark_only  = false;
    int64_t     benchmark_rows  = 0;   /* 0 = all rows in first file */
    int64_t     max_rows_per_file = 0; /* 0 = unlimited               */
    /* Spill-run mode: instead of accumulating one ever-growing global map
       (infeasible at full non-reflexive scale — ~20B uniques), process each
       file (or a small batch), write an independent SORTED run to disk, and
       RESET the map.  All cross-file/cross-node dedup is deferred to --merge.
       Keeps peak RAM ≈ one run's uniques and removes the global-map bottleneck. */
    bool        spill_runs      = false;
    std::string runs_dir;              /* where sorted runs are written (default: checkpoint_dir) */
    int         files_per_run   = 1;   /* files accumulated per spilled run */
    std::string run_tag         = "run"; /* filename prefix for run files */
    GeometryBackendKind backend_kind = GeometryBackendKind::Cpu;
    int         cuda_device     = slurm_default_cuda_device();
};

/* ═══════════════════════════════════════════════════════════════════════════
 *  Hash map key: 128-bit xxHash of the normal form
 * ═══════════════════════════════════════════════════════════════════════════ */

struct Hash128 {
    uint64_t lo, hi;

    bool operator==(const Hash128 &o) const {
        return lo == o.lo && hi == o.hi;
    }
};

struct Hash128Hasher {
    size_t operator()(const Hash128 &h) const {
        /* Use the low 64 bits as the bucket hash.  xxHash128 is already
           well-distributed so no further mixing is needed. */
        return static_cast<size_t>(h.lo);
    }
};

/* ═══════════════════════════════════════════════════════════════════════════
 *  Value stored for each unique polytope in the hash map
 * ═══════════════════════════════════════════════════════════════════════════ */

/* Slim per-polytope record.  The ws-5d dataset is always a SINGLE weight
   system (1x6 weights, degree = sum), so the general combined-CWS grid
   (nw/N/structure_id/profile_id and the [5][10] weight matrix) is dropped —
   it was ~85% zero padding.  Only the six representative weights are kept.
   The reflexive-only fields (dual_point_count, h11/h12/h13) remain so the
   classifier still supports reflexive input; they are 0 and omitted from the
   output under --non-reflexive. */
struct PolytopeInfo {
    uint64_t count;               /* how many CWS generate this polytope    */
    int64_t  source_index;        /* row index/provenance of representative */
    int32_t  weights[6];          /* the single weight system [w0..w5]      */
    int16_t  vertex_count;
    int16_t  facet_count;
    int32_t  point_count;
    int32_t  dual_point_count;    /* reflexive-only (0 for non-reflexive)   */
    int16_t  h11, h12, h13;       /* reflexive-only (0 for non-reflexive)   */
};

using PolytopeMap = std::unordered_map<Hash128, PolytopeInfo, Hash128Hasher>;

/* ═══════════════════════════════════════════════════════════════════════════
 *  Flat record for sort-merge operations (matches checkpoint on-disk layout)
 * ═══════════════════════════════════════════════════════════════════════════ */

struct MergeRecord {
    Hash128      key;
    PolytopeInfo info;
};
/* Hash128 ends at offset 16 (8-aligned), PolytopeInfo starts with uint64_t
   (needs 8-alignment), so there is no inter-member padding.  Verify: */
static_assert(sizeof(MergeRecord) == sizeof(Hash128) + sizeof(PolytopeInfo),
              "MergeRecord must have no padding (matches checkpoint I/O format)");

static constexpr int32_t CLASSIFIER_SCHEMA_LEGACY = 1;
static constexpr int32_t CLASSIFIER_SCHEMA_COMBINED = 2;
static constexpr uint64_t CHECKPOINT_MAGIC = 0x4357533544434b50ULL; /* PKC5DSWC */
static constexpr uint32_t CHECKPOINT_VERSION = 2;

struct CheckpointHeader {
    uint64_t magic;
    uint32_t version;
    uint32_t record_size;
    uint64_t count;
};

static void write_checkpoint_header(std::ofstream &f, uint64_t count) {
    CheckpointHeader header{CHECKPOINT_MAGIC, CHECKPOINT_VERSION,
                            static_cast<uint32_t>(sizeof(MergeRecord)), count};
    f.write(reinterpret_cast<const char *>(&header), sizeof(header));
}

static uint64_t read_checkpoint_header(std::ifstream &f, const fs::path &path) {
    CheckpointHeader header{};
    f.read(reinterpret_cast<char *>(&header), sizeof(header));
    if (!f)
        throw std::runtime_error("Cannot read checkpoint header: " + path.string());
    if (header.magic != CHECKPOINT_MAGIC)
        throw std::runtime_error("Unsupported unversioned checkpoint: " + path.string() +
                                 " (rebuild checkpoints with schema v2)");
    if (header.version != CHECKPOINT_VERSION || header.record_size != sizeof(MergeRecord))
        throw std::runtime_error("Unsupported checkpoint version/layout: " + path.string());
    return header.count;
}

static int profile_id_for_structure(int structure_id) {
    if (structure_id <= 1) return 1;      /* [6] */
    if (structure_id <= 3) return 2;      /* [5,2] */
    if (structure_id <= 7) return 3;      /* [4,3] */
    if (structure_id <= 14) return 4;     /* [4,2,2] */
    if (structure_id <= 32) return 5;     /* [3,3,2] */
    if (structure_id <= 45) return 6;     /* [3,2,2,2] */
    if (structure_id <= 47) return 7;     /* [2,2,2,2,2] */
    return 0;
}

static bool key_less(const Hash128 &a, const Hash128 &b) {
    if (a.hi != b.hi) return a.hi < b.hi;
    return a.lo < b.lo;
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Compute xxHash128 of a normal form matrix
 * ═══════════════════════════════════════════════════════════════════════════ */

static Hash128 hash_normal_form(const Long nf[POLY_Dmax][VERT_Nmax],
                                int dim, int nv) {
    /* Hash only the used portion: dim rows × nv columns.
       We lay out rows contiguously for the hash. */
    /* Maximum size: 5 * 64 * 8 = 2560 bytes — always fits on stack */
    Long buf[POLY_Dmax * VERT_Nmax];
    int k = 0;
    for (int i = 0; i < dim; i++)
        for (int j = 0; j < nv; j++)
            buf[k++] = nf[i][j];

    XXH128_hash_t h = XXH3_128bits(buf, k * sizeof(Long));
    return {h.low64, h.high64};
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Arrow / Parquet helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

#define CHECK_ARROW(expr)                                            \
    do {                                                             \
        arrow::Status _s = (expr);                                   \
        if (!_s.ok())                                                \
            throw std::runtime_error(std::string(__FILE__) + ":" +   \
                std::to_string(__LINE__) + " " + _s.ToString());     \
    } while (0)

#define ASSIGN_OR_THROW(lhs, expr)                                   \
    do {                                                             \
        auto _r = (expr);                                            \
        if (!_r.ok())                                                \
            throw std::runtime_error(std::string(__FILE__) + ":" +   \
                std::to_string(__LINE__) + " " + _r.status().ToString()); \
        lhs = std::move(_r).ValueOrDie();                            \
    } while (0)

/* ═══════════════════════════════════════════════════════════════════════════
 *  Thread pool
 * ═══════════════════════════════════════════════════════════════════════════ */

class ThreadPool {
public:
    explicit ThreadPool(int n) {
        for (int i = 0; i < n; i++)
            workers_.emplace_back([this] { run(); });
    }
    ~ThreadPool() {
        { std::unique_lock<std::mutex> lk(mtx_); stop_ = true; }
        cv_.notify_all();
        for (auto &w : workers_) w.join();
    }
    template <class F>
    std::future<void> enqueue(F &&f) {
        auto task = std::make_shared<std::packaged_task<void()>>(std::forward<F>(f));
        auto fut = task->get_future();
        { std::unique_lock<std::mutex> lk(mtx_); queue_.emplace([task] { (*task)(); }); }
        cv_.notify_one();
        return fut;
    }
private:
    void run() {
        for (;;) {
            std::function<void()> job;
            {
                std::unique_lock<std::mutex> lk(mtx_);
                cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
                if (stop_ && queue_.empty()) return;
                job = std::move(queue_.front());
                queue_.pop();
            }
            job();
        }
    }
    std::vector<std::thread>           workers_;
    std::queue<std::function<void()>>  queue_;
    std::mutex                         mtx_;
    std::condition_variable            cv_;
    bool                               stop_{false};
};

/* ═══════════════════════════════════════════════════════════════════════════
 *  Statistics tracking
 * ═══════════════════════════════════════════════════════════════════════════ */

struct Stats {
    std::atomic<int64_t> total_cws{0};
    std::atomic<int64_t> processed_cws{0};
    std::atomic<int64_t> failed_cws{0};
    std::atomic<int64_t> duplicate_cws{0};
    std::atomic<int64_t> unique_polytopes{0};
    std::atomic<int>     files_done{0};
    int                  files_total{0};
    std::chrono::steady_clock::time_point start;

    void print_progress() const {
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - start).count();
        int64_t proc = processed_cws.load();
        double rate = proc / (elapsed > 0 ? elapsed : 1.0);
        double remaining = (total_cws.load() - proc) / (rate > 0 ? rate : 1.0);

        std::cerr << "\r  [" << files_done.load() << "/" << files_total << " files]"
                  << "  " << proc / 1'000'000 << "M / "
                  << total_cws.load() / 1'000'000 << "M CWS"
                  << "  unique: " << unique_polytopes.load()
                  << "  dup: " << duplicate_cws.load() / 1'000'000 << "M"
                  << "  fail: " << failed_cws.load()
                  << "  " << std::fixed << std::setprecision(0)
                  << rate / 1000 << "K/s"
                  << "  ETA " << (int)(remaining / 60) << "m"
                  << "        " << std::flush;
    }
};

/* ═══════════════════════════════════════════════════════════════════════════
 *  Process a batch of CWS rows
 * ═══════════════════════════════════════════════════════════════════════════ */

struct CWSRow {
    int32_t schema_version;
    int32_t structure_id;
    int32_t profile_id;
    int64_t source_index;
    PalpCWSInput cws;
    int32_t vertex_count;
    int32_t facet_count;
    int32_t point_count;
    int32_t dual_point_count;
    int32_t h11, h12, h13;
};

static void fill_first_cws_info(PolytopeInfo &info, const CWSRow &row) {
    /* Single weight system: record its provenance and the six weights. */
    info.source_index = row.source_index;
    std::memset(info.weights, 0, sizeof(info.weights));
    for (int c = 0; c < row.cws.N && c < 6; c++)
        info.weights[c] = row.cws.weights[0][c];
}

static void process_batch(const std::vector<CWSRow> &rows,
                          PalpWorkspace *ws,
                          PolytopeMap &local_map,
                          Stats &stats)
{
    PalpNFResult result;

    for (const auto &row : rows) {
        palp_compute_nf_from_cws(ws, &row.cws, &result);

        if (!result.ok) {
            stats.failed_cws.fetch_add(1, std::memory_order_relaxed);
            stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
            continue;
        }

        Hash128 key = hash_normal_form(result.nf, result.dim, result.nv);

        auto it = local_map.find(key);
        if (it != local_map.end()) {
            it->second.count++;
            stats.duplicate_cws.fetch_add(1, std::memory_order_relaxed);
        } else {
            PolytopeInfo info{};
            info.count = 1;
            fill_first_cws_info(info, row);
            info.vertex_count     = static_cast<int16_t>(result.nv);
            info.facet_count      = static_cast<int16_t>(result.ne);
            info.point_count      = result.np;
            info.dual_point_count = row.dual_point_count;
            info.h11              = static_cast<int16_t>(row.h11);
            info.h12              = static_cast<int16_t>(row.h12);
            info.h13              = static_cast<int16_t>(row.h13);
            local_map.emplace(key, info);
        }
        stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Merge local map into global map (under lock)
 * ═══════════════════════════════════════════════════════════════════════════ */

static void merge_maps(PolytopeMap &global, PolytopeMap &local,
                       std::mutex &global_mtx, Stats &stats)
{
    std::lock_guard<std::mutex> lk(global_mtx);
    for (auto &[key, info] : local) {
        auto it = global.find(key);
        if (it != global.end()) {
            it->second.count += info.count;
            /* The first occurrence of this key in the batch was counted in
               processed_cws but not as dup (only within-batch duplicates
               2..N were counted by process_batch).  It is a global duplicate,
               so credit it here. */
            stats.duplicate_cws.fetch_add(1, std::memory_order_relaxed);
        } else {
            global.emplace(key, info);
            stats.unique_polytopes.fetch_add(1, std::memory_order_relaxed);
        }
    }
    local.clear();
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Read a parquet file and extract CWS rows
 * ═══════════════════════════════════════════════════════════════════════════ */

static std::vector<CWSRow> read_parquet_file(const fs::path &path,
                                             int64_t max_rows = 0) {
    std::shared_ptr<arrow::io::ReadableFile> infile;
    ASSIGN_OR_THROW(infile, arrow::io::ReadableFile::Open(path.string()));

    std::unique_ptr<parquet::arrow::FileReader> reader;
    {
        parquet::arrow::FileReaderBuilder builder;
        CHECK_ARROW(builder.Open(infile));
        CHECK_ARROW(builder.Build(&reader));
    }

    /* Read only the columns we need.  Schema v1 is the historical single
       six-weight format.  Schema v2 stores a true combined CWS matrix. */
    std::vector<int> col_indices;
    auto file_schema = reader->parquet_reader()->metadata()->schema();
    auto has_column = [&](const std::string &name) {
        return file_schema->ColumnIndex(name) >= 0;
    };

    bool combined_schema = has_column("nw") && has_column("N") &&
                           has_column("degree0") && has_column("weight0_0");

    std::vector<std::string> needed;
    if (combined_schema) {
        needed = {
            "cws_schema_version", "structure_id", "profile_id",
            "source_index", "nw", "N",
            "vertex_count", "facet_count", "point_count", "dual_point_count",
            "h11", "h12", "h13"
        };
        for (int r = 0; r < PALP_API_MAX_CWS; r++)
            needed.push_back("degree" + std::to_string(r));
        for (int r = 0; r < PALP_API_MAX_CWS; r++)
            for (int c = 0; c < PALP_API_MAX_COORDS; c++)
                needed.push_back("weight" + std::to_string(r) + "_" + std::to_string(c));
    } else {
        needed = {
            "weight0", "weight1", "weight2", "weight3", "weight4", "weight5",
            "vertex_count", "facet_count", "point_count", "dual_point_count",
            "h11", "h12", "h13"
        };
    }
    for (const auto &name : needed) {
        int idx = file_schema->ColumnIndex(name);
        if (idx >= 0) col_indices.push_back(idx);
    }

    std::shared_ptr<arrow::Table> table;
    CHECK_ARROW(reader->ReadTable(col_indices, &table));

    if (max_rows > 0 && table->num_rows() > max_rows)
        table = table->Slice(0, max_rows);

    /* Flatten multi-chunk columns into single chunks so that raw_values()
       pointers remain valid for the lifetime of `table`.  Multi-chunk columns
       arise when a Parquet file has more than one row group; without this step
       the get_col lambda below would return a raw pointer into a temporary
       combined array that is freed immediately, causing heap corruption. */
    ASSIGN_OR_THROW(table, table->CombineChunks());

    int64_t n = table->num_rows();
    std::vector<CWSRow> rows(n);

    /* Extract columns as flat arrays.  The project schemas use int32 for CWS
       values and int64 for source_index. */
    auto get_col = [&](const std::string &name) -> const int32_t * {
        auto col = table->GetColumnByName(name);
        if (!col || col->num_chunks() == 0) return nullptr;
        return std::static_pointer_cast<arrow::Int32Array>(
                   col->chunk(0))->raw_values();
    };
    auto get_i64_col = [&](const std::string &name) -> const int64_t * {
        auto col = table->GetColumnByName(name);
        if (!col || col->num_chunks() == 0) return nullptr;
        return std::static_pointer_cast<arrow::Int64Array>(
                   col->chunk(0))->raw_values();
    };

    const int32_t *vc  = get_col("vertex_count");
    const int32_t *fc  = get_col("facet_count");
    const int32_t *pc  = get_col("point_count");
    const int32_t *dpc = get_col("dual_point_count");
    const int32_t *h11 = get_col("h11");
    const int32_t *h12 = get_col("h12");
    const int32_t *h13 = get_col("h13");

    if (combined_schema) {
        const int32_t *schema_version = get_col("cws_schema_version");
        const int32_t *structure_id = get_col("structure_id");
        const int32_t *profile_id = get_col("profile_id");
        const int64_t *source_index = get_i64_col("source_index");
        const int32_t *nw = get_col("nw");
        const int32_t *N = get_col("N");
        std::array<const int32_t *, PALP_API_MAX_CWS> degree{};
        std::array<std::array<const int32_t *, PALP_API_MAX_COORDS>, PALP_API_MAX_CWS> weight{};

        if (!nw || !N)
            throw std::runtime_error(path.string() + ": combined CWS schema missing nw or N");

        for (int r = 0; r < PALP_API_MAX_CWS; r++)
            degree[r] = get_col("degree" + std::to_string(r));
        for (int r = 0; r < PALP_API_MAX_CWS; r++)
            for (int c = 0; c < PALP_API_MAX_COORDS; c++)
                weight[r][c] = get_col("weight" + std::to_string(r) + "_" + std::to_string(c));

        for (int64_t i = 0; i < n; i++) {
            CWSRow &row = rows[i];
            row.schema_version = schema_version ? schema_version[i] : CLASSIFIER_SCHEMA_COMBINED;
            row.structure_id = structure_id ? structure_id[i] : 0;
            row.profile_id = profile_id ? profile_id[i] : profile_id_for_structure(row.structure_id);
            row.source_index = source_index ? source_index[i] : i;
            std::memset(&row.cws, 0, sizeof(row.cws));
            row.cws.nw = nw[i];
            row.cws.N = N[i];
            row.cws.index = 1;
            if (row.cws.nw < 1 || row.cws.nw > PALP_API_MAX_CWS ||
                row.cws.N < 1 || row.cws.N > PALP_API_MAX_COORDS ||
                row.cws.N - row.cws.nw != POLY_Dmax)
                throw std::runtime_error(path.string() + ": invalid combined CWS dimensions at row " +
                                         std::to_string(i));
            for (int r = 0; r < PALP_API_MAX_CWS; r++) {
                row.cws.degree[r] = degree[r] ? degree[r][i] : 0;
                for (int c = 0; c < PALP_API_MAX_COORDS; c++)
                    row.cws.weights[r][c] = weight[r][c] ? weight[r][c][i] : 0;
            }
            row.vertex_count     = vc  ? vc[i]  : 0;
            row.facet_count      = fc  ? fc[i]  : 0;
            row.point_count      = pc  ? pc[i]  : 0;
            row.dual_point_count = dpc ? dpc[i] : 0;
            row.h11 = h11 ? h11[i] : 0;
            row.h12 = h12 ? h12[i] : 0;
            row.h13 = h13 ? h13[i] : 0;
        }
        return rows;
    }

    const int32_t *w0  = get_col("weight0");
    const int32_t *w1  = get_col("weight1");
    const int32_t *w2  = get_col("weight2");
    const int32_t *w3  = get_col("weight3");
    const int32_t *w4  = get_col("weight4");
    const int32_t *w5  = get_col("weight5");
    if (!w0 || !w1 || !w2 || !w3 || !w4 || !w5)
        throw std::runtime_error(path.string() + ": legacy CWS schema missing weight0..weight5");

    for (int64_t i = 0; i < n; i++) {
        CWSRow &row = rows[i];
        row.schema_version = CLASSIFIER_SCHEMA_LEGACY;
        row.structure_id = 1;
        row.profile_id = 1;
        row.source_index = i;
        std::memset(&row.cws, 0, sizeof(row.cws));
        row.cws.nw = 1;
        row.cws.N = 6;
        row.cws.index = 1;
        row.cws.weights[0][0] = w0[i];
        row.cws.weights[0][1] = w1[i];
        row.cws.weights[0][2] = w2[i];
        row.cws.weights[0][3] = w3[i];
        row.cws.weights[0][4] = w4[i];
        row.cws.weights[0][5] = w5[i];
        for (int c = 0; c < 6; c++)
            row.cws.degree[0] += row.cws.weights[0][c];
        rows[i].vertex_count     = vc  ? vc[i]  : 0;
        rows[i].facet_count      = fc  ? fc[i]  : 0;
        rows[i].point_count      = pc  ? pc[i]  : 0;
        rows[i].dual_point_count = dpc ? dpc[i] : 0;
        rows[i].h11 = h11 ? h11[i] : 0;
        rows[i].h12 = h12 ? h12[i] : 0;
        rows[i].h13 = h13 ? h13[i] : 0;
    }
    return rows;
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Write results to output parquet
 * ═══════════════════════════════════════════════════════════════════════════ */

static void write_results(const PolytopeMap &global_map,
                          const fs::path &output_path,
                          bool non_reflexive = false) {
    /* Slim single-weight-system schema.  degree = sum(weights) is derivable and
       not stored.  Non-reflexive input has no lattice dual, so dual_point_count
       and Hodge (h11/h12/h13) are omitted. */
    std::vector<std::shared_ptr<arrow::Field>> fields = {
        arrow::field("hash_lo",       arrow::uint64()),
        arrow::field("hash_hi",       arrow::uint64()),
        arrow::field("count",         arrow::uint64()),
        arrow::field("source_index",  arrow::int64()),
        arrow::field("weight0",       arrow::int32()),
        arrow::field("weight1",       arrow::int32()),
        arrow::field("weight2",       arrow::int32()),
        arrow::field("weight3",       arrow::int32()),
        arrow::field("weight4",       arrow::int32()),
        arrow::field("weight5",       arrow::int32()),
        arrow::field("vertex_count",  arrow::int16()),
        arrow::field("facet_count",   arrow::int16()),
        arrow::field("point_count",   arrow::int32()),
    };
    if (!non_reflexive)
        fields.insert(fields.end(), {
            arrow::field("dual_point_count",  arrow::int32()),
            arrow::field("h11",               arrow::int16()),
            arrow::field("h12",               arrow::int16()),
            arrow::field("h13",               arrow::int16()),
        });
    auto schema = arrow::schema(fields);

    arrow::UInt64Builder  hash_lo_b, hash_hi_b, count_b;
    arrow::Int64Builder   source_b;
    arrow::Int32Builder   w0_b, w1_b, w2_b, w3_b, w4_b, w5_b;
    arrow::Int16Builder   vc_b, fc_b, h11_b, h12_b, h13_b;
    arrow::Int32Builder   pc_b, dpc_b;

    int64_t n = static_cast<int64_t>(global_map.size());
    CHECK_ARROW(hash_lo_b.Reserve(n));  CHECK_ARROW(hash_hi_b.Reserve(n));
    CHECK_ARROW(count_b.Reserve(n));    CHECK_ARROW(source_b.Reserve(n));
    CHECK_ARROW(w0_b.Reserve(n));  CHECK_ARROW(w1_b.Reserve(n));
    CHECK_ARROW(w2_b.Reserve(n));  CHECK_ARROW(w3_b.Reserve(n));
    CHECK_ARROW(w4_b.Reserve(n));  CHECK_ARROW(w5_b.Reserve(n));
    CHECK_ARROW(vc_b.Reserve(n));  CHECK_ARROW(fc_b.Reserve(n));
    CHECK_ARROW(pc_b.Reserve(n));  CHECK_ARROW(dpc_b.Reserve(n));
    CHECK_ARROW(h11_b.Reserve(n)); CHECK_ARROW(h12_b.Reserve(n));
    CHECK_ARROW(h13_b.Reserve(n));

    for (const auto &[key, info] : global_map) {
        CHECK_ARROW(hash_lo_b.Append(key.lo));
        CHECK_ARROW(hash_hi_b.Append(key.hi));
        CHECK_ARROW(count_b.Append(info.count));
        CHECK_ARROW(source_b.Append(info.source_index));
        CHECK_ARROW(w0_b.Append(info.weights[0]));
        CHECK_ARROW(w1_b.Append(info.weights[1]));
        CHECK_ARROW(w2_b.Append(info.weights[2]));
        CHECK_ARROW(w3_b.Append(info.weights[3]));
        CHECK_ARROW(w4_b.Append(info.weights[4]));
        CHECK_ARROW(w5_b.Append(info.weights[5]));
        CHECK_ARROW(vc_b.Append(info.vertex_count));
        CHECK_ARROW(fc_b.Append(info.facet_count));
        CHECK_ARROW(pc_b.Append(info.point_count));
        CHECK_ARROW(dpc_b.Append(info.dual_point_count));
        CHECK_ARROW(h11_b.Append(info.h11));
        CHECK_ARROW(h12_b.Append(info.h12));
        CHECK_ARROW(h13_b.Append(info.h13));
    }

    std::shared_ptr<arrow::Array>
        a_hlo, a_hhi, a_cnt, a_source,
        a_w0, a_w1, a_w2, a_w3, a_w4, a_w5,
        a_vc, a_fc, a_pc, a_dpc, a_h11, a_h12, a_h13;

    CHECK_ARROW(hash_lo_b.Finish(&a_hlo)); CHECK_ARROW(hash_hi_b.Finish(&a_hhi));
    CHECK_ARROW(count_b.Finish(&a_cnt));   CHECK_ARROW(source_b.Finish(&a_source));
    CHECK_ARROW(w0_b.Finish(&a_w0));  CHECK_ARROW(w1_b.Finish(&a_w1));
    CHECK_ARROW(w2_b.Finish(&a_w2));  CHECK_ARROW(w3_b.Finish(&a_w3));
    CHECK_ARROW(w4_b.Finish(&a_w4));  CHECK_ARROW(w5_b.Finish(&a_w5));
    CHECK_ARROW(vc_b.Finish(&a_vc));  CHECK_ARROW(fc_b.Finish(&a_fc));
    CHECK_ARROW(pc_b.Finish(&a_pc));  CHECK_ARROW(dpc_b.Finish(&a_dpc));
    CHECK_ARROW(h11_b.Finish(&a_h11)); CHECK_ARROW(h12_b.Finish(&a_h12));
    CHECK_ARROW(h13_b.Finish(&a_h13));

    std::vector<std::shared_ptr<arrow::Array>> arrays = {
        a_hlo, a_hhi, a_cnt, a_source,
        a_w0, a_w1, a_w2, a_w3, a_w4, a_w5,
        a_vc, a_fc, a_pc,
    };
    if (!non_reflexive)
        arrays.insert(arrays.end(), { a_dpc, a_h11, a_h12, a_h13 });
    auto table = arrow::Table::Make(schema, arrays);

    /* Write */
    std::shared_ptr<arrow::io::FileOutputStream> out;
    ASSIGN_OR_THROW(out, arrow::io::FileOutputStream::Open(output_path.string()));

    auto writer_props = parquet::WriterProperties::Builder()
        .compression(parquet::Compression::ZSTD)
        ->max_row_group_length(1024 * 1024)
        ->build();

    CHECK_ARROW(parquet::arrow::WriteTable(*table, arrow::default_memory_pool(),
                                           out, 1024 * 1024, writer_props));
    CHECK_ARROW(out->Close());
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Write a checkpoint (serialise hash map to binary file)
 * ═══════════════════════════════════════════════════════════════════════════ */

static void write_checkpoint(const PolytopeMap &map, const fs::path &path) {
    std::ofstream f(path, std::ios::binary);
    uint64_t n = map.size();
    write_checkpoint_header(f, n);
    for (const auto &[key, info] : map) {
        f.write(reinterpret_cast<const char *>(&key), sizeof(key));
        f.write(reinterpret_cast<const char *>(&info), sizeof(info));
    }
    std::cerr << "\n  Checkpoint: " << n << " entries → " << path.string() << "\n";
}


static void read_checkpoint(PolytopeMap &map, const fs::path &path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return;
    uint64_t n = read_checkpoint_header(f, path);
    map.reserve(n);
    for (uint64_t i = 0; i < n; i++) {
        Hash128 key;
        PolytopeInfo info;
        f.read(reinterpret_cast<char *>(&key), sizeof(key));
        f.read(reinterpret_cast<char *>(&info), sizeof(info));
        auto it = map.find(key);
        if (it != map.end())
            it->second.count += info.count;
        else
            map.emplace(key, info);
    }
    std::cerr << "  Loaded checkpoint: " << n << " entries from " << path.string() << "\n";
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  In-memory sort-merge checkpoint merger
 *
 *  Maximises use of available RAM to avoid intermediate disk I/O:
 *    1. Load shards one at a time, parallel-sort in-place, keep in RAM
 *    2. When a batch fills memory, k-way merge with dedup → small temp file
 *    3. Final k-way merge of temp files (or single batch) → Parquet
 *
 *  With 700 GB RAM and ~19 GB/shard all 67 shards fit in one batch,
 *  so the only disk write is the final Parquet output.
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ── Helper: load a checkpoint and parallel-sort it in-place ──────────────
 *  Phase A: parallel chunk sort.  Phase B: cascading parallel inplace_merge.
 *  No extra allocation beyond what inplace_merge needs internally.         */

static std::vector<MergeRecord> load_and_sort_shard(
        const fs::path &path, int n_threads) {
    auto t0 = std::chrono::steady_clock::now();

    std::ifstream f(path, std::ios::binary);
    if (!f.is_open())
        throw std::runtime_error("Cannot open: " + path.string());
    uint64_t n = read_checkpoint_header(f, path);
    std::vector<MergeRecord> records(n);
    f.read(reinterpret_cast<char *>(records.data()),
           static_cast<std::streamsize>(n * sizeof(MergeRecord)));
    f.close();

    double read_secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();

    auto cmp = [](const MergeRecord &a, const MergeRecord &b) {
        return key_less(a.key, b.key);
    };
    int64_t nn = static_cast<int64_t>(n);
    int n_chunks = std::min(n_threads, std::max(1, static_cast<int>(nn / 1000)));
    int64_t chunk_size = (nn + n_chunks - 1) / n_chunks;

    /* Phase A: sort independent chunks in parallel */
    {
        std::vector<std::thread> threads;
        threads.reserve(n_chunks);
        for (int t = 0; t < n_chunks; t++) {
            int64_t b = static_cast<int64_t>(t) * chunk_size;
            int64_t e = std::min(b + chunk_size, nn);
            threads.emplace_back([&records, b, e, &cmp]() {
                std::sort(records.begin() + b, records.begin() + e, cmp);
            });
        }
        for (auto &th : threads) th.join();
    }

    /* Phase B: cascade parallel inplace_merge — adjacent pairs at each
       doubling of width are independent and can run concurrently.         */
    for (int64_t width = chunk_size; width < nn; width *= 2) {
        std::vector<std::thread> mthreads;
        for (int64_t left = 0; left < nn; left += 2 * width) {
            int64_t mid   = std::min(left + width,     nn);
            int64_t right = std::min(left + 2 * width, nn);
            if (mid < right)
                mthreads.emplace_back([&records, left, mid, right, &cmp]() {
                    std::inplace_merge(records.begin() + left,
                                       records.begin() + mid,
                                       records.begin() + right, cmp);
                });
        }
        for (auto &th : mthreads) th.join();
    }

    double total_secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();
    std::cerr << "    " << path.filename().string()
              << " (" << n / 1'000'000.0 << "M)"
              << "  read=" << std::fixed << std::setprecision(1) << read_secs << "s"
              << "  sort=" << (total_secs - read_secs) << "s"
              << "  total=" << total_secs << "s\n";
    return records;
}

/* ── Helper: buffered reader for sorted binary intermediate files ─────── */

class SortedBinaryReader {
    static constexpr size_t BUF_RECORDS = 256 * 1024;
    std::ifstream file_;
    uint64_t remaining_;
    std::vector<MergeRecord> buffer_;
    size_t buf_pos_, buf_size_;
public:
    MergeRecord current;
    bool valid;
    explicit SortedBinaryReader(const fs::path &path)
        : buffer_(BUF_RECORDS), buf_pos_(0), buf_size_(0), valid(false)
    {
        file_.open(path, std::ios::binary);
        if (!file_.is_open())
            throw std::runtime_error("Cannot open: " + path.string());
        remaining_ = read_checkpoint_header(file_, path);
        advance();
    }
    void advance() {
        if (buf_pos_ < buf_size_) { current = buffer_[buf_pos_++]; valid = true; return; }
        if (remaining_ == 0) { valid = false; return; }
        size_t to_read = std::min(static_cast<uint64_t>(BUF_RECORDS), remaining_);
        file_.read(reinterpret_cast<char *>(buffer_.data()),
                   static_cast<std::streamsize>(to_read * sizeof(MergeRecord)));
        buf_pos_ = 1; buf_size_ = to_read; remaining_ -= to_read;
        current = buffer_[0]; valid = true;
    }
};

/* ── Heap entry for file-based final merge ──────────────────────────────── */

struct FileHeapEntry {
    Hash128 key; int reader_idx;
    bool operator>(const FileHeapEntry &o) const {
        if (key.hi != o.key.hi) return key.hi > o.key.hi;
        return key.lo > o.key.lo;
    }
};

/* ── Cursor for in-memory k-way merge ───────────────────────────────────── */

struct MemCursor {
    const MergeRecord *cur, *end;
    bool operator>(const MemCursor &o) const { return key_less(o.cur->key, cur->key); }
};

/* ── Merge sorted in-memory vectors with dedup → binary intermediate file ─ */

static uint64_t merge_batch_to_file(
        std::vector<std::vector<MergeRecord>> &shards, const fs::path &out_path)
{
    std::priority_queue<MemCursor, std::vector<MemCursor>,
                        std::greater<MemCursor>> heap;
    for (auto &v : shards)
        if (!v.empty()) heap.push({v.data(), v.data() + v.size()});

    std::ofstream out(out_path, std::ios::binary);
    uint64_t count = 0;
    write_checkpoint_header(out, count); /* placeholder */

    constexpr size_t WBUF = 256 * 1024;
    std::vector<MergeRecord> wbuf; wbuf.reserve(WBUF);

    while (!heap.empty()) {
        MemCursor top = heap.top(); heap.pop();
        MergeRecord merged = *top.cur; ++top.cur;
        if (top.cur < top.end) heap.push(top);
        while (!heap.empty() && heap.top().cur->key == merged.key) {
            MemCursor dup = heap.top(); heap.pop();
            merged.info.count += dup.cur->info.count;
            ++dup.cur;
            if (dup.cur < dup.end) heap.push(dup);
        }
        wbuf.push_back(merged); count++;
        if (wbuf.size() >= WBUF) {
            out.write(reinterpret_cast<const char *>(wbuf.data()),
                      static_cast<std::streamsize>(wbuf.size() * sizeof(MergeRecord)));
            wbuf.clear();
        }
    }
    if (!wbuf.empty())
        out.write(reinterpret_cast<const char *>(wbuf.data()),
                  static_cast<std::streamsize>(wbuf.size() * sizeof(MergeRecord)));
    out.seekp(0);
    write_checkpoint_header(out, count);
    out.close();
    return count;
}

/* ── Main merge entry point ─────────────────────────────────────────────── *
 *
 *  Two-phase external sort-merge.  Works on any RAM ≥ ~2× largest shard.
 *
 *  Phase 1 — sort each shard independently (one at a time):
 *    Load shard → parallel sort → write sorted binary to sorted_shards/ dir.
 *    Peak RAM = 1 shard + inplace_merge buffer ≈ 2× shard size (~66 GB max).
 *    Resumable: if sorted/<name> already exists with matching size, skip it.
 *
 *  Phase 2 — N-way streaming merge → Parquet:
 *    Open all sorted files simultaneously via buffered SortedBinaryReader.
 *    Min-heap of size N drives the merge; each reader holds 256K records
 *    (~18 MB).  Peak RAM = N × 18 MB ≈ 1.2 GB for 67 shards.
 *    Dedup by coalescing consecutive equal keys (summing counts).
 *
 *  Disk: sorted_shards/ holds one sorted copy of every shard (~1.25 TB for
 *  67 × 33 GB shards).  Deleted automatically after Phase 2 completes.
 * ─────────────────────────────────────────────────────────────────────────*/

static void merge_checkpoints(const std::vector<fs::path> &shard_paths,
                               const fs::path &output_path,
                               int n_threads,
                               bool assume_sorted = false,
                               bool non_reflexive = false) {
    auto t_total = std::chrono::steady_clock::now();
    const size_t n_shards = shard_paths.size();

    /* ── Scan shard record counts ─────────────────────────────────────────── */
    uint64_t total_input_records = 0;
    std::vector<uint64_t> shard_counts(n_shards);
    for (size_t i = 0; i < n_shards; i++) {
        std::ifstream f(shard_paths[i], std::ios::binary);
        if (!f) throw std::runtime_error("Cannot open: " + shard_paths[i].string());
        shard_counts[i] = read_checkpoint_header(f, shard_paths[i]);
        total_input_records += shard_counts[i];
    }

    double input_gb = static_cast<double>(total_input_records) * sizeof(MergeRecord)
                      / (1024.0 * 1024 * 1024);
    size_t phys_bytes = static_cast<size_t>(sysconf(_SC_PHYS_PAGES))
                      * static_cast<size_t>(sysconf(_SC_PAGESIZE));
    size_t phys_gb = phys_bytes / (1024ULL * 1024 * 1024);
    size_t largest_shard_bytes = *std::max_element(shard_counts.begin(), shard_counts.end())
                                 * sizeof(MergeRecord);

    std::cerr << "═══════════════════════════════════════════════════════════════\n"
              << " Two-Phase External Sort-Merge: " << n_shards << " shards, "
              << n_threads << " threads\n"
              << "═══════════════════════════════════════════════════════════════\n\n"
              << "Total input:   " << std::fixed << std::setprecision(1)
              << total_input_records / 1'000'000.0
              << "M records  (" << input_gb << " GB)\n"
              << "Physical RAM:  " << phys_gb << " GB\n"
              << "Largest shard: " << largest_shard_bytes / (1024.0*1024*1024) << " GB"
              << "  (peak sort RAM ≈ "
              << 2.0 * largest_shard_bytes / (1024.0*1024*1024) << " GB)\n\n";

    if (2 * largest_shard_bytes > phys_bytes * 85ULL / 100)
        throw std::runtime_error(
            "Largest shard needs ~" +
            std::to_string(2 * largest_shard_bytes / (1024*1024*1024)) +
            " GB for sorting but only " + std::to_string(phys_gb) +
            " GB physical RAM available.");

    /* ══════════════════════════════════════════════════════════════════════
     *  Phase 1: sort each shard in-place (overwrites originals)
     *
     *  Disk overhead: one ~33 GB .tmp file at a time — no separate
     *  sorted_shards/ directory needed.  Safe on machines with limited
     *  free disk space (you only need ~shard_size + output_parquet free).
     *
     *  Resumability: a zero-byte <shard>.sorted marker file is written
     *  after each successful sort.  Re-running skips marked shards.
     *  To force a full re-sort, delete the .sorted marker files.
     * ══════════════════════════════════════════════════════════════════════ */

    if (assume_sorted) {
        std::cerr << "Phase 1: SKIPPED (--assume-sorted)\n\n";
    } else {
    std::cerr << "Phase 1: sorting " << n_shards << " shards in-place\n"
              << "  (each shard is overwritten with its sorted version)\n\n";
    }

    /* sorted_paths[i] == shard_paths[i]: Phase 2 reads from the originals */
    const std::vector<fs::path> &sorted_paths = shard_paths;
    size_t skipped = 0;

    for (size_t i = 0; i < n_shards; i++) {
        if (assume_sorted) { skipped++; continue; }
        fs::path marker = shard_paths[i].string() + ".sorted";

        /* Resumability: .sorted marker means this file is already sorted */
        if (fs::exists(marker)) {
            std::cerr << "[" << (i+1) << "/" << n_shards << "]  SKIP (already sorted): "
                      << shard_paths[i].filename().string() << "\n";
            skipped++;
            continue;
        }

        std::cerr << "[" << (i+1) << "/" << n_shards << "]  ";
        auto records = load_and_sort_shard(shard_paths[i], n_threads);

        /* Write sorted data to <original>.tmp, then atomically replace original */
        fs::path tmp_path = shard_paths[i].string() + ".tmp";
        {
            std::ofstream out(tmp_path, std::ios::binary);
            if (!out) throw std::runtime_error("Cannot write: " + tmp_path.string());
            uint64_t n = records.size();
            write_checkpoint_header(out, n);
            out.write(reinterpret_cast<const char *>(records.data()),
                      static_cast<std::streamsize>(n * sizeof(MergeRecord)));
        }
        /* Free shard memory BEFORE rename — keeps peak RSS minimal */
        { std::vector<MergeRecord>().swap(records); }
        fs::rename(tmp_path, shard_paths[i]);   /* atomic: replaces original */

        /* Leave a marker so a restart skips this shard */
        { std::ofstream m(marker); }

        std::cerr << "    → sorted in-place  ("
                  << std::fixed << std::setprecision(1)
                  << fs::file_size(shard_paths[i]) / (1024.0*1024*1024) << " GB)\n";
    }

    double phase1_secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_total).count();
    std::cerr << "\nPhase 1 complete: " << (n_shards - skipped) << " sorted, "
              << skipped << " skipped  (" << std::fixed << std::setprecision(1)
              << phase1_secs / 60 << " min)\n\n";

    /* ══════════════════════════════════════════════════════════════════════
     *  Phase 2: N-way streaming merge → Parquet
     *  Peak RAM = N readers × 256K records × 72 bytes ≈ 1.2 GB for 67 shards
     * ══════════════════════════════════════════════════════════════════════ */

    std::cerr << "Phase 2: " << n_shards << "-way streaming merge → Parquet...\n"
              << "  Output: " << output_path.string() << "\n\n";

    /* Open all sorted files */
    std::vector<std::unique_ptr<SortedBinaryReader>> readers;
    readers.reserve(n_shards);
    for (auto &p : sorted_paths)
        readers.push_back(std::make_unique<SortedBinaryReader>(p));

    /* Min-heap: (key, reader_index) */
    std::priority_queue<FileHeapEntry, std::vector<FileHeapEntry>,
                        std::greater<FileHeapEntry>> heap;
    for (int i = 0; i < static_cast<int>(readers.size()); i++)
        if (readers[i]->valid)
            heap.push({readers[i]->current.key, i});

    /* ── Parquet writer ─────────────────────────────────────────────────── */
    std::vector<std::shared_ptr<arrow::Field>> merge_fields = {
        arrow::field("hash_lo",       arrow::uint64()),
        arrow::field("hash_hi",       arrow::uint64()),
        arrow::field("count",         arrow::uint64()),
        arrow::field("source_index",  arrow::int64()),
        arrow::field("weight0",       arrow::int32()),
        arrow::field("weight1",       arrow::int32()),
        arrow::field("weight2",       arrow::int32()),
        arrow::field("weight3",       arrow::int32()),
        arrow::field("weight4",       arrow::int32()),
        arrow::field("weight5",       arrow::int32()),
        arrow::field("vertex_count",  arrow::int16()),
        arrow::field("facet_count",   arrow::int16()),
        arrow::field("point_count",   arrow::int32()),
    };
    if (!non_reflexive)
        merge_fields.insert(merge_fields.end(), {
            arrow::field("dual_point_count", arrow::int32()),
            arrow::field("h11",              arrow::int16()),
            arrow::field("h12",              arrow::int16()),
            arrow::field("h13",              arrow::int16()),
        });
    auto schema = arrow::schema(merge_fields);
    auto writer_props = parquet::WriterProperties::Builder()
        .compression(parquet::Compression::ZSTD)
        ->max_row_group_length(1024 * 1024)->build();

    std::shared_ptr<arrow::io::FileOutputStream> pq_out;
    ASSIGN_OR_THROW(pq_out, arrow::io::FileOutputStream::Open(output_path.string()));
    auto pq_r = parquet::arrow::FileWriter::Open(
        *schema, arrow::default_memory_pool(), pq_out, writer_props);
    if (!pq_r.ok())
        throw std::runtime_error("Parquet open: " + pq_r.status().ToString());
    auto pq_writer = std::move(pq_r).ValueOrDie();

    arrow::UInt64Builder hash_lo_b, hash_hi_b, count_b;
    arrow::Int64Builder  source_b;
    arrow::Int32Builder  w0_b, w1_b, w2_b, w3_b, w4_b, w5_b, pc_b, dpc_b;
    arrow::Int16Builder  vc_b, fc_b, h11_b, h12_b, h13_b;
    int64_t pq_n = 0;
    constexpr int64_t PQ_FLUSH = 1'000'000;

    auto flush_pq = [&]() {
        if (pq_n == 0) return;
        std::shared_ptr<arrow::Array>
            a_hlo, a_hhi, a_cnt, a_source,
            a_w0, a_w1, a_w2, a_w3, a_w4, a_w5,
            a_vc, a_fc, a_pc, a_dpc, a_h11, a_h12, a_h13;
        CHECK_ARROW(hash_lo_b.Finish(&a_hlo)); CHECK_ARROW(hash_hi_b.Finish(&a_hhi));
        CHECK_ARROW(count_b.Finish(&a_cnt));   CHECK_ARROW(source_b.Finish(&a_source));
        CHECK_ARROW(w0_b.Finish(&a_w0)); CHECK_ARROW(w1_b.Finish(&a_w1));
        CHECK_ARROW(w2_b.Finish(&a_w2)); CHECK_ARROW(w3_b.Finish(&a_w3));
        CHECK_ARROW(w4_b.Finish(&a_w4)); CHECK_ARROW(w5_b.Finish(&a_w5));
        CHECK_ARROW(vc_b.Finish(&a_vc)); CHECK_ARROW(fc_b.Finish(&a_fc));
        CHECK_ARROW(pc_b.Finish(&a_pc)); CHECK_ARROW(dpc_b.Finish(&a_dpc));
        CHECK_ARROW(h11_b.Finish(&a_h11)); CHECK_ARROW(h12_b.Finish(&a_h12));
        CHECK_ARROW(h13_b.Finish(&a_h13));
        std::vector<std::shared_ptr<arrow::Array>> batch_arrays = {
            a_hlo, a_hhi, a_cnt, a_source,
            a_w0, a_w1, a_w2, a_w3, a_w4, a_w5, a_vc, a_fc, a_pc};
        if (!non_reflexive)
            batch_arrays.insert(batch_arrays.end(), {a_dpc, a_h11, a_h12, a_h13});
        auto batch = arrow::RecordBatch::Make(schema, pq_n, batch_arrays);
        CHECK_ARROW(pq_writer->WriteRecordBatch(*batch));
        pq_n = 0;
    };
    auto emit = [&](const Hash128 &key, const PolytopeInfo &info) {
        CHECK_ARROW(hash_lo_b.Append(key.lo));   CHECK_ARROW(hash_hi_b.Append(key.hi));
        CHECK_ARROW(count_b.Append(info.count));
        CHECK_ARROW(source_b.Append(info.source_index));
        CHECK_ARROW(w0_b.Append(info.weights[0]));
        CHECK_ARROW(w1_b.Append(info.weights[1]));
        CHECK_ARROW(w2_b.Append(info.weights[2]));
        CHECK_ARROW(w3_b.Append(info.weights[3]));
        CHECK_ARROW(w4_b.Append(info.weights[4]));
        CHECK_ARROW(w5_b.Append(info.weights[5]));
        CHECK_ARROW(vc_b.Append(info.vertex_count));
        CHECK_ARROW(fc_b.Append(info.facet_count));
        CHECK_ARROW(pc_b.Append(info.point_count));
        CHECK_ARROW(dpc_b.Append(info.dual_point_count));
        CHECK_ARROW(h11_b.Append(info.h11));
        CHECK_ARROW(h12_b.Append(info.h12));
        CHECK_ARROW(h13_b.Append(info.h13));
        if (++pq_n >= PQ_FLUSH) flush_pq();
    };

    /* ── Streaming heap-merge with dedup ─────────────────────────────────── */
    uint64_t total_unique = 0, total_input_seen = 0;
    auto t_phase2 = std::chrono::steady_clock::now();
    auto last_report = t_phase2;

    while (!heap.empty()) {
        FileHeapEntry top = heap.top(); heap.pop();
        Hash128 cur_key  = top.key;
        PolytopeInfo info = readers[top.reader_idx]->current.info;
        readers[top.reader_idx]->advance();
        if (readers[top.reader_idx]->valid)
            heap.push({readers[top.reader_idx]->current.key, top.reader_idx});
        total_input_seen++;

        /* Coalesce all readers that share this key */
        while (!heap.empty() && heap.top().key == cur_key) {
            FileHeapEntry dup = heap.top(); heap.pop();
            info.count += readers[dup.reader_idx]->current.info.count;
            readers[dup.reader_idx]->advance();
            if (readers[dup.reader_idx]->valid)
                heap.push({readers[dup.reader_idx]->current.key, dup.reader_idx});
            total_input_seen++;
        }

        emit(cur_key, info);
        total_unique++;

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration<double>(now - last_report).count() >= 5.0) {
            double elapsed = std::chrono::duration<double>(now - t_phase2).count();
            double rate    = total_input_seen / (elapsed > 0 ? elapsed : 1.0);
            double pct     = 100.0 * total_input_seen / total_input_records;
            double eta     = (total_input_records - total_input_seen)
                             / (rate > 0 ? rate : 1.0);
            std::cerr << "\r  " << std::fixed << std::setprecision(1) << pct << "%"
                      << "  unique=" << total_unique / 1'000'000.0 << "M"
                      << "  processed=" << total_input_seen / 1'000'000.0 << "M"
                      << "  " << std::setprecision(0) << rate / 1'000'000 << "M/s"
                      << "  ETA " << static_cast<int>(eta / 60) << "m"
                      << "        " << std::flush;
            last_report = now;
        }
    }

    flush_pq();
    CHECK_ARROW(pq_writer->Close());
    CHECK_ARROW(pq_out->Close());
    readers.clear();

    /* ── Cleanup .sorted marker files (data files are kept as-is) ─────── */
    std::cerr << "\n\nCleaning up .sorted markers...\n";
    for (auto &p : shard_paths) {
        fs::path marker = p.string() + ".sorted";
        if (fs::exists(marker)) fs::remove(marker);
    }

    double total_secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_total).count();
    std::cerr << "\n═══════════════════════════════════════════════════════════════\n"
              << " Merge Complete\n"
              << "═══════════════════════════════════════════════════════════════\n"
              << "  Total input records:  " << total_input_records << "\n"
              << "  Unique polytopes:     " << total_unique << "\n"
              << "  Duplicates removed:   " << (total_input_records - total_unique) << "\n"
              << "  Phase 1 (sort):       " << std::fixed << std::setprecision(1)
              << phase1_secs / 60 << " min\n"
              << "  Phase 2 (merge):      "
              << std::chrono::duration<double>(
                     std::chrono::steady_clock::now() - t_total).count() / 60
                 - phase1_secs / 60 << " min\n"
              << "  Total time:           " << total_secs / 60 << " min\n"
              << "  Output:               " << output_path.string() << "\n";
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Main processing loop: process one parquet file
 * ═══════════════════════════════════════════════════════════════════════════ */

/* Diagnostic perf knobs (investigation only; leave unset in production):
     PALP_BENCH_NOSTORE=1  compute NF + hash but skip the hash-map insert
     PALP_BENCH_NOHASH=1   (with NOSTORE) also skip hashing — raw PALP NF only
   These isolate whether the fat 320-byte map inserts (random GB-scale memory
   traffic) or the PALP NF compute itself is the scaling bottleneck. */
static bool bench_nostore() { static bool v = std::getenv("PALP_BENCH_NOSTORE") != nullptr; return v; }
static bool bench_nohash()  { static bool v = std::getenv("PALP_BENCH_NOHASH")  != nullptr; return v; }
static volatile uint64_t g_bench_sink = 0;

/* ── Parallel sort of a flat vector (chunk-sort + cascading inplace_merge) ── */
template <class T, class Cmp>
static void parallel_sort_vec(std::vector<T> &v, Cmp cmp, int n_threads) {
    int64_t nn = static_cast<int64_t>(v.size());
    if (nn < 2) return;
    int n_chunks = std::min(std::max(1, n_threads),
                            std::max(1, static_cast<int>(nn / 1000)));
    int64_t chunk_size = (nn + n_chunks - 1) / n_chunks;
    {
        std::vector<std::thread> ts;
        for (int t = 0; t < n_chunks; t++) {
            int64_t b = static_cast<int64_t>(t) * chunk_size;
            int64_t e = std::min(b + chunk_size, nn);
            if (b < e) ts.emplace_back([&v, b, e, &cmp]() {
                std::sort(v.begin() + b, v.begin() + e, cmp); });
        }
        for (auto &th : ts) th.join();
    }
    for (int64_t width = chunk_size; width < nn; width *= 2) {
        std::vector<std::thread> ts;
        for (int64_t left = 0; left < nn; left += 2 * width) {
            int64_t mid   = std::min(left + width,     nn);
            int64_t right = std::min(left + 2 * width, nn);
            if (mid < right) ts.emplace_back([&v, left, mid, right, &cmp]() {
                std::inplace_merge(v.begin() + left, v.begin() + mid,
                                   v.begin() + right, cmp); });
        }
        for (auto &th : ts) th.join();
    }
}

/* ── Write an already-key-sorted vector of MergeRecords as a run (.ckpt) ──── */
static void write_records_run(const std::vector<MergeRecord> &recs,
                              const fs::path &path) {
    fs::path tmp = path; tmp += ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary);
        write_checkpoint_header(f, static_cast<uint64_t>(recs.size()));
        f.write(reinterpret_cast<const char *>(recs.data()),
                static_cast<std::streamsize>(recs.size() * sizeof(MergeRecord)));
    }
    fs::rename(tmp, path);
}

static void process_file(const fs::path &input_path,
                         PolytopeMap &global_map,
                         std::mutex &global_mtx,
                         Stats &stats,
                         int n_threads,
                         GeometryBackendKind backend_kind,
                         int cuda_device,
                         int64_t max_rows = 0)
{
    /* Read all CWS from the parquet file */
    auto t0 = std::chrono::steady_clock::now();
    std::vector<CWSRow> rows = read_parquet_file(input_path, max_rows);
    double read_time = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();

    int64_t n = static_cast<int64_t>(rows.size());
    stats.total_cws.fetch_add(n, std::memory_order_relaxed);
    const bool nostore = bench_nostore();
    const bool nohash  = bench_nohash();

    std::cerr << "\n  " << input_path.filename().string()
              << ": " << n / 1'000'000.0 << "M rows, read in "
              << std::fixed << std::setprecision(1) << read_time << "s\n";

    /* ── Work distribution strategy ──────────────────────────────────────
     * Processing cost is dominated by point_count (Make_CWS_Points and
     * Find_Equations scale with # lattice points).  The input data has
     * a natural random distribution of point_counts, which provides
     * reasonable load balance across threads.  We use dynamic work-stealing
     * with small blocks so that if one thread hits an expensive polytope,
     * the others continue processing lighter ones from the shared queue. */
    bool cuda_or_auto = backend_kind != GeometryBackendKind::Cpu;
    int actual_threads = cuda_or_auto
        ? std::min(n_threads, static_cast<int>(n))
        : std::min(n_threads, (int)((n + 999) / 1000));
    int64_t block_size = cuda_or_auto ? 32 : 1024;

    int64_t n_blocks = (n + block_size - 1) / block_size;
    std::atomic<int64_t> next_block{0};

    /* Each thread gets its own workspace and local map */
    std::vector<std::future<void>> futures;
    std::vector<PolytopeMap> local_maps(actual_threads);

    /* Pre-reserve local maps based on expected unique polytope density */
    int64_t chunk_size = (n + actual_threads - 1) / actual_threads;
    for (auto &m : local_maps)
        m.reserve(std::min(chunk_size, (int64_t)1'000'000));

    ThreadPool pool(actual_threads);

    for (int t = 0; t < actual_threads; t++) {
        futures.push_back(pool.enqueue([&, t] {
            std::unique_ptr<GeometryBackend> backend =
                make_geometry_backend(backend_kind, cuda_device);
            std::vector<PalpNFResult> block_results(static_cast<std::size_t>(block_size));

            /* Dynamic work-stealing: grab next block from shared counter */
            for (;;) {
                int64_t b = next_block.fetch_add(1, std::memory_order_relaxed);
                if (b >= n_blocks) break;

                int64_t bstart = b * block_size;
                int64_t bend = std::min(bstart + block_size, n);
                int64_t block_count = bend - bstart;

                backend->compute_batch(&rows[bstart].cws, sizeof(CWSRow),
                                       static_cast<std::size_t>(block_count),
                                       block_results.data());

                for (int64_t i = bstart; i < bend; i++) {
                    const CWSRow &row = rows[i];
                    const PalpNFResult &result = block_results[static_cast<std::size_t>(i - bstart)];

                    if (!result.ok) {
                        stats.failed_cws.fetch_add(1, std::memory_order_relaxed);
                        stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }

                    if (nostore) {
                        if (!nohash) {
                            Hash128 k = hash_normal_form(result.nf, result.dim, result.nv);
                            g_bench_sink ^= k.lo;   /* defeat dead-code elimination */
                        }
                        stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }

                    Hash128 key = hash_normal_form(result.nf, result.dim, result.nv);

                    auto it = local_maps[t].find(key);
                    if (it != local_maps[t].end()) {
                        it->second.count++;
                        stats.duplicate_cws.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        PolytopeInfo info{};
                        info.count = 1;
                        fill_first_cws_info(info, row);
                        info.vertex_count     = static_cast<int16_t>(result.nv);
                        info.facet_count      = static_cast<int16_t>(result.ne);
                        info.point_count      = result.np;
                        info.dual_point_count = row.dual_point_count;
                        info.h11              = static_cast<int16_t>(row.h11);
                        info.h12              = static_cast<int16_t>(row.h12);
                        info.h13              = static_cast<int16_t>(row.h13);
                        local_maps[t].emplace(key, info);
                    }
                    stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }));
    }

    /* Wait for all threads and show progress periodically */
    bool all_done = false;
    while (!all_done) {
        all_done = true;
        for (auto &f : futures) {
            if (f.wait_for(std::chrono::milliseconds(500)) != std::future_status::ready)
                all_done = false;
        }
        stats.print_progress();
    }
    for (auto &f : futures) f.get();  /* propagate exceptions */

    /* Merge all local maps into global */
    for (auto &lm : local_maps) {
        merge_maps(global_map, lm, global_mtx, stats);
    }

    stats.files_done.fetch_add(1, std::memory_order_relaxed);
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Append-mode per-file processing → one sorted run (throughput path)
 *
 *  The compute loop appends {hash, row-index, geometry} sequentially instead
 *  of inserting into a per-thread hash map.  Sequential append is cache- and
 *  bandwidth-friendly (the random GB-scale hash-map inserts of process_file
 *  were the dominant scaling bottleneck — ~2.7x slower on a full socket).
 *  Dedup is deferred: after compute we sort by (hash, idx) and collapse equal
 *  hashes into one MergeRecord (representative = smallest row index, count =
 *  group size), then write a sorted run.  Output is byte-for-byte equivalent
 *  to the map path's run (same hash set + counts; representative is the first
 *  occurrence by row index, which is deterministic).
 * ═══════════════════════════════════════════════════════════════════════════ */

struct HashRec {
    Hash128 key;
    int64_t idx;      /* row index within this file (representative source)   */
    int16_t nv, ne;   /* vertex / facet counts from the PALP NF result        */
    int32_t np;       /* point count                                          */
};

/* Parallel collapse of a (hash,idx)-sorted HashRec array into deduped
   MergeRecords (one per equal-hash group; representative = smallest idx;
   count = group size).  Building the fat 320B records single-threaded was a
   big share of the append path's post-compute overhead.  Two passes (count
   groups per chunk → prefix-sum offsets → fill) split at group boundaries so
   chunks are independent and there is no intermediate copy (peak memory is
   just the output). */
static std::vector<MergeRecord> collapse_sorted(const std::vector<HashRec> &all,
                                                const std::vector<CWSRow> &rows,
                                                int n_threads) {
    size_t n = all.size();
    std::vector<MergeRecord> out;
    if (n == 0) return out;

    int nb = std::min(std::max(1, n_threads), std::max(1, (int)(n / 100000)));
    std::vector<size_t> starts(nb + 1);
    starts[0] = 0; starts[nb] = n;
    for (int k = 1; k < nb; k++) {
        size_t p = (size_t)((unsigned long long)k * n / (unsigned)nb);
        while (p > 0 && p < n && all[p].key == all[p - 1].key) p++;
        starts[k] = p;
    }
    for (int k = 1; k <= nb; k++)
        if (starts[k] < starts[k - 1]) starts[k] = starts[k - 1];

    auto count_groups = [&](size_t b, size_t e) {
        size_t g = 0;
        for (size_t i = b; i < e;) {
            size_t j = i + 1; while (j < e && all[j].key == all[i].key) j++;
            g++; i = j;
        }
        return g;
    };
    std::vector<size_t> gcount(nb, 0);
    {
        std::vector<std::thread> ts;
        for (int k = 0; k < nb; k++)
            ts.emplace_back([&, k] { gcount[k] = count_groups(starts[k], starts[k + 1]); });
        for (auto &t : ts) t.join();
    }
    std::vector<size_t> off(nb + 1, 0);
    for (int k = 0; k < nb; k++) off[k + 1] = off[k] + gcount[k];
    out.resize(off[nb]);

    auto fill = [&](int k) {
        size_t w = off[k];
        for (size_t i = starts[k]; i < starts[k + 1];) {
            size_t j = i + 1; while (j < starts[k + 1] && all[j].key == all[i].key) j++;
            const CWSRow &row = rows[all[i].idx];
            MergeRecord &rec = out[w++];
            rec = MergeRecord{};
            rec.key = all[i].key;
            PolytopeInfo &info = rec.info;
            info.count = static_cast<uint64_t>(j - i);
            fill_first_cws_info(info, row);
            info.vertex_count     = all[i].nv;
            info.facet_count      = all[i].ne;
            info.point_count      = all[i].np;
            info.dual_point_count = row.dual_point_count;
            info.h11 = static_cast<int16_t>(row.h11);
            info.h12 = static_cast<int16_t>(row.h12);
            info.h13 = static_cast<int16_t>(row.h13);
            i = j;
        }
    };
    {
        std::vector<std::thread> ts;
        for (int k = 0; k < nb; k++) ts.emplace_back(fill, k);
        for (auto &t : ts) t.join();
    }
    return out;
}

/* Read a file and produce its deduped, key-sorted run records (compute + sort
   + collapse).  The caller writes the run — typically on a background thread so
   the 8 GB run-write of file K overlaps the compute of file K+1. */
static std::vector<MergeRecord> build_run_records(
        const fs::path &input_path, Stats &stats, int n_threads,
        GeometryBackendKind backend_kind, int cuda_device, int64_t max_rows = 0)
{
    auto t0 = std::chrono::steady_clock::now();
    std::vector<CWSRow> rows = read_parquet_file(input_path, max_rows);
    double read_time = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();

    int64_t n = static_cast<int64_t>(rows.size());
    stats.total_cws.fetch_add(n, std::memory_order_relaxed);
    std::cerr << "\n  " << input_path.filename().string()
              << ": " << n / 1'000'000.0 << "M rows, read in "
              << std::fixed << std::setprecision(1) << read_time << "s\n";

    bool cuda_or_auto = backend_kind != GeometryBackendKind::Cpu;
    int actual_threads = cuda_or_auto
        ? std::min(n_threads, std::max(1, static_cast<int>(n)))
        : std::min(n_threads, std::max(1, (int)((n + 999) / 1000)));
    int64_t block_size = cuda_or_auto ? 32 : 1024;
    int64_t n_blocks = (n + block_size - 1) / block_size;
    std::atomic<int64_t> next_block{0};

    /* Per-thread append buffers (no shared structure in the hot loop). */
    std::vector<std::vector<HashRec>> tbufs(actual_threads);
    for (auto &v : tbufs)
        v.reserve(static_cast<size_t>(n / actual_threads) + 1024);

    ThreadPool pool(actual_threads);
    std::vector<std::future<void>> futures;
    for (int t = 0; t < actual_threads; t++) {
        futures.push_back(pool.enqueue([&, t] {
            std::unique_ptr<GeometryBackend> backend =
                make_geometry_backend(backend_kind, cuda_device);
            std::vector<PalpNFResult> block_results(static_cast<std::size_t>(block_size));
            std::vector<HashRec> &buf = tbufs[t];
            for (;;) {
                int64_t b = next_block.fetch_add(1, std::memory_order_relaxed);
                if (b >= n_blocks) break;
                int64_t bstart = b * block_size;
                int64_t bend = std::min(bstart + block_size, n);
                backend->compute_batch(&rows[bstart].cws, sizeof(CWSRow),
                                       static_cast<std::size_t>(bend - bstart),
                                       block_results.data());
                for (int64_t i = bstart; i < bend; i++) {
                    const PalpNFResult &res = block_results[static_cast<std::size_t>(i - bstart)];
                    if (!res.ok) {
                        stats.failed_cws.fetch_add(1, std::memory_order_relaxed);
                        stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }
                    Hash128 key = hash_normal_form(res.nf, res.dim, res.nv);
                    buf.push_back(HashRec{key, i, static_cast<int16_t>(res.nv),
                                          static_cast<int16_t>(res.ne),
                                          static_cast<int32_t>(res.np)});
                    stats.processed_cws.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }));
    }
    bool all_done = false;
    while (!all_done) {
        all_done = true;
        for (auto &f : futures)
            if (f.wait_for(std::chrono::milliseconds(500)) != std::future_status::ready)
                all_done = false;
        stats.print_progress();
    }
    for (auto &f : futures) f.get();

    /* Concatenate per-thread buffers. */
    size_t tot = 0; for (auto &v : tbufs) tot += v.size();
    std::vector<HashRec> all; all.reserve(tot);
    for (auto &v : tbufs) {
        all.insert(all.end(), v.begin(), v.end());
        std::vector<HashRec>().swap(v);   /* free promptly */
    }

    /* Sort by (hash, idx): groups equal hashes; idx tiebreak makes the
       representative deterministic (smallest row index). */
    parallel_sort_vec(all, [](const HashRec &a, const HashRec &b) {
        if (a.key.hi != b.key.hi) return a.key.hi < b.key.hi;
        if (a.key.lo != b.key.lo) return a.key.lo < b.key.lo;
        return a.idx < b.idx;
    }, n_threads);

    /* Collapse equal-hash groups into deduped MergeRecords (parallel). */
    std::vector<MergeRecord> out = collapse_sorted(all, rows, n_threads);
    std::cerr << "\n  Run: " << out.size() << " sorted entries (from "
              << n / 1'000'000.0 << "M rows)\n";
    stats.files_done.fetch_add(1, std::memory_order_relaxed);
    return out;
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  Get current RSS in bytes (Linux-specific)
 * ═══════════════════════════════════════════════════════════════════════════ */

static size_t get_rss_bytes() {
    std::ifstream f("/proc/self/statm");
    size_t pages;
    f >> pages;  /* total */
    f >> pages;  /* RSS in pages */
    return pages * sysconf(_SC_PAGESIZE);
}

/* ═══════════════════════════════════════════════════════════════════════════
 *  CLI and main
 * ═══════════════════════════════════════════════════════════════════════════ */

static void usage(const char *argv0) {
    std::cerr
        << "Usage: " << argv0 << "\n"
        << "  --input   <dir>   Directory containing ws-5d-*.parquet\n"
        << "  --output  <dir>   Output directory for results\n"
        << " [--non-reflexive] Input is non-reflexive IP WS: omit dual/Hodge columns\n"
        << " [--checkpoint <dir>] Directory for checkpoint files\n"
        << " [--offset <n>]    Global index offset for checkpoint file naming\n"
        << " [--threads <n>]   Thread count (default: hardware_concurrency)\n"
        << " [--backend <b>]   Geometry backend: cpu, cuda, or auto (default: cpu)\n"
        << " [--cuda-device n] CUDA device index for --backend cuda/auto (default: 0)\n"
        << " [--start <n>]     First file index (default: 0)\n"
        << " [--end <n>]       Last file index (inclusive, default: last)\n"
        << " [--resume]        Resume from checkpoint\n"
        << " [--assume-sorted] Skip Phase 1 sort (all shards already sorted)\n"
        << " [--max-rows <n>]  Limit rows processed per file (for testing)\n"
        << " [--benchmark <n>] Benchmark mode: process N rows from first file\n"
        << " [--spill-runs]    Per-file sorted-run mode: write an independent sorted\n"
        << "                   run per file (or --files-per-run batch) and reset the\n"
        << "                   map; bounded RAM, no global accumulation. Dedup via --merge.\n"
        << " [--runs-dir <d>]  Where to write spilled runs (default: checkpoint dir)\n"
        << " [--files-per-run n] Files accumulated per spilled run (default: 1)\n"
        << " [--run-tag <s>]   Filename prefix for run files (default: run)\n"
        << " [--merge <dir>]   Merge checkpoint/run shards from <dir>\n"
        << "\n"
        << "Examples:\n"
        << "  # Process all files\n"
        << "  " << argv0 << " --input ./data --output ./results\n"
        << "\n"
        << "  # Process files 0-99 on runner 1\n"
        << "  " << argv0 << " --input ./data --output ./results --start 0 --end 99\n"
        << "\n"
        << "  # Benchmark: process 100K rows\n"
        << "  " << argv0 << " --input ./data --output ./results --benchmark 100000\n";
}

int main(int argc, char **argv) {
    Config cfg;
    std::string merge_dir;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if      (a == "--input"       && i+1 < argc) cfg.input_dir      = argv[++i];
        else if (a == "--output"      && i+1 < argc) cfg.output_dir     = argv[++i];
        else if (a == "--checkpoint"  && i+1 < argc) cfg.checkpoint_dir  = argv[++i];
        else if (a == "--threads"     && i+1 < argc) cfg.n_threads      = std::stoi(argv[++i]);
        else if (a == "--backend"     && i+1 < argc) cfg.backend_kind   = parse_geometry_backend_kind(argv[++i]);
        else if (a == "--cuda-device" && i+1 < argc) cfg.cuda_device    = std::stoi(argv[++i]);
        else if (a == "--start"       && i+1 < argc) cfg.start_file     = std::stoi(argv[++i]);
        else if (a == "--end"         && i+1 < argc) cfg.end_file       = std::stoi(argv[++i]);
        else if (a == "--offset"      && i+1 < argc) cfg.name_offset    = std::stoi(argv[++i]);
        else if (a == "--resume")                     cfg.resume         = true;
        else if (a == "--assume-sorted")               cfg.assume_sorted  = true;
        else if (a == "--non-reflexive")               cfg.non_reflexive  = true;
        else if (a == "--max-rows"    && i+1 < argc) cfg.max_rows_per_file = std::stoll(argv[++i]);
        else if (a == "--spill-runs")                  cfg.spill_runs     = true;
        else if (a == "--runs-dir"      && i+1 < argc) cfg.runs_dir       = argv[++i];
        else if (a == "--files-per-run" && i+1 < argc) cfg.files_per_run  = std::stoi(argv[++i]);
        else if (a == "--run-tag"       && i+1 < argc) cfg.run_tag        = argv[++i];
        else if (a == "--benchmark"   && i+1 < argc) {
            cfg.benchmark_only = true;
            cfg.benchmark_rows = std::stoll(argv[++i]);
        }
        else if (a == "--merge"       && i+1 < argc) merge_dir          = argv[++i];
        else if (a == "-h" || a == "--help") { usage(argv[0]); return 0; }
        else { std::cerr << "Unknown option: " << a << "\n"; usage(argv[0]); return 1; }
    }

    /* ── Merge mode ──────────────────────────────────────────────────────── */
    if (!merge_dir.empty()) {
        if (cfg.output_dir.empty()) { usage(argv[0]); return 1; }
        if (cfg.n_threads <= 0)
            cfg.n_threads = static_cast<int>(std::thread::hardware_concurrency());
        std::vector<fs::path> shards;
        for (auto &e : fs::directory_iterator(merge_dir))
            if (e.path().extension() == ".ckpt") shards.push_back(e.path());
        std::sort(shards.begin(), shards.end());
        if (shards.empty()) { std::cerr << "No .ckpt files in " << merge_dir << "\n"; return 1; }
        fs::create_directories(cfg.output_dir);
        merge_checkpoints(shards, fs::path(cfg.output_dir) / "unique_polytopes.parquet",
                          cfg.n_threads, cfg.assume_sorted, cfg.non_reflexive);
        return 0;
    }

    if (cfg.input_dir.empty() || cfg.output_dir.empty()) {
        usage(argv[0]);
        return 1;
    }
    if (cfg.n_threads <= 0)
        cfg.n_threads = static_cast<int>(std::thread::hardware_concurrency());
    if (cfg.checkpoint_dir.empty())
        cfg.checkpoint_dir = cfg.output_dir + "/checkpoints";
    if (cfg.spill_runs) {
        if (cfg.runs_dir.empty()) cfg.runs_dir = cfg.checkpoint_dir;
        if (cfg.files_per_run < 1) cfg.files_per_run = 1;
        if (cfg.resume) {
            std::cerr << "  Note: --resume is ignored in --spill-runs mode "
                         "(each run is independent; dedup happens in --merge)\n";
            cfg.resume = false;
        }
    }

    if (cfg.backend_kind == GeometryBackendKind::Cuda) {
        std::string reason;
        if (!cuda_geometry_available(&reason)) {
            std::cerr << "CUDA backend unavailable: " << reason << "\n";
            return 1;
        }
    }

    std::string cuda_reason;
    bool cuda_visible = cuda_geometry_available(&cuda_reason);

    /* ── Initialize PALP ─────────────────────────────────────────────────── */
    palp_init();

    /* ── Collect input files ─────────────────────────────────────────────── */
    std::vector<fs::path> input_files;
    for (auto &e : fs::directory_iterator(cfg.input_dir))
        if (e.path().extension() == ".parquet")
            input_files.push_back(e.path());
    std::sort(input_files.begin(), input_files.end());

    if (input_files.empty()) {
        std::cerr << "No .parquet files in " << cfg.input_dir << "\n";
        return 1;
    }

    /* Apply file range filter */
    if (cfg.start_file >= 0) {
        int end = cfg.end_file >= 0 ? cfg.end_file + 1 : static_cast<int>(input_files.size());
        end = std::min(end, static_cast<int>(input_files.size()));
        input_files = std::vector<fs::path>(
            input_files.begin() + cfg.start_file,
            input_files.begin() + end);
    }

    if (cfg.benchmark_only) {
        /* In benchmark mode, only process the first file */
        input_files.resize(1);
    }

    fs::create_directories(cfg.output_dir);
    fs::create_directories(cfg.checkpoint_dir);
    if (cfg.spill_runs) fs::create_directories(cfg.runs_dir);

    std::cerr << "=== Polytope Classifier ===\n"
              << "Input:      " << cfg.input_dir << "\n"
              << "Output:     " << cfg.output_dir << "\n"
              << "Files:      " << input_files.size() << "\n"
              << "Threads:    " << cfg.n_threads << "\n"
              << "Backend:    " << geometry_backend_kind_name(cfg.backend_kind);
    if (cfg.backend_kind == GeometryBackendKind::Auto) {
        std::cerr << " (" << (cuda_visible ? "cuda visible" : "cpu fallback: " + cuda_reason) << ")";
    } else if (cfg.backend_kind == GeometryBackendKind::Cuda) {
        std::cerr << " device " << cfg.cuda_device;
    }
    std::cerr << "\n"
              << "CPU:        ";
    {
        std::ifstream cpuinfo("/proc/cpuinfo");
        std::string line;
        while (std::getline(cpuinfo, line))
            if (line.find("model name") != std::string::npos) {
                std::cerr << line.substr(line.find(':') + 2) << "\n";
                break;
            }
    }
    std::cerr << "RAM:        " << sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE)
                                   / (1024*1024*1024) << " GB\n\n";

    /* ── Global hash map ─────────────────────────────────────────────────── */
    PolytopeMap global_map;
    std::mutex global_mtx;

    /* Resume from checkpoint if requested */
    if (cfg.spill_runs) {
        /* Fresh start: remove any stale runs so restarting this file range is
           idempotent (every run is fully regenerated from its source files). */
        for (auto &e : fs::directory_iterator(cfg.runs_dir))
            if (e.path().extension() == ".ckpt") fs::remove(e.path());
    } else if (cfg.resume) {
        /* Load ALL .ckpt files from the checkpoint directory.  In a properly
           managed run there should be exactly one (the latest full snapshot),
           but we load all in case of manual checkpoint management. */
        for (auto &e : fs::directory_iterator(cfg.checkpoint_dir))
            if (e.path().extension() == ".ckpt")
                read_checkpoint(global_map, e.path());
    } else {
        /* Fresh start: clean any stale checkpoint files from previous runs
           to avoid disk accumulation and confusion during --resume later. */
        for (auto &e : fs::directory_iterator(cfg.checkpoint_dir)) {
            if (e.path().extension() == ".ckpt") {
                std::cerr << "  Removing old checkpoint: "
                          << e.path().filename().string() << "\n";
                fs::remove(e.path());
            }
        }
    }

    /* ── Main loop ───────────────────────────────────────────────────────── */
    Stats stats;
    stats.files_total = static_cast<int>(input_files.size());
    stats.start = std::chrono::steady_clock::now();
    stats.unique_polytopes.store(global_map.size());

    auto t_total = std::chrono::steady_clock::now();
    fs::path prev_checkpoint;   /* track previous checkpoint for cleanup */
    int runs_written = 0;       /* spilled runs (spill mode)                */
    std::thread run_writer;     /* background run-writer (spill mode): writes
                                   run K while file K+1 computes.  At most one
                                   outstanding write, so peak extra RAM is one
                                   run (~8 GB). */

    for (size_t fi = 0; fi < input_files.size(); fi++) {
        int64_t max_rows = (cfg.benchmark_only && cfg.benchmark_rows > 0)
                           ? cfg.benchmark_rows
                           : cfg.max_rows_per_file;

        int base = cfg.name_offset >= 0 ? cfg.name_offset
                 : cfg.start_file  >= 0 ? cfg.start_file : 0;
        int global_idx = base + static_cast<int>(fi);

        if (cfg.spill_runs) {
            /* Append-mode throughput path: each file → one independent SORTED
               run (append {hash,idx} in the hot loop, sort + collapse at the
               end).  No global map, peak RAM bounded to one file.  Cross-file
               and cross-node dedup are deferred to --merge.  The run-write is
               handed to a background thread so it overlaps the next file's
               compute (I/O-bound write vs CPU-bound compute). */
            char buf[80];
            std::snprintf(buf, sizeof(buf), "%s-%05d.ckpt",
                          cfg.run_tag.c_str(), global_idx);
            fs::path run_path = fs::path(cfg.runs_dir) / buf;
            std::vector<MergeRecord> recs = build_run_records(
                input_files[fi], stats, cfg.n_threads, cfg.backend_kind,
                cfg.cuda_device, max_rows);
            /* Ensure the previous run finished writing (bounds outstanding
               writes to one) before launching the next. */
            if (run_writer.joinable()) run_writer.join();
            size_t nrec = recs.size();
            run_writer = std::thread(
                [rp = std::move(run_path), rc = std::move(recs)]() mutable {
                    write_records_run(rc, rp);
                });
            runs_written++;
            size_t rss = get_rss_bytes();
            std::cerr << "  RSS: " << rss / (1024*1024) << " MB"
                      << "  run entries: " << nrec
                      << "  runs: " << runs_written << " (writing async)\n";
            continue;
        }

        process_file(input_files[fi], global_map, global_mtx, stats,
                 cfg.n_threads, cfg.backend_kind, cfg.cuda_device, max_rows);

        /* Memory monitoring */
        size_t rss = get_rss_bytes();
        std::cerr << "\n  RSS: " << rss / (1024*1024) << " MB"
                  << "  Map size: " << global_map.size() << "\n";

        if ((fi + 1) % 10 == 0 || fi == input_files.size() - 1) {
            /* Periodic checkpoint — each checkpoint is a FULL snapshot of the
               global map, so we only need to keep the latest one. */
            char buf[64];
            std::snprintf(buf, sizeof(buf), "checkpoint-%04d.ckpt", global_idx);
            fs::path ckpt_path = fs::path(cfg.checkpoint_dir) / buf;
            write_checkpoint(global_map, ckpt_path);

            /* Delete previous checkpoint — it is a strict subset of the
               one just written. */
            if (!prev_checkpoint.empty() && fs::exists(prev_checkpoint))
                fs::remove(prev_checkpoint);
            prev_checkpoint = ckpt_path;
        }
    }

    /* Ensure the last background run-write has completed. */
    if (run_writer.joinable()) run_writer.join();

    double total_secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_total).count();

    /* ── Spill-runs finalization ─────────────────────────────────────────── */
    if (cfg.spill_runs) {
        int64_t p = stats.processed_cws.load();
        int64_t f = stats.failed_cws.load();
        std::cerr << "\n\n=== Results (spill-runs) ===\n"
                  << "Total CWS processed:   " << p << "\n"
                  << "Failed:                " << f << "\n"
                  << "Runs written:          " << runs_written
                  << " → " << cfg.runs_dir << "\n"
                  << "Total time:            " << std::fixed << std::setprecision(1)
                  << total_secs << "s (" << total_secs / 60 << " min)\n"
                  << "Throughput:            " << std::setprecision(0)
                  << (total_secs > 0 ? p / total_secs : 0) << " CWS/s\n"
                  << "NOTE: cross-file/cross-node dedup deferred — run --merge over "
                  << cfg.runs_dir << " (with --assume-sorted; runs are pre-sorted).\n";
        fs::path summary_path = fs::path(cfg.output_dir) / "summary.json";
        std::ofstream sf(summary_path);
        sf << "{\n"
           << "  \"mode\": \"spill-runs\",\n"
           << "  \"total_cws\": " << p << ",\n"
           << "  \"failed_cws\": " << f << ",\n"
           << "  \"runs_written\": " << runs_written << ",\n"
           << "  \"total_seconds\": " << total_secs << ",\n"
           << "  \"throughput_cws_per_sec\": " << (total_secs > 0 ? p / total_secs : 0) << ",\n"
           << "  \"files_processed\": " << stats.files_done.load() << ",\n"
           << "  \"threads\": " << cfg.n_threads << "\n"
           << "}\n";
        std::cerr << "Done.\n";
        return 0;
    }

    /* ── Final output ────────────────────────────────────────────────────── */
    /* Accounting invariant check:
       Every CWS is either failed, within-thread duplicate, or creates a
       local map entry.  Every local map entry adds 1 to either unique or
       duplicate during merge.  So: processed == unique + dgplicate + failed. */
    {
        int64_t p = stats.processed_cws.load();
        int64_t u = static_cast<int64_t>(global_map.size());
        int64_t d = stats.duplicate_cws.load();
        int64_t f = stats.failed_cws.load();
        if (p != u + d + f) {
            std::cerr << "\n⚠ ACCOUNTING MISMATCH: processed(" << p
                      << ") != unique(" << u << ") + dup(" << d
                      << ") + fail(" << f << ") = " << (u + d + f)
                      << "  [diff=" << (p - u - d - f) << "]\n";
        }
    }

    std::cerr << "\n\n=== Results ===\n"
              << "Total CWS processed:   " << stats.processed_cws.load() << "\n"
              << "Failed:                " << stats.failed_cws.load() << "\n"
              << "Duplicate CWS:         " << stats.duplicate_cws.load() << "\n"
              << "Unique polytopes:      " << global_map.size() << "\n"
              << "Total time:            " << std::fixed << std::setprecision(1)
              << total_secs << "s (" << total_secs / 60 << " min)\n"
              << "Throughput:            " << std::setprecision(0)
              << stats.processed_cws.load() / total_secs << " CWS/s\n";

    /* Write final parquet */
    fs::path output_parquet = fs::path(cfg.output_dir) / "unique_polytopes.parquet";
    std::cerr << "\nWriting results to " << output_parquet.string() << " ...\n";
    write_results(global_map, output_parquet, cfg.non_reflexive);

    /* Write summary JSON */
    {
        fs::path summary_path = fs::path(cfg.output_dir) / "summary.json";
        std::ofstream sf(summary_path);
        sf << "{\n"
           << "  \"total_cws\": " << stats.processed_cws.load() << ",\n"
           << "  \"failed_cws\": " << stats.failed_cws.load() << ",\n"
           << "  \"duplicate_cws\": " << stats.duplicate_cws.load() << ",\n"
           << "  \"unique_polytopes\": " << global_map.size() << ",\n"
           << "  \"total_seconds\": " << total_secs << ",\n"
           << "  \"throughput_cws_per_sec\": " << stats.processed_cws.load() / total_secs << ",\n"
           << "  \"files_processed\": " << stats.files_done.load() << ",\n"
           << "  \"threads\": " << cfg.n_threads << ",\n"
           << "  \"backend\": \"" << geometry_backend_kind_name(cfg.backend_kind) << "\"\n"
           << "}\n";
    }

    std::cerr << "Done.\n";
    return 0;
}
