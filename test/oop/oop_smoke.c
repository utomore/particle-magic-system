/* oop_smoke.c -- the out-of-process load smoke (host-runtime F006, M8/I6).
 *
 * A pure C program. It links NO Haskell package: the only thing it knows
 * about this project at compile time is include/particle_magic.h, and the
 * only thing it knows at run time is a path to a shared library it opens
 * with LoadLibraryA / dlopen. Everything below is reached through a symbol
 * address, never through a link-time reference.
 *
 * Why it exists: the hspec suite calls Magic.FFI's functions as ordinary
 * Haskell functions inside a process whose RTS was already up. That is
 * blind to four things -- the export list (.def), the runtime start, the
 * exception firewall, and the shutdown semantics. This program is not.
 *
 *     oop-smoke <library> --list
 *     oop-smoke <library> --all [--spell PATH] [--golden PATH]
 *     oop-smoke <library> --probe NAME [--spell PATH] [--golden PATH]
 *
 * --all is the parent: it loads NOTHING and spawns one child per probe,
 * because two of the probes exist precisely to find out whether the
 * library still ends the calling process. The child's exit code is the
 * whole result (see PROBE_* below), so a probe that dies is a FAIL line
 * rather than a missing harness.
 *
 * The Linux build may additionally be given -DPM_OOP_WITH_RTS_HEADERS and
 * the GHC rts include directory. That pulls in Rts.h for the LAYOUT of
 * RTS_FLAGS only -- the pointer itself comes from dlsym on the loaded
 * library's dependency chain, so still not one Haskell symbol is linked.
 */

#if defined(PM_OOP_WITH_RTS_HEADERS)
/* Before everything: Rts.h wants to be the first thing a translation unit
   sees, exactly as cbits/pm_init.c has it. */
#include "Rts.h"
#endif

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#include "particle_magic.h"

/* --- the exit-code contract (F006 N1) ---------------------------------- */

#define PROBE_PASS 0
#define PROBE_FAIL 20 /* ran to the end, but an assertion did not hold   */
#define PROBE_SKIP 21 /* not applicable here (platform, or no poison lib) */
/* anything else, including a signal: the child did not survive.          */

#define OOP_FRAMES 120
#define OOP_DT (1.0f / 60.0f)
#define OOP_CAPACITY 16384
#define OOP_MAX_BATCHES 8
#define OOP_SEED 20260814ull

/* The reference platform for the committed goldens (test/GoldenPlatform.hs:
   `referencePlatform = os == "mingw32"`). */
#if defined(_WIN32)
#define OOP_REFERENCE_PLATFORM 1
#else
#define OOP_REFERENCE_PLATFORM 0
#endif

static const char *const PLATFORM_SCOPE_NOTE =
    "bit-for-bit goldens are a same-platform law (ADR-0016): recorded on "
    "windows/x86_64, and cross-platform the position columns may differ by "
    "a couple of ulp because libm's sin/cos are not correctly rounded.";

/* --- platform: loading and resolving ----------------------------------- */

#if defined(_WIN32)
typedef HMODULE oop_lib;
#define OOP_NULL_LIB ((HMODULE)0)
static oop_lib lib_open(const char *path) { return LoadLibraryA(path); }
static void *lib_sym(oop_lib h, const char *name)
{
    return (void *)(uintptr_t)GetProcAddress(h, name);
}
static void lib_why(char *buf, size_t n)
{
    snprintf(buf, n, "LoadLibrary error %lu", (unsigned long)GetLastError());
}
#else
typedef void *oop_lib;
#define OOP_NULL_LIB ((void *)0)
static oop_lib lib_open(const char *path) { return dlopen(path, RTLD_NOW); }
static void *lib_sym(oop_lib h, const char *name) { return dlsym(h, name); }
static void lib_why(char *buf, size_t n)
{
    const char *e = dlerror();
    snprintf(buf, n, "dlopen: %s", e ? e : "(no message)");
}
#endif

/* --- the shipped symbols ------------------------------------------------
 *
 * Every name under EXPORTS in particle-magic-ffi.def. Missing one is a
 * FAIL, which on Windows makes probe `load` a cross-process acceptance of
 * the export list itself -- FFIContractSpec can only compare texts.
 * test/OopSmokeSpec.hs keeps this array and the .def in step.
 */
static const char *const REQUIRED_SYMBOLS[] = {
    "pm_init",
    "pm_init_ex",
    "pm_shutdown",
    "pm_abi_version",
    "pm_cast",
    "pm_cast_ex",
    "pm_advance",
    "pm_advance_ex",
    "pm_is_finished",
    "pm_age",
    "pm_observe",
    "pm_observe_ex",
    "pm_free",
    "pm_max_particles",
    "pm_project",
    "pm_depth_order",
    "pm_scene_new",
    "pm_scene_free",
    "pm_scene_cast",
    "pm_scene_cast_many",
    "pm_scene_dismiss",
    "pm_scene_advance",
    "pm_scene_advance_ex",
    "pm_scene_observe",
    "pm_scene_budget",
    "pm_scene_count",
    "pm_scene_spells",
    "pm_spell_bounds",
    "pm_spell_box",
    "pm_emitter_count",
    "pm_emitter_box",
    "pm_occupancy",
    "pm_occupancy_mask",
    "pm_scene_spell_bounds",
    "pm_plan_steps",
    NULL};

/* --- function pointer types -------------------------------------------- */

typedef void (*fn_void_v)(void);
typedef int (*fn_int_v)(void);
typedef PmSpell *(*fn_cast)(const char *, const float *, const float *,
                            uint64_t, char *, int);
typedef void (*fn_advance)(PmSpell *, float);
typedef int (*fn_observe)(PmSpell *, float *, float *, float *, float *,
                          float *, uint32_t *, int, int *, int);
typedef double (*fn_age)(const PmSpell *);
typedef int (*fn_is_finished)(const PmSpell *);
typedef void (*fn_free)(PmSpell *);
typedef uint32_t (*fn_mask)(PmSpell *);
typedef int (*fn_bounds)(const PmSpell *, float *, float *);
typedef int (*fn_init_ex)(const PmConfig *);
typedef PmSpell *(*fn_poison)(void);

/* --- shared state of one probe run ------------------------------------- */

static oop_lib g_lib;
static const char *g_spell_path = "assets/spells/ring-fire.json";
static const char *g_golden_path = "examples/haskell/expected-output.txt";
static char g_note[512]; /* the child's one-line reason, printed on exit  */

static void note(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_note, sizeof g_note, fmt, ap);
    va_end(ap);
}

static void *need(const char *name)
{
    void *p = lib_sym(g_lib, name);
    if (!p) note("symbol %s did not resolve", name);
    return p;
}

/* Host-owned columns. Static rather than malloc'd so a probe that dies
   mid-way leaves nothing interesting behind. */
