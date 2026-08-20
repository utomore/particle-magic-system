/* pm_init.c -- the runtime's lifecycle: state machine, configuration,
 * shutdown (host-runtime F003, ADR-022 D1; originally func-spec 0009
 * section 4.3, ADR-0011 D5).
 *
 * Everything else in the C ABI is a Haskell `foreign export ccall` behind
 * a gate in cbits/pm_gate.c; these three functions are the exception,
 * because starting and stopping the GHC runtime cannot itself be a Haskell
 * call.
 *
 * What the host gets from here:
 *
 *   * pm_init_ex(cfg) -- capability count, nursery size, GC mode and the
 *     statistics flag, all four applied to the runtime as it starts. The
 *     option string is built HERE from bounded integers and never taken
 *     from the host as free text: a malformed RTS option makes the runtime
 *     abort the whole process, which is the one thing this library must
 *     never do to its host (P-1).
 *   * pm_init() -- the same machine with no settings: one capability, the
 *     default collector, no statistics. Bit for bit what it always did.
 *   * A four-state machine, atomic, so that two engine threads racing to
 *     initialise is a defined situation and not a data race, and so that
 *     "already shut down" is an error code rather than a dead process.
 *     GHC 9.14 refuses to restart a runtime it has stopped -- it prints
 *     "reinitializing the RTS after shutdown is not currently supported"
 *     and kills the process -- so the machine makes sure hs_init_ghc is
 *     never reached a second time.
 *
 *       UNINIT --(pm_init/pm_init_ex)--> INITIALIZING --> RUNNING
 *                                                            |
 *                                                    (pm_shutdown)
 *                                                            v
 *                                                          CLOSED
 *
 *     Every other exported symbol asks pm_runtime_ready() first (I3, see
 *     cbits/pm_gate.c) and answers a sentinel outside RUNNING, because
 *     entering the runtime before hs_init or after hs_exit terminates the
 *     process from inside the RTS, where no Haskell-side check could ever
 *     run.
 *
 * The environment is deliberately shut out: rts_opts_enabled is
 * RtsOptsIgnoreAll, so GHCRTS can neither override what the host asked for
 * nor abort the process on a non-"safe" option. The runtime belongs to the
 * host, and an environment variable is not the host's API call.
 *
 * One process loads one copy of the RTS (a GHC limitation, see ADR-0011's
 * consequences): do not link two GHC-produced shared objects into the same
 * host and expect them to cooperate.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

/* Rts.h before RtsAPI.h, which is not self-contained: it names W_ and
   STG_NORETURN. Rts.h is also where getNumCapabilities/setNumCapabilities
   come from. getNumCapabilities() reads 0 until some runtime starts, which
   is how this file tells "nobody has started one" from "the host already
   has one running" -- and reading it before hs_init is a plain global
   load, so it is safe to ask first. */
#include "Rts.h"
#include "RtsAPI.h"

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <sched.h>
#endif

#if defined(_WIN32)
#define PM_EXPORT __declspec(dllexport)
#else
#define PM_EXPORT __attribute__((visibility("default")))
#endif

/* The attributed declarations come before the header's plain ones on
   purpose: adding dllexport to an existing declaration is a warning,
   adding it first is not. PmConfig is only needed by name here, so the
   struct tag is enough and the header stays the one place it is defined. */
struct PmConfig;
PM_EXPORT void pm_init(void);
PM_EXPORT int pm_init_ex(const struct PmConfig* config);
PM_EXPORT void pm_shutdown(void);

#include "particle_magic.h"
#include "pm_runtime.h"

/* The state machine ---------------------------------------------------- */

#define PM_RT_UNINIT       0
#define PM_RT_INITIALIZING 1
#define PM_RT_RUNNING      2
#define PM_RT_CLOSED       3

static atomic_int pm_rt_state = PM_RT_UNINIT;

/* Did we call hs_init/hs_init_ghc? Written only inside INITIALIZING, read
   only after RUNNING, so no atomic is needed. pm_shutdown pairs exactly
   the reference we took and no more -- a host that started the runtime
   itself keeps its own. */
static int pm_rt_paired = 0;

/* Non-zero when the runtime found in this process is the one we started.
   Kept for the error path's sake: it is the difference between "your
   settings were applied" and "the runtime was already here, so most of
   them could not be". */
