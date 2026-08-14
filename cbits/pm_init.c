/* pm_init.c -- RTS lifecycle wrapper (func-spec 0009 section 4.3, ADR-0011 D5).
 *
 * Everything else in the C ABI is a Haskell `foreign export ccall`; these
 * two functions are the exception, because starting and stopping the GHC
 * runtime cannot itself be a Haskell call. Both are idempotent: a host
 * that calls pm_init() from several subsystems, or on every scene load,
 * gets exactly one runtime.
 *
 * On Windows the DLL built by the foreign-library stanza initialises the
 * RTS from DllMain, so pm_init() is belt-and-braces there; on Linux/macOS
 * a .so needs the explicit call. Hosts call it unconditionally and stay
 * portable. hs_init/hs_exit are reference counted by the RTS, so the flag
 * here only keeps *our* pairing straight.
 *
 * One process loads one copy of the RTS (a GHC limitation, see ADR-0011's
 * consequences): do not link two GHC-produced shared objects into the same
 * host and expect them to cooperate.
 */
#include <stddef.h>

#include "HsFFI.h"

#if defined(_WIN32)
#define PM_EXPORT __declspec(dllexport)
#else
#define PM_EXPORT __attribute__((visibility("default")))
#endif

/* The shared object exports its Haskell entry points by itself, but these
   two are plain C and need saying so. The attributed declarations come
   before the header's plain ones on purpose: adding dllexport to an
   existing declaration is a warning, adding it first is not. */
PM_EXPORT void pm_init(void);
PM_EXPORT void pm_shutdown(void);

#include "particle_magic.h"

static int pm_rts_running = 0;

PM_EXPORT void pm_init(void)
{
    if (!pm_rts_running) {
        static char  argv0[] = "particle-magic-ffi";
        static char *argv[]  = {argv0, NULL};
        char       **pargv   = argv;
        int          argc    = 1;

        hs_init(&argc, &pargv);
        pm_rts_running = 1;
    }
}

PM_EXPORT void pm_shutdown(void)
{
    if (pm_rts_running) {
        pm_rts_running = 0;
        hs_exit();
    }
}