static float col_x[OOP_CAPACITY];
static float col_y[OOP_CAPACITY];
static float col_z[OOP_CAPACITY];
static float col_size[OOP_CAPACITY];
static float col_life[OOP_CAPACITY];
static uint32_t col_color[OOP_CAPACITY];
static int batch_info[OOP_MAX_BATCHES * PM_BATCH_INFO_STRIDE];

static char *read_whole_file(const char *path, long *out_len)
{
    FILE *f = fopen(path, "rb");
    long n;
    char *buf;
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    buf[n] = '\0';
    fclose(f);
    if (out_len) *out_len = n;
    return buf;
}

/* --- FNV-1a 64 over the little-endian bytes of each 32-bit word ---------
 * test/PerfGoldenSpec.hs:158-162 transcribed. Diagnostic only: it has no
 * recomputed golden of its own, so asserting it against a committed
 * constant would create a truth nobody maintains (F006 T5).
 */
static uint64_t fnv_start(void) { return 0xcbf29ce484222325ULL; }

static uint64_t fnv_word(uint64_t h, uint32_t w)
{
    int s;
    for (s = 0; s < 32; s += 8) {
        h ^= (uint64_t)((w >> s) & 0xFFu);
        h *= 0x100000001b3ULL;
    }
    return h;
}