static int pm_rt_is_ours = 0;

int pm_runtime_ready(void)
{
    return atomic_load_explicit(&pm_rt_state, memory_order_acquire) == PM_RT_RUNNING;
}

static void pm_rt_yield(void)
{
#if defined(_WIN32)
    SwitchToThread();
#else
    sched_yield();
#endif
}

/* INITIALIZING is brief but observable: the thread that loses the race can
   see it. Wait it out -- bounded, and yielding rather than burning a core,
   and without this library ever creating a thread of its own (C2.4) -- so
   that the loser is told what actually happened instead of being handed a
   racing value. */
static int pm_rt_settled(void)
{
    int spins = 0;
    int state = atomic_load_explicit(&pm_rt_state, memory_order_acquire);

    while (state == PM_RT_INITIALIZING && spins < 1000000) {
        pm_rt_yield();
        spins++;
        state = atomic_load_explicit(&pm_rt_state, memory_order_acquire);
    }
    return state;
}

/* Building the option string ------------------------------------------- */

/* "-N256 -A1073741824 --nonmoving-gc -T" is 36 characters; the buffer is
   fixed, nothing is allocated, and every field feeding it is a bounded
   integer validated before we get here. It is static rather than automatic
   because hs_init_ghc keeps the pointer for the runtime's lifetime, and
   only the thread that won the CAS ever writes it. */
#define PM_RT_OPTS_CAP 64
static char pm_rt_opts[PM_RT_OPTS_CAP];

static size_t pm_rt_put(size_t at, const char* text)
{
    while (*text != '\0' && at + 1 < PM_RT_OPTS_CAP) {
        pm_rt_opts[at++] = *text++;
    }
    pm_rt_opts[at] = '\0';
    return at;
}

static size_t pm_rt_put_u64(size_t at, uint64_t value)
{
    char digits[24];
    size_t n = 0;

    do {
        digits[n++] = (char)('0' + (int)(value % 10u));
        value /= 10u;
    } while (value != 0);

    while (n > 0 && at + 1 < PM_RT_OPTS_CAP) {
        pm_rt_opts[at++] = digits[--n];
    }
    pm_rt_opts[at] = '\0';
    return at;
}

static size_t pm_rt_sep(size_t at)
{
    return at == 0 ? at : pm_rt_put(at, " ");
}

/* NULL when there is nothing to say, which is both what pm_init wants and
   bit for bit the runtime this library has always started. */
static const char* pm_rt_build_opts(const PmConfig* cfg)
{
    size_t at = 0;

    pm_rt_opts[0] = '\0';
    if (cfg == NULL) {
        return NULL;
    }

    /* -N without a number means "follow the hardware"; -N0 aborts the
       process, and -N1 is the runtime's own default, so neither is worth
       emitting. */
    if (cfg->capabilities == 0) {
        at = pm_rt_put(at, "-N");
    } else if (cfg->capabilities >= 2) {
        at = pm_rt_put(at, "-N");
        at = pm_rt_put_u64(at, cfg->capabilities);
    }
    if (cfg->nursery_bytes != 0) {
        at = pm_rt_sep(at);
        at = pm_rt_put(at, "-A");
        at = pm_rt_put_u64(at, cfg->nursery_bytes);
    }
    if (cfg->gc_mode == PM_GC_NONMOVING) {
        at = pm_rt_sep(at);
        at = pm_rt_put(at, "--nonmoving-gc");
    }
    if (cfg->stats == PM_STATS_ON) {
        at = pm_rt_sep(at);
        at = pm_rt_put(at, "-T");
    }
    return at == 0 ? NULL : pm_rt_opts;
}

/* Validation ------------------------------------------------------------ */

/* Pure, and ahead of the state machine: a rejected config leaves both the
   state and the runtime exactly as they were. Every bound here is one the
   runtime would otherwise enforce by aborting the process. */
