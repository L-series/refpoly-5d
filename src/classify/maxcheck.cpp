/**
 * maxcheck.cpp — fast-pass r-maximality worker over the reflexive catalogue.
 *
 * Streams a contiguous row-group range of unique_polytopes_clean.parquet and
 * classifies every polytope by PALP's exact r-maximality test
 * (palp_maxcheck.h → Poly_Max_check: P is r-maximal iff its dual P* is
 * r-minimal, i.e. P* has no proper reflexive subpolytope).  Output is three
 * append-only index streams, each record = (row_group:u32, row:u32):
 *
 *   .max    — provably r-MAXIMAL   (the deliverable; full record recovered
 *             later by joining these indices back to the source parquet)
 *   .nonmax — provably NOT maximal (compact index-only list)
 *   .defer  — NOT decided in this pass; must be re-run by the slow/robust pass
 *   .anom   — not a valid reflexive polytope (non-IP / non-reflexive / bad row)
 *
 * The union of the four streams over all rows is the full catalogue, so the
 * classification is provably complete: no polytope is ever silently dropped and
 * no verdict is ever guessed.  A DEFER is produced for, and only for, an item
 * this pass could not finish exactly:
 *
 *   (1) dual_point_count > --dpc-gate     deterministic size gate ("stop big
 *                                          ones fast"): the expensive tail is
 *                                          deferred without running the test.
 *   (2) the test exceeds --budget-ms       per-item wall-clock budget (SIGALRM).
 *   (3) the test overflows PALP's arrays    (MAXCHK_OVERFLOW).
 *   (4) the test crashes (e.g. deep-recursion stack overflow → SIGSEGV).
 *
 * Cases (2)/(4) cannot finish in-process without either a wrong answer or a
 * memory leak accumulating across rows, so the offending row is appended to a
 * *persistent* skip-set and the process exits; the supervisor
 * (scripts/slurm/maxcheck_worker.sh) restarts us, we truncate the output
 * streams back to the last checkpoint, replay from there, and DEFER every row
 * in the skip-set without re-testing it.  Each abort adds exactly one row to
 * the skip-set, so progress is guaranteed and every row lands in exactly one
 * stream.  Checkpoints (fsync + committed counts in the marker) bound the
 * replay window; an RSS cap forces a clean recycle so transient per-abort leaks
 * cannot grow without bound.
 *
 * Process-per-core / SLURM-array model: each invocation owns a row-group range
 * [--rg-start,--rg-end); the launcher fans the 2267 row groups across cores.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fcntl.h>
#include <unistd.h>
#include <csignal>
#include <csetjmp>
#include <sys/time.h>

#include <arrow/api.h>
#include <arrow/io/api.h>
#include <parquet/arrow/reader.h>

#include "palp_maxcheck.h"

#define ACHECK(expr)                                                       \
    do {                                                                   \
        auto _s = (expr);                                                  \
        if (!_s.ok()) {                                                    \
            std::fprintf(stderr, "%s:%d arrow error: %s\n", __FILE__,      \
                         __LINE__, _s.ToString().c_str());                 \
            std::exit(3);                                                  \
        }                                                                  \
    } while (0)

/* ── exit codes read by the supervisor ─────────────────────────────────── */
enum { EXIT_DONE = 0, EXIT_ABORT = 70, EXIT_RECYCLE = 72 };

/* ── append-only index stream: fixed 8-byte (rg,row) records ───────────── */
struct IdxStream {
    FILE  *fp = nullptr;
    char   path[1024];
    uint64_t n = 0;         /* records written since open (incl. buffered)  */
    void open(const std::string &p) {
        std::snprintf(path, sizeof path, "%s", p.c_str());
        fp = std::fopen(path, "r+b");           /* keep existing content    */
        if (!fp) fp = std::fopen(path, "w+b");
        if (!fp) { std::perror(path); std::exit(3); }
    }
    void put(uint32_t rg, uint32_t row) {
        uint32_t rec[2] = {rg, row};
        std::fwrite(rec, sizeof rec, 1, fp);
        n++;
    }
    void sync() { std::fflush(fp); ::fsync(fileno(fp)); }
    void truncate_to(uint64_t records) {         /* resume: drop uncommitted */
        std::fflush(fp);
        if (::ftruncate(fileno(fp), (off_t)records * 8) != 0) std::perror("ftruncate");
        std::fseek(fp, (long)records * 8, SEEK_SET);
        n = records;
    }
};

