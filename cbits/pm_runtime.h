/* pm_runtime.h -- what cbits/pm_gate.c asks cbits/pm_init.c, plus the one
 * seam test/FFIRuntimeCapsSpec.hs needs.
 *
 * INTERNAL (host-runtime F003). Not installed, not declared in
 * include/particle_magic.h, not listed in particle-magic-ffi.def: this is
 * how the translation units built from cbits/ share the runtime state
 * machine, not part of the ABI. Nothing here carries PM_EXPORT, so
 * test/FFIContractSpec.hs does not count these among the public symbols
 * and the Windows export face stays exactly the .def's list.
 */
#ifndef PM_RUNTIME_H
#define PM_RUNTIME_H

struct PmConfig;

/* Non-zero exactly while the state machine is RUNNING, i.e. between a
   successful pm_init/pm_init_ex and pm_shutdown. One acquire load and one
   comparison -- this runs in front of every exported symbol, so it does
   nothing else at all: no logging, no locking, no table lookup. */
int pm_runtime_ready(void);

/* The header's "the GHC runtime was ALREADY running in this process" row:
 * apply everything such a runtime still accepts and answer PM_ERR_STATE
 * when some field could not be applied, PM_OK when every field could.
 * NULL is pm_init's own call and asks for nothing (PM_OK, nothing
 * applied).
 *
 * It is a function of its own, and not static, for one reason: the state
 * machine allows exactly ONE initialisation per process, so an in-process
 * spec gets one shot at pm_init_ex and cannot cover this decision case by
 * case. B002 was found in a branch of it that no test could reach.
 */
int pm_runtime_apply_to_running(const struct PmConfig* cfg);

#endif /* PM_RUNTIME_H */