static uint32_t float_bits(float f)
{
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

/* --- the golden's platform rule (test/ExampleHostSpec.hs:319-343) -------
 *
 * On the reference platform a line is compared character for character.
 * Elsewhere it is compared token by token: every non-numeric word and
 * every integer must still be identical -- that is the "particle count on
 * every platform" half of the contract card -- while the two decimal
 * columns (age, checksum) get the same relative tolerance the Haskell
 * spec uses. Skipping them instead would LOWER the coverage this harness
 * gives the non-reference platform, which is the opposite of the point.
 */
#define OOP_TOKEN_MAX 64
#define OOP_TOKEN_LEN 64

#if !OOP_REFERENCE_PLATFORM
static int tokenize(const char *line, char out[OOP_TOKEN_MAX][OOP_TOKEN_LEN])
{
    int n = 0;
    const char *p = line;
    while (*p && n < OOP_TOKEN_MAX) {
        int k = 0;
        while (*p && (*p == ' ' || *p == '\t' || *p == '(' || *p == ')' || *p == ',')) p++;
        if (!*p) break;
        while (*p && *p != ' ' && *p != '\t' && *p != '(' && *p != ')' && *p != ',') {
            if (k < OOP_TOKEN_LEN - 1) out[n][k++] = *p;
            p++;
        }
        out[n][k] = '\0';
        n++;
    }
    return n;
}

/* A decimal column: parses as a number AND is written with a point. The
   integer columns deliberately fall through to string equality. */
static int decimal_token(const char *t, double *v)
{
    char *end = NULL;
    double d;
    if (!strchr(t, '.')) return 0;
    d = strtod(t, &end);
    if (end == t || (end && *end != '\0')) return 0;
    *v = d;
    return 1;
}
#endif /* !OOP_REFERENCE_PLATFORM */

static int same_line(const char *actual, const char *expected)
{
#if OOP_REFERENCE_PLATFORM
    return strcmp(actual, expected) == 0;
#else
    char at[OOP_TOKEN_MAX][OOP_TOKEN_LEN];
    char et[OOP_TOKEN_MAX][OOP_TOKEN_LEN];
    int an = tokenize(actual, at);
    int en = tokenize(expected, et);
    int i;
    if (an != en) return 0;
    for (i = 0; i < an; ++i) {
        double x, y;
        if (decimal_token(at[i], &x) && decimal_token(et[i], &y)) {
            double ax = fabs(x), ay = fabs(y);
            double bound = 1e-5 * (1.0 + (ax > ay ? ax : ay));
            if (fabs(x - y) > bound) return 0;
        } else if (strcmp(at[i], et[i]) != 0) {
            return 0;
        }
    }
    return 1;
#endif
}

static void chomp(char *s)
{
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
}

/* --- probe: load -------------------------------------------------------- */

static int probe_load(void)
{
    int i, missing = 0;
    fn_int_v abi, maxp;
    fn_void_v init, shutdown;

    for (i = 0; REQUIRED_SYMBOLS[i]; ++i) {
        if (!lib_sym(g_lib, REQUIRED_SYMBOLS[i])) {
            if (missing == 0) note("missing shipped symbol %s", REQUIRED_SYMBOLS[i]);
            fprintf(stderr, "  missing: %s\n", REQUIRED_SYMBOLS[i]);
            missing++;
        }
    }
    if (missing > 0) {
        note("%d of %d shipped symbols did not resolve (first: see stderr)",
             missing, i);
        return PROBE_FAIL;
    }

    abi = (fn_int_v)need("pm_abi_version");
    maxp = (fn_int_v)need("pm_max_particles");
    init = (fn_void_v)need("pm_init");
    shutdown = (fn_void_v)need("pm_shutdown");
    if (!abi || !maxp || !init || !shutdown) return PROBE_FAIL;

    /* Before pm_init on purpose: the header promises a startup generation
       check is safe there (the C gate answers it directly). */
    if (abi() != PM_ABI_VERSION) {
        note("pm_abi_version() = %d, header says %d", abi(), PM_ABI_VERSION);
        return PROBE_FAIL;
    }

    init();
    if (maxp() <= 0) {
        note("pm_max_particles() = %d, expected a positive capacity", maxp());
        shutdown();
        return PROBE_FAIL;
    }
    note("%d shipped symbols resolved, abi %d, capacity %d", i, abi(), maxp());
    shutdown();
    return PROBE_PASS;
}

/* --- probe: life -------------------------------------------------------- */

/* One pass of the lifecycle, comparing against the golden. Shared by the
   `life` probe and by `rts-config`, which needs "and it still works". */
static int run_lifecycle(int compare_golden, uint64_t *out_digest,
                         int *out_max_particles)
{
    fn_void_v init = (fn_void_v)need("pm_init");
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_observe observe = (fn_observe)need("pm_observe");
    fn_age age = (fn_age)need("pm_age");
    fn_is_finished is_finished = (fn_is_finished)need("pm_is_finished");
    fn_free release = (fn_free)need("pm_free");
    fn_int_v maxp = (fn_int_v)need("pm_max_particles");

    const float caster_pos[3] = {1.5f, 0.25f, -2.0f};
    const float caster_facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    char *json;
    PmSpell *spell;
    FILE *golden = NULL;
    char gline[1024];
    char mine[1024];
    int frame, capacity, mismatches = 0, shown = 0;
    int max_particles_seen = 0, compared = 0;
    double last_checksum = 0.0;
    uint64_t digest = 0;

    if (!init || !shutdown || !cast || !advance || !observe || !age
        || !is_finished || !release || !maxp)
        return PROBE_FAIL;

    if (compare_golden) {
        golden = fopen(g_golden_path, "rb");
        if (!golden) {
            note("cannot open golden %s", g_golden_path);
            return PROBE_FAIL;
        }
        if (!fgets(gline, sizeof gline, golden)) { /* the "spell: ..." line */
            note("golden %s is empty", g_golden_path);
            fclose(golden);
            return PROBE_FAIL;
        }
    }

    capacity = maxp();
    if (capacity <= 0 || capacity > OOP_CAPACITY) {
        /* pm_max_particles is the live capacity; PM_MAX_PARTICLES is the
           frozen macro. The columns are sized from the query, as a host
           should, and OOP_CAPACITY is only the static ceiling here. */
        capacity = OOP_CAPACITY;
    }

    json = read_whole_file(g_spell_path, NULL);
    if (!json) {
        note("cannot read spell %s", g_spell_path);
        if (golden) fclose(golden);
        return PROBE_FAIL;
    }

    init();
    err[0] = '\0';
    spell = cast(json, caster_pos, caster_facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!spell) {
        note("pm_cast returned NULL: %s", err);
        if (golden) fclose(golden);
        shutdown();
        return PROBE_FAIL;
    }

    for (frame = 0; frame < OOP_FRAMES; ++frame) {
        int batches, b, total = 0;
        double checksum = 0.0;
        uint64_t h = fnv_start();

        advance(spell, OOP_DT);
        batches = observe(spell, col_x, col_y, col_z, col_size, col_life,
                          col_color, capacity, batch_info, OOP_MAX_BATCHES);
        if (batches < 0) {
            note("pm_observe returned %d on frame %d", batches, frame);
            if (golden) fclose(golden);
            release(spell);
            shutdown();
            return PROBE_FAIL;
        }

        /* Per batch, in batch order, exactly as PerfGoldenSpec.digestOf
           walks them: all of one batch's columns before the next batch. */
        for (b = 0; b < batches; ++b) {
            int off = batch_info[b * PM_BATCH_INFO_STRIDE + 0];
            int cnt = batch_info[b * PM_BATCH_INFO_STRIDE + 1];
            int i;
            if (off < 0 || cnt < 0 || off + cnt > capacity) {
                note("batch %d of frame %d is out of range (off %d, count %d)",
                     b, frame, off, cnt);
                if (golden) fclose(golden);
                release(spell);
                shutdown();
                return PROBE_FAIL;
            }
            total += cnt;
            for (i = off; i < off + cnt; ++i)
                checksum += (double)col_x[i] + (double)col_y[i] + (double)col_z[i]
                            + (double)col_size[i] + (double)col_life[i];
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, float_bits(col_x[i]));
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, float_bits(col_y[i]));
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, float_bits(col_z[i]));
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, float_bits(col_size[i]));
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, float_bits(col_life[i]));
            for (i = off; i < off + cnt; ++i) h = fnv_word(h, col_color[i]);
        }
        if (total > max_particles_seen) max_particles_seen = total;
        last_checksum = checksum;
        digest = h;

        snprintf(mine, sizeof mine,
                 "frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f",
                 frame, age(spell), batches, total,
                 batches > 0 ? batch_info[2] : -1, checksum);

        if (golden) {
            if (!fgets(gline, sizeof gline, golden)) {
                note("golden ran out at frame %d -- expected %d frames",
                     frame, OOP_FRAMES);
                fclose(golden);
                release(spell);
                shutdown();
                return PROBE_FAIL;
            }
            chomp(gline);
            compared++;
            if (!same_line(mine, gline)) {
                mismatches++;
                if (shown < 3) {
                    fprintf(stderr, "  frame %d differs\n    golden: %s\n    mine  : %s\n",
                            frame, gline, mine);
                    shown++;
                }
            }
        }
    }

    if (golden) {
        snprintf(mine, sizeof mine, "finished: %d", is_finished(spell));
        if (!fgets(gline, sizeof gline, golden)) {
            note("golden has no 'finished:' line");
            fclose(golden);
            release(spell);
            shutdown();
            return PROBE_FAIL;
        }
        chomp(gline);
        compared++;
        if (!same_line(mine, gline)) {
            mismatches++;
            fprintf(stderr, "  finished line differs\n    golden: %s\n    mine  : %s\n",
                    gline, mine);
        }
        fclose(golden);
    }

    release(spell);
    shutdown();

    if (out_digest) *out_digest = digest;
    if (out_max_particles) *out_max_particles = max_particles_seen;

    /* Anti-false-green. This spell starts empty (the golden's frame 0 has
       `particles 0`), so "every line matched" is worth nothing unless the
       run actually produced particles and actually compared 121 lines. */
    if (max_particles_seen <= 0) {
        note("no frame produced a single particle -- the comparison would be vacuous");
        return PROBE_FAIL;
    }
    if (last_checksum == 0.0) {
        note("the last frame's checksum is exactly zero -- nothing was sampled");
        return PROBE_FAIL;
    }
    if (compare_golden && compared != OOP_FRAMES + 1) {
        note("compared %d lines, expected %d", compared, OOP_FRAMES + 1);
        return PROBE_FAIL;
    }

    if (mismatches > 0) {
        note("%d of %d golden lines differ (peak %d particles). %s",
             mismatches, compared, max_particles_seen,
             OOP_REFERENCE_PLATFORM ? "This IS the reference platform."
                                    : PLATFORM_SCOPE_NOTE);
        return PROBE_FAIL;
    }
    return PROBE_PASS;
}

static int probe_life(void)
{
    uint64_t digest = 0;
    int peak = 0;
    int rc = run_lifecycle(1, &digest, &peak);
    if (rc == PROBE_PASS)
        note("%d frames + finished line match the golden, peak %d particles, "
             "digest=%llu",
             OOP_FRAMES, peak, (unsigned long long)digest);
    return rc;
}

/* --- the state probes (C2.5, the I3 gate) -------------------------------
 *
 * Before host-runtime F003 these three ENDED the calling process from
 * inside the RTS ("newBoundTask: RTS is not initialised"). That is why
 * every probe runs in a child. The gate is landed now, so the expected
 * answer is the sentinel table; `gate_landed()` keeps the pre-gate branch
 * honest rather than assuming, and the parent turns "not landed" into
 * PENDING instead of a failure.
 */
static int gate_landed(void) { return lib_sym(g_lib, "pm_init_ex") != NULL; }

/* One representative per sentinel shape in the header's table. The whole
   29-symbol table is FFIRuntimeSpec's job, in process. */