/* ── globals reachable from the SIGALRM / SIGSEGV handlers ──────────────── */
static volatile sig_atomic_t g_cur_rg  = 0;
static volatile sig_atomic_t g_cur_row = 0;
static int g_skip_fd = -1;          /* O_APPEND fd of the persistent skip-set */
static volatile sig_atomic_t g_in_test = 0;

/* Append the in-flight row to the skip-set and terminate.  write()/_exit are
   async-signal-safe; the skip-set is O_APPEND so the record is atomic. */
static void abort_current_row(void) {
    if (g_skip_fd >= 0) {
        uint32_t rec[2] = {(uint32_t)g_cur_rg, (uint32_t)g_cur_row};
        ssize_t w = ::write(g_skip_fd, rec, sizeof rec); (void)w;
    }
    _exit(EXIT_ABORT);
}
static void on_alarm(int) { if (g_in_test) abort_current_row(); _exit(EXIT_ABORT); }
static void on_segv(int)  { abort_current_row(); }

static long rss_kib(void) {
    FILE *f = std::fopen("/proc/self/statm", "r");
    if (!f) return 0;
    long pages = 0; if (std::fscanf(f, "%*s %ld", &pages) != 1) pages = 0;
    std::fclose(f);
    return pages * (sysconf(_SC_PAGESIZE) / 1024);
}

/* Persistent skip-set: (rg,row) rows to DEFER without testing on replay. */
static bool load_skip(const std::string &path, std::vector<uint64_t> &out) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    uint32_t rec[2];
    while (std::fread(rec, sizeof rec, 1, f) == 1)
        out.push_back(((uint64_t)rec[0] << 32) | rec[1]);
    std::fclose(f);
    return true;
}

/* Marker: last committed checkpoint + stream lengths, replayed on resume. */
struct Marker {
    int      com_rg = -1;               /* first not-yet-committed (rg,row)  */
    long long com_row = 0;
    uint64_t n_max = 0, n_nonmax = 0, n_defer = 0, n_anom = 0;
    void load(const std::string &p) {
        FILE *f = std::fopen(p.c_str(), "r");
        if (!f) return;
        if (std::fscanf(f, "%d %lld %llu %llu %llu %llu", &com_rg, &com_row,
                        (unsigned long long *)&n_max, (unsigned long long *)&n_nonmax,
                        (unsigned long long *)&n_defer, (unsigned long long *)&n_anom) != 6)
            com_rg = -1;
        std::fclose(f);
    }
    void store(const std::string &p) const {
        std::string tmp = p + ".tmp";
        FILE *f = std::fopen(tmp.c_str(), "w");
        if (!f) return;
        std::fprintf(f, "%d %lld %llu %llu %llu %llu\n", com_rg, com_row,
                     (unsigned long long)n_max, (unsigned long long)n_nonmax,
                     (unsigned long long)n_defer, (unsigned long long)n_anom);
        std::fflush(f); ::fsync(fileno(f)); std::fclose(f);
        std::rename(tmp.c_str(), p.c_str());
    }
};