static int pm_rt_validate(const PmConfig* cfg)
{
    if (cfg == NULL) {
        return PM_ERR_ARGS;
    }
    /* A size we do not recognise -- older or newer -- is refused rather
       than partially applied: silently ignoring a field the host set is
       exactly what C2.4 forbids. */
    if (cfg->size != (uint32_t)sizeof(PmConfig)) {
        return PM_ERR_ARGS;
    }
    if (cfg->capabilities > (uint32_t)PM_MAX_CAPABILITIES) {
        return PM_ERR_ARGS;
    }
    if (cfg->nursery_bytes != 0
        && (cfg->nursery_bytes < (uint64_t)PM_NURSERY_MIN_BYTES
            || cfg->nursery_bytes > (uint64_t)PM_NURSERY_MAX_BYTES)) {
        return PM_ERR_ARGS;
    }
    if (cfg->gc_mode != PM_GC_DEFAULT && cfg->gc_mode != PM_GC_NONMOVING) {
        return PM_ERR_ARGS;
    }
    if (cfg->stats != PM_STATS_OFF && cfg->stats != PM_STATS_ON) {
        return PM_ERR_ARGS;
    }
    return PM_OK;
}

/* Starting -------------------------------------------------------------- */

static int pm_rt_start(const PmConfig* cfg)
{
    static char  argv0[] = "particle-magic-ffi";
    static char *argv[]  = {argv0, NULL};
    char       **pargv   = argv;
    int          argc    = 1;
    int          expected = PM_RT_UNINIT;
    int          rc = PM_OK;

    if (!atomic_compare_exchange_strong(&pm_rt_state, &expected, PM_RT_INITIALIZING)) {
        /* Lost the race, or there was never one to win. Either way the
           settings in this call were not applied; wait out a concurrent
           initialisation so the answer is settled rather than racing. */
        if (expected == PM_RT_INITIALIZING) {
            (void)pm_rt_settled();
        }
        return PM_ERR_STATE;
    }

    if (getNumCapabilities() == 0) {
        RtsConfig conf = defaultRtsConfig;

        conf.rts_hs_main      = HS_BOOL_FALSE;
        conf.rts_opts_enabled = RtsOptsIgnoreAll;
        conf.rts_opts         = pm_rt_build_opts(cfg);
        hs_init_ghc(&argc, &pargv, conf);
        pm_rt_paired = 1;
        pm_rt_is_ours = 1;
    } else {
        /* The runtime was already running when we were asked -- a Haskell
           host, or one that called hs_init itself. Take a reference so our
           pm_shutdown releases only what we took, apply what the runtime
           still accepts at this point, and report the rest. */
        hs_init(&argc, &pargv);
        pm_rt_paired = 1;
        pm_rt_is_ours = 0;

        if (cfg != NULL) {
            if (cfg->capabilities != 0) {
                setNumCapabilities(cfg->capabilities);
            }
            if (cfg->nursery_bytes != 0
                || cfg->gc_mode != PM_GC_DEFAULT
                || (cfg->stats == PM_STATS_ON && !getRTSStatsEnabled())) {
                rc = PM_ERR_STATE;
            }
        }
    }

    atomic_store_explicit(&pm_rt_state, PM_RT_RUNNING, memory_order_release);
    return rc;
}

/* The three exported entry points --------------------------------------- */

PM_EXPORT int pm_init_ex(const PmConfig* config)
{
    int rc = pm_rt_validate(config);

    if (rc != PM_OK) {
        return rc;
    }
    return pm_rt_start(config);
}

PM_EXPORT void pm_init(void)
{
    /* Idempotent in every direction: already running is a no-op, and so is
       already shut down -- which used to be a dead process. */
    (void)pm_rt_start(NULL);
}

PM_EXPORT void pm_shutdown(void)
{
    int expected = PM_RT_RUNNING;

    if (atomic_load_explicit(&pm_rt_state, memory_order_acquire) == PM_RT_INITIALIZING) {
        (void)pm_rt_settled();
    }
    /* The state closes BEFORE hs_exit: a thread already at the gate then
       answers PM_ERR_STATE instead of entering a runtime that is going
       away. Outside RUNNING this does nothing at all, so hs_exit is never
       called more often than we called hs_init. */
    if (atomic_compare_exchange_strong(&pm_rt_state, &expected, PM_RT_CLOSED)) {
        if (pm_rt_paired) {
            pm_rt_paired = 0;
            hs_exit();
        }
    }
    (void)pm_rt_is_ours;
}