static int sample_sentinels(const char *when)
{
    fn_int_v maxp = (fn_int_v)need("pm_max_particles");
    fn_int_v abi = (fn_int_v)need("pm_abi_version");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_age age = (fn_age)need("pm_age");
    fn_mask mask = (fn_mask)need("pm_occupancy_mask");
    const float pos[3] = {0.0f, 0.0f, 0.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    int v;
    double a;
    PmSpell *s;
    size_t i, len;

    if (!maxp || !abi || !cast || !advance || !age || !mask) return PROBE_FAIL;

    /* returns a count or a code */
    v = maxp();
    if (v != PM_ERR_STATE) {
        note("%s: pm_max_particles() = %d, expected PM_ERR_STATE (%d)",
             when, v, PM_ERR_STATE);
        return PROBE_FAIL;
    }

    /* returns a handle, and says why */
    memset(err, 0xAB, sizeof err);
    err[sizeof err - 1] = '\0';
    s = cast("{}", pos, facing, OOP_SEED, err, (int)sizeof err);
    if (s != NULL) {
        note("%s: pm_cast returned a handle, expected NULL", when);
        return PROBE_FAIL;
    }
    len = strnlen(err, sizeof err);
    if (len == 0 || len >= sizeof err) {
        note("%s: pm_cast left no NUL-terminated reason in err_buf", when);
        return PROBE_FAIL;
    }
    for (i = 0; i < len; ++i) {
        if ((unsigned char)err[i] < 0x20 || (unsigned char)err[i] > 0x7E) {
            note("%s: pm_cast's reason is not printable ASCII at byte %u",
                 when, (unsigned)i);
            return PROBE_FAIL;
        }
    }

    /* returns void: must simply come back */
    advance(NULL, OOP_DT);

    /* returns a double */
    a = age(NULL);
    if (!(a == (double)PM_ERR_STATE)) {
        note("%s: pm_age() = %f, expected %f", when, a, (double)PM_ERR_STATE);
        return PROBE_FAIL;
    }

    /* returns a bit set: fail-safe zero */
    if (mask(NULL) != 0u) {
        note("%s: pm_occupancy_mask() = %u, expected 0", when, mask(NULL));
        return PROBE_FAIL;
    }

    /* the one symbol the gate does not close */
    if (abi() != PM_ABI_VERSION) {
        note("%s: pm_abi_version() = %d, expected %d (it must answer in every state)",
             when, abi(), PM_ABI_VERSION);
        return PROBE_FAIL;
    }
    return PROBE_PASS;
}

static int probe_state_uninit(void)
{
    int rc;
    if (!gate_landed()) {
        /* Reaching the RTS here is what used to end the process. Do it on
           purpose: if the process survives without the gate, the state
           machine changed behind our back and somebody should look. */
        fn_int_v maxp = (fn_int_v)need("pm_max_particles");
        if (!maxp) return PROBE_FAIL;
        fprintf(stderr, "  no pm_init_ex: calling into an unstarted runtime\n");
        (void)maxp();
        note("survived a pre-init call with no I3 gate present");
        return PROBE_FAIL;
    }
    rc = sample_sentinels("before pm_init");
    if (rc == PROBE_PASS) note("every sampled symbol answered its UNINIT sentinel");
    return rc;
}

static int probe_state_after_shutdown(void)
{
    fn_void_v init = (fn_void_v)need("pm_init");
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_observe observe = (fn_observe)need("pm_observe");
    fn_free release = (fn_free)need("pm_free");
    const float pos[3] = {1.5f, 0.25f, -2.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    char *json;
    PmSpell *spell;
    int rc, batches;

    if (!init || !shutdown || !cast || !advance || !observe || !release)
        return PROBE_FAIL;
    if (!gate_landed()) {
        fprintf(stderr, "  no pm_init_ex: calling into a stopped runtime\n");
        init();
        shutdown();
        (void)((fn_int_v)need("pm_max_particles"))();
        note("survived a post-shutdown call with no I3 gate present");
        return PROBE_FAIL;
    }

    /* Prove the library was good before it was closed, so a PASS below is
       "shutdown closed it" and not "it never worked". */
    json = read_whole_file(g_spell_path, NULL);
    if (!json) { note("cannot read spell %s", g_spell_path); return PROBE_FAIL; }
    init();
    err[0] = '\0';
    spell = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!spell) { note("pm_cast failed before shutdown: %s", err); return PROBE_FAIL; }
    advance(spell, OOP_DT);
    batches = observe(spell, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    if (batches < 0) {
        note("pm_observe failed before shutdown: %d", batches);
        return PROBE_FAIL;
    }
    release(spell);
    shutdown();

    rc = sample_sentinels("after pm_shutdown");
    if (rc != PROBE_PASS) return rc;

    /* Idempotent, as examples/c/main.c already assumes. */
    shutdown();
    rc = sample_sentinels("after a second pm_shutdown");
    if (rc == PROBE_PASS)
        note("the library worked, then answered CLOSED sentinels; "
             "pm_shutdown is idempotent");
    return rc;
}

static int probe_state_reinit(void)
{
    fn_void_v init = (fn_void_v)need("pm_init");
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_init_ex init_ex;
    PmConfig cfg;
    int rc;

    if (!init || !shutdown) return PROBE_FAIL;
    if (!gate_landed()) {
        note("pm_init_ex is not exported: the one-way door has no observable answer");
        return PROBE_FAIL;
    }
    init_ex = (fn_init_ex)need("pm_init_ex");
    if (!init_ex) return PROBE_FAIL;

    init();
    shutdown();

    /* A no-op, per the header: it must not restart anything and must not
       end this process. Surviving the next line is half the assertion. */
    init();

    memset(&cfg, 0, sizeof cfg);
    cfg.size = (uint32_t)sizeof cfg;
    cfg.capabilities = 1;
    rc = init_ex(&cfg);
    if (rc != PM_ERR_STATE) {
        note("pm_init_ex after pm_shutdown = %d, expected PM_ERR_STATE (%d)",
             rc, PM_ERR_STATE);
        return PROBE_FAIL;
    }
    if (sample_sentinels("after pm_init on a closed library") != PROBE_PASS)
        return PROBE_FAIL;
    note("the door is one-way: pm_init is a no-op and pm_init_ex answers PM_ERR_STATE");
    return PROBE_PASS;
}

/* --- probe: rts-config (C1.5) ------------------------------------------- */

#define OOP_WANT_CAPABILITIES 2u
#define OOP_WANT_NURSERY (64ull * 1024ull * 1024ull)

#ifndef BLOCK_SIZE
#define OOP_BLOCK_SIZE 4096u
#else
#define OOP_BLOCK_SIZE ((uint32_t)BLOCK_SIZE)
#endif

/* Everything below reads the RTS through dlsym on the library's dependency
   chain. Windows exports none of it (the .def closes the export face), so
   there the settings are asserted only by "pm_init_ex said PM_OK and the
   library then worked" -- and the difference is printed, not swallowed. */
static int assert_rts_settings(int want_stats, char *why, size_t why_len)
{
#if defined(_WIN32)
    (void)want_stats;
    snprintf(why, why_len,
             "RTS symbols are not exported on this platform (.def); "
             "asserted PM_OK and a working lifecycle only");
    return PROBE_SKIP;
#else
    uint32_t *n_capabilities = (uint32_t *)lib_sym(g_lib, "n_capabilities");
    int (*stats_enabled)(void) = (int (*)(void))lib_sym(g_lib, "getRTSStatsEnabled");
    int checked = 0;

    if (!n_capabilities) {
        snprintf(why, why_len, "n_capabilities did not resolve through the library");
        return PROBE_FAIL;
    }
    if (*n_capabilities != OOP_WANT_CAPABILITIES) {
        snprintf(why, why_len, "n_capabilities = %u, asked for %u",
                 (unsigned)*n_capabilities, (unsigned)OOP_WANT_CAPABILITIES);
        return PROBE_FAIL;
    }
    checked++;

    if (!stats_enabled) {
        snprintf(why, why_len, "getRTSStatsEnabled did not resolve");
        return PROBE_FAIL;
    }
    if (want_stats && !stats_enabled()) {
        snprintf(why, why_len,
                 "getRTSStatsEnabled() is false after PM_STATS_ON");
        return PROBE_FAIL;
    }
    if (!want_stats && stats_enabled()) {
        snprintf(why, why_len,
                 "getRTSStatsEnabled() is true although statistics were not asked for");
        return PROBE_FAIL;
    }
    checked++;

#if defined(PM_OOP_WITH_RTS_HEADERS)
    {
        RTS_FLAGS *flags = (RTS_FLAGS *)lib_sym(g_lib, "RtsFlags");
        uint32_t want_blocks = (uint32_t)(OOP_WANT_NURSERY / OOP_BLOCK_SIZE);
        if (!flags) {
            snprintf(why, why_len, "RtsFlags did not resolve through the library");
            return PROBE_FAIL;
        }
        if (flags->GcFlags.minAllocAreaSize != want_blocks) {
            snprintf(why, why_len,
                     "minAllocAreaSize = %u blocks, asked for %u (%u bytes / %u)",
                     (unsigned)flags->GcFlags.minAllocAreaSize,
                     (unsigned)want_blocks, (unsigned)OOP_WANT_NURSERY,
                     (unsigned)OOP_BLOCK_SIZE);
            return PROBE_FAIL;
        }
        checked++;
        if (!flags->GcFlags.useNonmoving) {
            snprintf(why, why_len, "useNonmoving is false after PM_GC_NONMOVING");
            return PROBE_FAIL;
        }
        checked++;
        snprintf(why, why_len,
                 "%d RTS settings verified in the runtime (caps, stats, nursery, gc)",
                 checked);
    }
#else
    snprintf(why, why_len,
             "%d RTS settings verified (caps, stats); nursery and gc need "
             "Rts.h -- rebuild with PM_OOP_WITH_RTS_HEADERS",
             checked);
#endif
    return PROBE_PASS;
#endif
}

static int probe_rts_config(void)
{
    fn_init_ex init_ex;
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_observe observe = (fn_observe)need("pm_observe");
    fn_free release = (fn_free)need("pm_free");
    PmConfig cfg;
    char why[320];
    const float pos[3] = {1.5f, 0.25f, -2.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    char *json;
    PmSpell *spell;
    int rc, batches, sub;
    int want_stats = 1;

    if (!gate_landed()) {
        note("pm_init_ex is not exported (host-runtime F003 not landed)");
        return PROBE_FAIL;
    }
    init_ex = (fn_init_ex)need("pm_init_ex");
    if (!init_ex || !shutdown || !cast || !advance || !observe || !release)
        return PROBE_FAIL;

    memset(&cfg, 0, sizeof cfg);
    cfg.size = (uint32_t)sizeof cfg;
    cfg.capabilities = OOP_WANT_CAPABILITIES;
    cfg.nursery_bytes = OOP_WANT_NURSERY;
    cfg.gc_mode = PM_GC_NONMOVING;
#if defined(PM_OOP_HAS_RTS_STATS)
    cfg.stats = PM_STATS_ON;
#else
    want_stats = 0;
#endif

    rc = init_ex(&cfg);
    if (rc != PM_OK) {
        note("pm_init_ex = %d, expected PM_OK -- this process started the runtime",
             rc);
        return PROBE_FAIL;
    }

    /* The settings are worth nothing if the library stopped working. */
    json = read_whole_file(g_spell_path, NULL);
    if (!json) { note("cannot read spell %s", g_spell_path); shutdown(); return PROBE_FAIL; }
    err[0] = '\0';
    spell = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!spell) { note("pm_cast failed under the custom config: %s", err); shutdown(); return PROBE_FAIL; }
    advance(spell, OOP_DT);
    batches = observe(spell, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    release(spell);
    if (batches < 0) {
        note("pm_observe = %d under the custom config", batches);
        shutdown();
        return PROBE_FAIL;
    }

    sub = assert_rts_settings(want_stats, why, sizeof why);
    shutdown();
    if (sub == PROBE_FAIL) { note("%s", why); return PROBE_FAIL; }
    note("%s", why);
    return sub; /* PASS, or SKIP with the platform's reason */
}

/* --- probe: rts-prestarted (the "runtime was already up" row) ------------
 *
 * The header's table has a row in-process tests cannot reach and the
 * shipped path cannot reach either: a host whose GHC runtime was ALREADY
 * running before pm_init_ex was called. Then capabilities still take
 * effect, nursery / gc / stats cannot, and pm_init_ex says so with
 * PM_ERR_STATE while leaving the library up and usable.
 *
 * This harness is the only test that can control the runtime's start, so
 * it stands the row up: hs_init through the SAME dlsym chain, then
 * pm_init_ex. Windows exports no RTS symbol, so there it is a SKIP.
 */
static int probe_rts_prestarted(void)
{
#if defined(_WIN32)
    note("hs_init is not exported on this platform (.def); "
         "the pre-started-runtime row cannot be stood up here");
    return PROBE_SKIP;
#else
    void (*hs_init_fn)(int *, char ***) =
        (void (*)(int *, char ***))lib_sym(g_lib, "hs_init");
    int (*stats_enabled)(void) = (int (*)(void))lib_sym(g_lib, "getRTSStatsEnabled");
    uint32_t *n_capabilities = (uint32_t *)lib_sym(g_lib, "n_capabilities");
    fn_init_ex init_ex;
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_observe observe = (fn_observe)need("pm_observe");
    fn_free release = (fn_free)need("pm_free");
    static char argv0[] = "oop-smoke";
    static char *argv_[] = {argv0, NULL};
    char **pargv = argv_;
    int argc_ = 1;
    PmConfig cfg;
    const float pos[3] = {1.5f, 0.25f, -2.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    char *json;
    PmSpell *spell;
    int rc, batches;

    if (!gate_landed()) {
        note("pm_init_ex is not exported (host-runtime F003 not landed)");
        return PROBE_FAIL;
    }
    if (!hs_init_fn || !stats_enabled || !n_capabilities) {
        note("hs_init / getRTSStatsEnabled / n_capabilities did not resolve");
        return PROBE_SKIP;
    }
    init_ex = (fn_init_ex)need("pm_init_ex");
    if (!init_ex || !shutdown || !cast || !advance || !observe || !release)
        return PROBE_FAIL;

    /* Be the Haskell host: start the runtime before the library is asked
       to. No statistics are requested here, which is the point -- they can
       only be turned on while the runtime starts. */
    hs_init_fn(&argc_, &pargv);
    if (stats_enabled()) {
        note("the runtime came up with statistics already enabled; "
             "this probe cannot tell the two cases apart");
        return PROBE_SKIP;
    }

    memset(&cfg, 0, sizeof cfg);
    cfg.size = (uint32_t)sizeof cfg;
    cfg.capabilities = OOP_WANT_CAPABILITIES;
    cfg.nursery_bytes = OOP_WANT_NURSERY;
    cfg.gc_mode = PM_GC_NONMOVING;
    cfg.stats = PM_STATS_ON;

    rc = init_ex(&cfg);
    if (rc != PM_ERR_STATE) {
        note("pm_init_ex on an already-running runtime = %d, expected "
             "PM_ERR_STATE (%d) in its second sense",
             rc, PM_ERR_STATE);
        return PROBE_FAIL;
    }
    if (stats_enabled()) {
        note("getRTSStatsEnabled() is true, but nothing could have turned it on");
        return PROBE_FAIL;
    }
    if (*n_capabilities != OOP_WANT_CAPABILITIES) {
        note("n_capabilities = %u, but the capability count is the one "
             "setting that still applies on this row",
             (unsigned)*n_capabilities);
        return PROBE_FAIL;
    }

    /* "up and usable": PM_ERR_STATE here is a report, not a refusal. */
    json = read_whole_file(g_spell_path, NULL);
    if (!json) { note("cannot read spell %s", g_spell_path); return PROBE_FAIL; }
    err[0] = '\0';
    spell = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!spell) {
        note("pm_cast failed although pm_init_ex reported the library was up: %s",
             err);
        return PROBE_FAIL;
    }
    advance(spell, OOP_DT);
    batches = observe(spell, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    release(spell);
    if (batches < 0) {
        note("pm_observe = %d although the library reported itself up", batches);
        return PROBE_FAIL;
    }
    shutdown();
    note("runtime already up: pm_init_ex reported PM_ERR_STATE, capabilities "
         "applied, statistics correctly unavailable, library usable");
    return PROBE_PASS;
#endif
}

/* --- probe: rts-prestarted-zero-caps (host-runtime B002) ------------------
 *
 * The same row as rts-prestarted, asked the way the header tells a host to
 * ask: zero PmConfig, set `size`, fill in nothing you do not care about.
 * That leaves capabilities at 0, which the header defines as "follow the
 * hardware" -- a request like any other, and the one field this row still
 * has an API to honour.
 *
 * B002 was exactly here: 0 was read as "the host said nothing", so the
 * request was neither applied nor counted into PM_ERR_STATE. Silently
 * dropped, which C2.4 forbids.
 *
 * It needs a process of its own -- the state machine allows one
 * initialisation per process, so the sibling probe's non-zero request
 * cannot share one -- and that is what --all already gives every probe.
 * Windows exports no RTS symbol, so there it is a SKIP; Linux is the only
 * platform where n_capabilities can be read back through dlsym.
 */
static int probe_rts_prestarted_zero_caps(void)
{
#if defined(_WIN32)
    note("hs_init / n_capabilities are not exported on this platform (.def); "
         "the zero-capability request cannot be observed here");
    return PROBE_SKIP;
#else
    void (*hs_init_fn)(int *, char ***) =
        (void (*)(int *, char ***))lib_sym(g_lib, "hs_init");
    uint32_t *n_capabilities = (uint32_t *)lib_sym(g_lib, "n_capabilities");
    uint32_t (*processors)(void) =
        (uint32_t (*)(void))lib_sym(g_lib, "getNumberOfProcessors");
    fn_init_ex init_ex;
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_free release = (fn_free)need("pm_free");
    static char argv0[] = "oop-smoke";
    static char *argv_[] = {argv0, NULL};
    char **pargv = argv_;
    int argc_ = 1;
    PmConfig cfg;
    const float pos[3] = {1.5f, 0.25f, -2.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    char err[512];
    char *json;
    PmSpell *spell;
    uint32_t before, want;
    int rc;

    if (!gate_landed()) {
        note("pm_init_ex is not exported (host-runtime F003 not landed)");
        return PROBE_FAIL;
    }
    if (!hs_init_fn || !n_capabilities) {
        note("hs_init / n_capabilities did not resolve");
        return PROBE_SKIP;
    }
    init_ex = (fn_init_ex)need("pm_init_ex");
    if (!init_ex || !shutdown || !cast || !release) return PROBE_FAIL;

    /* Be the Haskell host. hs_init takes no RTS options, so the runtime
       comes up at the runtime's own default of one capability -- which is
       what makes "follow the hardware" observable at all. */
    hs_init_fn(&argc_, &pargv);
    before = *n_capabilities;
    want = processors ? processors() : 0;
    if (want != 0 && before >= want) {
        note("the pre-started runtime already has %u capabilities and the "
             "machine has %u: this probe cannot tell the two cases apart",
             (unsigned)before, (unsigned)want);
        return PROBE_SKIP;
    }

    /* The documented default way to write a config, and nothing else. */
    memset(&cfg, 0, sizeof cfg);
    cfg.size = (uint32_t)sizeof cfg;

    rc = init_ex(&cfg);
    /* Nothing in this config is a field the row cannot honour, so there is
       no degradation to report: PM_ERR_STATE here would mean the library
       refused a request it was able to satisfy. */
    if (rc != PM_OK) {
        note("pm_init_ex with a zeroed config = %d, expected PM_OK (%d): "
             "the only field asked for is the one this row still applies",
             rc, PM_OK);
        return PROBE_FAIL;
    }
    if (*n_capabilities == before) {
        note("n_capabilities is still %u: capabilities = 0 means 'follow "
             "the hardware' (particle_magic.h), and a request that is "
             "neither applied nor reported is the silent drop C2.4 forbids",
             (unsigned)before);
        return PROBE_FAIL;
    }
    if (want != 0 && *n_capabilities != want) {
        note("n_capabilities = %u, but the machine has %u and 'follow the "
             "hardware' has to mean the hardware",
             (unsigned)*n_capabilities, (unsigned)want);
        return PROBE_FAIL;
    }

    /* And the library is up, exactly as on the sibling row. */
    json = read_whole_file(g_spell_path, NULL);
    if (!json) { note("cannot read spell %s", g_spell_path); return PROBE_FAIL; }
    err[0] = '\0';
    spell = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!spell) { note("pm_cast failed after a zeroed pm_init_ex: %s", err); return PROBE_FAIL; }
    release(spell);
    shutdown();
    note("runtime already up, capabilities = 0: applied as %u (the machine's "
         "own count), reported PM_OK, library usable",
         (unsigned)*n_capabilities);
    return PROBE_PASS;
#endif
}

/* --- probe: firewall (C2.1) ---------------------------------------------
 *
 * The trigger is a test-only symbol that exists only in the poison build
 * (cabal flag oop-poison). It hands back a perfectly valid handle whose
 * contents are bottom, so the failure happens inside the REAL shipped
 * symbols -- which is the thing under test. With the shipped library the
 * symbol is absent and the probe reports SKIP.
 */
static int probe_firewall(void)
{
    fn_poison poison = (fn_poison)lib_sym(g_lib, "pm_poison_spell");
    fn_void_v init = (fn_void_v)need("pm_init");
    fn_void_v shutdown = (fn_void_v)need("pm_shutdown");
    fn_cast cast = (fn_cast)need("pm_cast");
    fn_advance advance = (fn_advance)need("pm_advance");
    fn_observe observe = (fn_observe)need("pm_observe");
    fn_age age = (fn_age)need("pm_age");
    fn_is_finished is_finished = (fn_is_finished)need("pm_is_finished");
    fn_free release = (fn_free)need("pm_free");
    fn_mask mask = (fn_mask)need("pm_occupancy_mask");
    fn_bounds bounds = (fn_bounds)need("pm_spell_bounds");
    const float pos[3] = {1.5f, 0.25f, -2.0f};
    const float facing[3] = {0.0f, 0.0f, 1.0f};
    float bmin[3], bmax[3];
    char err[512];
    char *json;
    PmSpell *good, *bad;
    int batches, v;
    double a;

    if (!poison) {
        note("this library has no pm_poison_spell -- build with "
             "'cabal build -foop-poison particle-magic-ffi-poison' to run it");
        return PROBE_SKIP;
    }
    if (!init || !shutdown || !cast || !advance || !observe || !age
        || !is_finished || !release || !mask || !bounds)
        return PROBE_FAIL;

    json = read_whole_file(g_spell_path, NULL);
    if (!json) { note("cannot read spell %s", g_spell_path); return PROBE_FAIL; }

    init();

    /* 1. the starting point is good */
    err[0] = '\0';
    good = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    if (!good) { note("pm_cast failed before poisoning: %s", err); free(json); return PROBE_FAIL; }
    advance(good, OOP_DT);
    batches = observe(good, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    if (batches < 0) {
        note("pm_observe = %d before poisoning", batches);
        free(json);
        return PROBE_FAIL;
    }

    /* 2. a valid handle over a value that explodes when forced */
    bad = poison();
    if (!bad) { note("pm_poison_spell returned NULL"); free(json); return PROBE_FAIL; }

    /* 3. every shape of sentinel, from the SHIPPED symbols */
    v = observe(bad, col_x, col_y, col_z, col_size, col_life,
                col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    if (v != PM_ERR_INTERNAL) {
        note("pm_observe on a poisoned spell = %d, expected PM_ERR_INTERNAL (%d)",
             v, PM_ERR_INTERNAL);
        free(json);
        return PROBE_FAIL;
    }
    v = is_finished(bad);
    if (v != PM_ERR_INTERNAL) {
        note("pm_is_finished = %d, expected PM_ERR_INTERNAL (%d)", v, PM_ERR_INTERNAL);
        free(json);
        return PROBE_FAIL;
    }
    a = age(bad);
    if (!(a == (double)PM_ERR_INTERNAL)) {
        note("pm_age = %f, expected %f", a, (double)PM_ERR_INTERNAL);
        free(json);
        return PROBE_FAIL;
    }
    if (mask(bad) != 0u) {
        note("pm_occupancy_mask = %u, expected the fail-safe 0", mask(bad));
        free(json);
        return PROBE_FAIL;
    }
    v = bounds(bad, bmin, bmax);
    if (v != PM_ERR_INTERNAL) {
        note("pm_spell_bounds = %d, expected PM_ERR_INTERNAL (%d)", v, PM_ERR_INTERNAL);
        free(json);
        return PROBE_FAIL;
    }
    /* void: it must simply come back */
    advance(bad, OOP_DT);

    /* 4. releasing it is a safe no-op: pm_free must not force the value */
    release(bad);

    /* 5. and the LIBRARY still works -- not merely "did not die" */
    err[0] = '\0';
    advance(good, OOP_DT);
    batches = observe(good, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    if (batches < 0) {
        note("the spell cast before poisoning stopped working: pm_observe = %d",
             batches);
        free(json);
        return PROBE_FAIL;
    }
    release(good);

    bad = cast(json, pos, facing, OOP_SEED, err, (int)sizeof err);
    free(json);
    if (!bad) { note("a fresh pm_cast after the firewall fired failed: %s", err); return PROBE_FAIL; }
    advance(bad, OOP_DT);
    batches = observe(bad, col_x, col_y, col_z, col_size, col_life,
                      col_color, OOP_CAPACITY, batch_info, OOP_MAX_BATCHES);
    release(bad);
    if (batches < 0) {
        note("a fresh spell after the firewall fired cannot be observed: %d", batches);
        return PROBE_FAIL;
    }

    shutdown();
    note("six shipped symbols answered their PM_ERR_INTERNAL sentinel, the "
         "process lived, and the library still casts");
    return PROBE_PASS;
}

/* --- the registry ------------------------------------------------------- */

typedef struct {
    const char *name;
    int (*run)(void);
    const char *covers;
} Probe;

static const Probe PROBES[] = {
    {"load", probe_load, "C1.1 export face (and the .def, across processes)"},
    {"life", probe_life, "C1.1 whole lifecycle against the golden"},
    {"state-uninit", probe_state_uninit, "C2.5 / I3 before pm_init"},
    {"state-after-shutdown", probe_state_after_shutdown, "C2.5 / I3 after pm_shutdown"},
    {"state-reinit", probe_state_reinit, "C2.5 the one-way door"},
    {"rts-config", probe_rts_config, "C1.5 settings reaching the runtime"},
    {"rts-prestarted", probe_rts_prestarted, "C1.5 the already-running-runtime row"},
    {"rts-prestarted-zero-caps", probe_rts_prestarted_zero_caps, "C2.4 capabilities=0 on that row (B002)"},
    {"firewall", probe_firewall, "C2.1 exception firewall"},
};
#define PROBE_COUNT ((int)(sizeof PROBES / sizeof PROBES[0]))

static const Probe *find_probe(const char *name)
{
    int i;
    for (i = 0; i < PROBE_COUNT; ++i)
        if (strcmp(PROBES[i].name, name) == 0) return &PROBES[i];
    return NULL;
}

/* --- the parent: one child per probe ------------------------------------ */

#if defined(_WIN32)
static int spawn_probe(const char *self, const char *lib, const char *probe)
{
    char cmd[2048];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 0xFFFFFFFFu;

    memset(&si, 0, sizeof si);
    si.cb = (DWORD)sizeof si;
    memset(&pi, 0, sizeof pi);
    snprintf(cmd, sizeof cmd,
             "\"%s\" \"%s\" --probe %s --spell \"%s\" --golden \"%s\"",
             self, lib, probe, g_spell_path, g_golden_path);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "cannot spawn %s: error %lu\n", probe,
                (unsigned long)GetLastError());
        return -1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
#else
static int spawn_probe(const char *self, const char *lib, const char *probe)
{
    pid_t pid = fork();
    int status = 0;
    if (pid < 0) { perror("fork"); return -1; }
    if (pid == 0) {
        char *argv[9];
        argv[0] = (char *)self;
        argv[1] = (char *)lib;
        argv[2] = (char *)"--probe";
        argv[3] = (char *)probe;
        argv[4] = (char *)"--spell";
        argv[5] = (char *)g_spell_path;
        argv[6] = (char *)"--golden";
        argv[7] = (char *)g_golden_path;
        argv[8] = NULL;
        execv(self, argv);
        perror("execv");
        _exit(127);
    }
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); return -1; }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) {
        fprintf(stderr, "  child was killed by signal %d\n", WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    return -1;
}
#endif

static int run_all(const char *self, const char *lib)
{
    int i, passed = 0, failed = 0, skipped = 0, pending = 0;
    int gate;
    oop_lib probe_lib;

    /* The parent loads nothing of its own; it asks one short-lived child
       whether the I3 gate is present, so "not landed yet" can be PENDING
       rather than a failure. Today the gate IS landed and this only ever
       takes the strict branch -- but the branch is kept because it is the
       cheapest possible regression detector for the gate disappearing. */
    probe_lib = lib_open(lib);
    if (probe_lib == OOP_NULL_LIB) {
        char why[256];
        lib_why(why, sizeof why);
        printf("oop-smoke: cannot load %s -- %s\n", lib, why);
        return 1;
    }
    gate = lib_sym(probe_lib, "pm_init_ex") != NULL;
    printf("oop-smoke: library %s\n", lib);
    printf("oop-smoke: I3 gate %s (pm_init_ex %s)\n",
           gate ? "landed" : "NOT landed",
           gate ? "resolves" : "is absent");

    for (i = 0; i < PROBE_COUNT; ++i) {
        int code = spawn_probe(self, lib, PROBES[i].name);
        const char *verdict;
        int is_state = strncmp(PROBES[i].name, "state-", 6) == 0;

        if (code == PROBE_PASS) { verdict = "PASS"; passed++; }
        else if (code == PROBE_SKIP) { verdict = "SKIP"; skipped++; }
        else if (code == PROBE_FAIL) { verdict = "FAIL"; failed++; }
        else if (is_state && !gate) {
            /* Did not come back alive, and the gate that would have kept
               it alive is not in this library: not landed, not broken. */
            verdict = "PENDING";
            pending++;
        } else { verdict = "FAIL"; failed++; }

        if (code != PROBE_PASS && code != PROBE_SKIP && code != PROBE_FAIL
            && !(is_state && !gate)) {
            printf("probe %-22s %s -- the child did not survive (exit %d)\n",
                   PROBES[i].name, verdict, code);
        } else if (strcmp(verdict, "PENDING") == 0) {
            printf("probe %-22s %s -- I3 gate not landed (host-runtime F003); "
                   "the child was ended by the runtime (exit %d)\n",
                   PROBES[i].name, verdict, code);
        } else {
            printf("probe %-22s %s\n", PROBES[i].name, verdict);
        }
    }

    printf("oop-smoke: %d passed, %d failed, %d skipped, %d pending\n",
           passed, failed, skipped, pending);
    return failed == 0 ? 0 : 1;
}

/* --- main --------------------------------------------------------------- */

static void usage(const char *self)
{
    fprintf(stderr,
            "usage: %s <library-path> --list\n"
            "       %s <library-path> --all   [--spell PATH] [--golden PATH]\n"
            "       %s <library-path> --probe NAME [--spell PATH] [--golden PATH]\n",
            self, self, self);
}

int main(int argc, char **argv)
{
    const char *lib;
    const char *mode;
    const char *probe_name = NULL;
    int i, rc;
    const Probe *p;
    char why[256];

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (argc < 3) { usage(argv[0]); return 2; }
    lib = argv[1];
    mode = argv[2];

    for (i = 3; i < argc; ++i) {
        if (strcmp(argv[i], "--spell") == 0 && i + 1 < argc) g_spell_path = argv[++i];
        else if (strcmp(argv[i], "--golden") == 0 && i + 1 < argc) g_golden_path = argv[++i];
        else if (!probe_name && strcmp(mode, "--probe") == 0) probe_name = argv[i];
        else { usage(argv[0]); return 2; }
    }
    if (strcmp(mode, "--probe") == 0 && !probe_name) { usage(argv[0]); return 2; }

    if (strcmp(mode, "--list") == 0) {
        for (i = 0; i < PROBE_COUNT; ++i)
            printf("%s\t%s\n", PROBES[i].name, PROBES[i].covers);
        return 0;
    }

    if (strcmp(mode, "--all") == 0) return run_all(argv[0], lib);

    if (strcmp(mode, "--probe") != 0) { usage(argv[0]); return 2; }

    p = find_probe(probe_name);
    if (!p) { fprintf(stderr, "no such probe: %s\n", probe_name); return 2; }

    g_lib = lib_open(lib);
    if (g_lib == OOP_NULL_LIB) {
        lib_why(why, sizeof why);
        fprintf(stderr, "cannot load %s -- %s\n", lib, why);
        return 2;
    }

    g_note[0] = '\0';
    rc = p->run();
    printf("%s: %s%s%s\n", p->name,
           rc == PROBE_PASS ? "pass" : rc == PROBE_SKIP ? "skip" : "fail",
           g_note[0] ? " -- " : "", g_note);
    return rc;
}