int main(int argc, char **argv) {
    std::string in_path, work;
    int rg_start = 0, rg_end = -1;
    long dpc_gate = 2000;          /* deterministic size gate (dual points)  */
    long budget_ms = 1000;         /* per-item wall-clock budget             */
    long rss_cap_mb = 12000;       /* recycle the process above this RSS      */
    long checkpoint = 65536;       /* rows between fsync/marker checkpoints    */

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return std::string(argv[++i]); };
        if      (a == "--input")      in_path = next();
        else if (a == "--work")       work = next();          /* output/marker dir prefix */
        else if (a == "--rg-start")   rg_start = std::stoi(next());
        else if (a == "--rg-end")     rg_end = std::stoi(next());
        else if (a == "--dpc-gate")   dpc_gate = std::stol(next());
        else if (a == "--budget-ms")  budget_ms = std::stol(next());
        else if (a == "--rss-cap-mb") rss_cap_mb = std::stol(next());
        else if (a == "--checkpoint") checkpoint = std::stol(next());
        else { std::fprintf(stderr, "unknown arg: %s\n", a.c_str()); return 2; }
    }
    if (in_path.empty() || work.empty()) {
        std::fprintf(stderr,
            "usage: maxcheck --input IN.parquet --work PREFIX --rg-start N --rg-end N\n"
            "       [--dpc-gate 2000] [--budget-ms 1000] [--rss-cap-mb 12000]\n");
        return 2;
    }

    maxchk_init_io();
    MaxWorkspace *w = maxws_alloc();
    if (!w) { std::fprintf(stderr, "workspace alloc failed\n"); return 2; }

    const std::string marker_path = work + ".marker";
    const std::string skip_path   = work + ".skip";

    /* Persistent skip-set (never truncated): open for append (handlers) and
       load the current contents to DEFER on this replay. */
    g_skip_fd = ::open(skip_path.c_str(), O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (g_skip_fd < 0) { std::perror(skip_path.c_str()); return 3; }
    std::vector<uint64_t> skip_vec;
    load_skip(skip_path, skip_vec);

    IdxStream s_max, s_nonmax, s_defer, s_anom;
    s_max.open(work + ".max");   s_nonmax.open(work + ".nonmax");
    s_defer.open(work + ".defer"); s_anom.open(work + ".anom");

    /* Resume from the last checkpoint: truncate streams to committed lengths. */
    Marker mk; mk.load(marker_path);
    int resume_rg = rg_start; long long resume_row = 0;
    if (mk.com_rg >= 0) {
        s_max.truncate_to(mk.n_max);       s_nonmax.truncate_to(mk.n_nonmax);
        s_defer.truncate_to(mk.n_defer);   s_anom.truncate_to(mk.n_anom);
        resume_rg = mk.com_rg; resume_row = mk.com_row;
    } else {
        s_max.n = s_nonmax.n = s_defer.n = s_anom.n = 0;
    }

    /* Signal handlers: SIGALRM (budget) and SIGSEGV (deep-recursion overflow)
       both record the in-flight row in the skip-set and exit for a clean
       supervisor restart.  SIGSEGV needs an alternate stack (the main stack may
       be exhausted). */
    static char altstack[65536];
    stack_t ss{}; ss.ss_sp = altstack; ss.ss_size = sizeof altstack;
    sigaltstack(&ss, nullptr);
    struct sigaction sa{};
    sa.sa_handler = on_alarm; sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, nullptr);
    struct sigaction sv{};
    sv.sa_handler = on_segv; sigemptyset(&sv.sa_mask); sv.sa_flags = SA_ONSTACK;
    sigaction(SIGSEGV, &sv, nullptr);
    sigaction(SIGBUS, &sv, nullptr);

    arrow::MemoryPool *pool = arrow::default_memory_pool();
    std::shared_ptr<arrow::io::ReadableFile> infile;
    ACHECK(arrow::io::ReadableFile::Open(in_path, pool).Value(&infile));
    std::unique_ptr<parquet::arrow::FileReader> reader;
    ACHECK(parquet::arrow::OpenFile(infile, pool, &reader));
    int n_rg = reader->num_row_groups();
    if (rg_end < 0 || rg_end > n_rg) rg_end = n_rg;

    std::shared_ptr<arrow::Schema> schema;
    ACHECK(reader->GetSchema(&schema));
    int nf_idx  = schema->GetFieldIndex("nf");
    int dpc_idx = schema->GetFieldIndex("dual_point_count");
    if (nf_idx < 0 || dpc_idx < 0) {
        std::fprintf(stderr, "missing nf / dual_point_count column\n"); return 2;
    }
    std::vector<int> want = {nf_idx, dpc_idx};

    long long done_rows = 0, n_gate = 0, n_budget_replay = 0;

    for (int rg = resume_rg; rg < rg_end; rg++) {
        std::shared_ptr<arrow::Table> table;
        ACHECK(reader->ReadRowGroup(rg, want, &table));
        auto nf_ch  = table->column(0);
        auto dpc_ch = table->column(1);
        long long start_row = (rg == resume_rg) ? resume_row : 0;

        long long row = 0;
        for (int c = 0; c < nf_ch->num_chunks(); c++) {
            auto list = std::static_pointer_cast<arrow::ListArray>(nf_ch->chunk(c));
            auto vals = std::static_pointer_cast<arrow::Int32Array>(list->values());
            auto dpc  = std::static_pointer_cast<arrow::Int32Array>(dpc_ch->chunk(c));
            const int32_t *vraw = vals->raw_values();
            for (int64_t i = 0; i < list->length(); i++, row++) {
                if (row < start_row) continue;
                g_cur_rg = rg; g_cur_row = (int)row;

                /* Skip-set: rows a previous attempt could not finish → DEFER. */
                uint64_t key = ((uint64_t)rg << 32) | (uint32_t)row;
                bool skipped = false;
                for (uint64_t k : skip_vec) if (k == key) { skipped = true; break; }
                if (skipped) { s_defer.put(rg, row); n_budget_replay++; goto checkpoint; }

                {
                    int32_t off = list->value_offset(i);
                    int32_t len = list->value_length(i);
                    long dp = dpc->IsValid(i) ? dpc->Value(i) : 0;

                    if (len <= 0 || len % 5 != 0) { s_anom.put(rg, row); goto checkpoint; }
                    /* (1) deterministic size gate: defer the expensive tail. */
                    if (dpc_gate > 0 && dp > dpc_gate) { s_defer.put(rg, row); n_gate++; goto checkpoint; }

                    int nv = len / 5;
                    /* Arm the per-item wall-clock budget. */
                    itimerval it{}; it.it_value.tv_sec = budget_ms / 1000;
                    it.it_value.tv_usec = (budget_ms % 1000) * 1000;
                    g_in_test = 1; setitimer(ITIMER_REAL, &it, nullptr);
                    int code = palp_max_check(w, vraw + off, 5, nv);
                    itimerval z{}; setitimer(ITIMER_REAL, &z, nullptr); g_in_test = 0;

                    switch (code) {
                        case MAXCHK_REF_MAX:    s_max.put(rg, row);    break;
                        case MAXCHK_REF_NONMAX: s_nonmax.put(rg, row); break;
                        case MAXCHK_OVERFLOW:   s_defer.put(rg, row);  break;
                        default:                s_anom.put(rg, row);   break; /* NONREF/NOTIP/ERR */
                    }
                }

              checkpoint:
                done_rows++;
                if (done_rows % checkpoint == 0) {
                    s_max.sync(); s_nonmax.sync(); s_defer.sync(); s_anom.sync();
                    mk.com_rg = rg; mk.com_row = row + 1;
                    mk.n_max = s_max.n; mk.n_nonmax = s_nonmax.n;
                    mk.n_defer = s_defer.n; mk.n_anom = s_anom.n;
                    mk.store(marker_path);
                    if (rss_cap_mb > 0 && rss_kib() > rss_cap_mb * 1024) {
                        std::fprintf(stderr, "[rg %d row %lld] RSS cap hit — recycling\n", rg, row);
                        return EXIT_RECYCLE;
                    }
                }
            }
        }
        /* Row group complete: checkpoint at its boundary. */
        s_max.sync(); s_nonmax.sync(); s_defer.sync(); s_anom.sync();
        mk.com_rg = rg + 1; mk.com_row = 0;
        mk.n_max = s_max.n; mk.n_nonmax = s_nonmax.n;
        mk.n_defer = s_defer.n; mk.n_anom = s_anom.n;
        mk.store(marker_path);
        std::fprintf(stderr,
            "[rg %d/%d] done  max=%llu nonmax=%llu defer=%llu anom=%llu "
            "(gate=%lld replay=%lld)\n", rg, rg_end,
            (unsigned long long)s_max.n, (unsigned long long)s_nonmax.n,
            (unsigned long long)s_defer.n, (unsigned long long)s_anom.n,
            n_gate, n_budget_replay);
        std::fflush(stderr);
    }

    std::fprintf(stderr,
        "DONE rg[%d,%d) max=%llu nonmax=%llu defer=%llu anom=%llu gate=%lld replay=%lld\n",
        rg_start, rg_end, (unsigned long long)s_max.n, (unsigned long long)s_nonmax.n,
        (unsigned long long)s_defer.n, (unsigned long long)s_anom.n, n_gate, n_budget_replay);
    maxws_free(w);
    return EXIT_DONE;
}
