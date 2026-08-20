/* pm_runtime.h -- the one question cbits/pm_gate.c asks cbits/pm_init.c.
 *
 * INTERNAL (host-runtime F003). Not installed, not declared in
 * include/particle_magic.h, not listed in particle-magic-ffi.def: this is
 * how the two C translation units share the runtime state machine, not
 * part of the ABI.
 */
#ifndef PM_RUNTIME_H
#define PM_RUNTIME_H

/* Non-zero exactly while the state machine is RUNNING, i.e. between a
   successful pm_init/pm_init_ex and pm_shutdown. One acquire load and one
   comparison -- this runs in front of every exported symbol, so it does
   nothing else at all: no logging, no locking, no table lookup. */
int pm_runtime_ready(void);

#endif /* PM_RUNTIME_H */
