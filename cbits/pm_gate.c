/* pm_gate.c -- I3: nothing enters the runtime before it is ready
 * (host-runtime F003; ADR-022 D1).
 *
 * Every public symbol in include/particle_magic.h except the three
 * lifecycle ones is defined here as a three-line wrapper around the
 * Haskell export of the same name with a pm_hs_ prefix. The wrapper asks
 * pm_runtime_ready() and, outside RUNNING, answers the sentinel its return
 * type allows instead of calling through.
 *
 * Why this layer is in C and not in Haskell: entering a `foreign export`
 * before hs_init, or after hs_exit, does not fail -- it terminates the
 * process from inside the RTS ("newBoundTask: RTS is not initialised"),
 * while GHC's stub is still setting up a bound task and before one line of
 * this library's Haskell has run. A check written in Haskell would be on
 * the wrong side of the crash. Measured on both platforms, 2026-08-20.
 *
 * The sentinels, matching the exception firewall's (host-runtime F001)
 * shape with -7 where it uses -6:
 *
 *   returning a count or code   PM_ERR_STATE (-7)
 *   returning a handle          NULL (pm_cast also writes a reason)
 *   returning void              nothing at all
 *   pm_age                      -7.0  (an age is never negative)
 *   pm_occupancy_mask           0     (fail-safe: "nothing is anywhere")
 *   pm_abi_version              PM_ABI_VERSION -- see below
 *
 * pm_is_finished answering -7 reads as true in C, so a host's
 * `while (!pm_is_finished(s))` ends rather than spinning on a spell that
 * can no longer answer -- the same reasoning F001 applied to -6.
 *
 * pm_abi_version is the one symbol the gate does not close: the header
 * tells hosts to compare generations at startup, which is before pm_init.
 * The C layer answers it from the same PM_ABI_VERSION macro the Haskell
 * side mirrors, so this is one truth read twice, not two truths.
 *
 * Cost: one acquire load, one comparison and a direct jump per call --
 * next to nothing beside the C-to-Haskell stub that follows it, which has
 * a bound task to set up. Every symbol pays it, so the gate does nothing
 * else whatsoever.
 */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define PM_EXPORT __declspec(dllexport)
#else
#define PM_EXPORT __attribute__((visibility("default")))
#endif

/* The attributed declarations come before the header's plain ones for the
   same reason as in cbits/pm_init.c: adding dllexport to an existing
   declaration is a warning, adding it first is not. The two handle types
   are only needed by name, so the struct tags are enough and the header
   stays the one place they are defined. */
struct PmSpell;
struct PmScene;

PM_EXPORT int pm_abi_version(void);
PM_EXPORT int pm_max_particles(void);
PM_EXPORT struct PmSpell* pm_cast(const char*, const float[3], const float[3],
                                  uint64_t, char*, int);
PM_EXPORT int pm_cast_ex(const char*, const float[3], const float[3],
                         uint64_t, char*, int, struct PmSpell**);
PM_EXPORT void pm_advance(struct PmSpell*, float);
PM_EXPORT int pm_advance_ex(struct PmSpell*, float);
PM_EXPORT int pm_is_finished(const struct PmSpell*);
PM_EXPORT double pm_age(const struct PmSpell*);
PM_EXPORT int pm_observe(struct PmSpell*, float*, float*, float*,
                         float*, float*, uint32_t*, int, int*, int);
PM_EXPORT int pm_observe_ex(struct PmSpell*, float*, float*, float*,
                            float*, float*, uint32_t*,
                            float*, float*, float*, int, int*, int);
PM_EXPORT int pm_project(int, const float*, const float*, const float*,
                         int, float*, float*, float*);
PM_EXPORT int pm_depth_order(int, const float*, const float*, const float*,
                             int, int*);
PM_EXPORT void pm_free(struct PmSpell*);
PM_EXPORT struct PmScene* pm_scene_new(int);
PM_EXPORT void pm_scene_free(struct PmScene*);
PM_EXPORT int pm_scene_cast(struct PmScene*, const char*, const float[3],
                            const float[3], uint64_t, char*, int, int*);
PM_EXPORT int pm_scene_cast_many(struct PmScene*, const char* const*, int,
                                 const float[3], const float[3], uint64_t,
                                 char*, int, int*);
PM_EXPORT void pm_scene_dismiss(struct PmScene*, int);
PM_EXPORT void pm_scene_advance(struct PmScene*, float);
PM_EXPORT int pm_scene_advance_ex(struct PmScene*, float);
PM_EXPORT int pm_plan_steps(double, int, double, double, int*, double*);
PM_EXPORT int pm_scene_observe(struct PmScene*, float*, float*, float*,
                               float*, float*, uint32_t*, int, int*, int);
PM_EXPORT int pm_scene_budget(const struct PmScene*, int*, int*);
PM_EXPORT int pm_scene_count(const struct PmScene*);
PM_EXPORT int pm_scene_spells(const struct PmScene*, int*, int);
PM_EXPORT int pm_spell_bounds(const struct PmSpell*, float[3], float[3]);
PM_EXPORT int pm_spell_box(const struct PmSpell*, float[3], float[9], float[3]);
PM_EXPORT int pm_emitter_count(const struct PmSpell*);
PM_EXPORT int pm_emitter_box(const struct PmSpell*, int, float[3], float[9], float[3]);
PM_EXPORT int pm_occupancy(struct PmSpell*, int, int*, int);
PM_EXPORT uint32_t pm_occupancy_mask(struct PmSpell*);
PM_EXPORT int pm_scene_spell_bounds(const struct PmScene*, int, float[3], float[3]);

#include "particle_magic.h"
#include "pm_runtime.h"

/* The Haskell side. GHC generates these from the `foreign export ccall
   "pm_hs_*"` declarations in src/ffi/Magic/FFI.hs; they are internal --
   absent from the header and from particle-magic-ffi.def, so the Windows
   export surface does not change at all. */
extern int pm_hs_abi_version(void);
extern int pm_hs_max_particles(void);
extern PmSpell* pm_hs_cast(const char*, const float*, const float*,
                           uint64_t, char*, int);
extern int pm_hs_cast_ex(const char*, const float*, const float*,
                         uint64_t, char*, int, PmSpell**);
extern void pm_hs_advance(PmSpell*, float);
extern int pm_hs_advance_ex(PmSpell*, float);
extern int pm_hs_is_finished(const PmSpell*);
extern double pm_hs_age(const PmSpell*);
extern int pm_hs_observe(PmSpell*, float*, float*, float*,
                         float*, float*, uint32_t*, int, int*, int);
extern int pm_hs_observe_ex(PmSpell*, float*, float*, float*,
                            float*, float*, uint32_t*,
                            float*, float*, float*, int, int*, int);
extern int pm_hs_project(int, const float*, const float*, const float*,
                         int, float*, float*, float*);
extern int pm_hs_depth_order(int, const float*, const float*, const float*,
                             int, int*);
extern void pm_hs_free(PmSpell*);
extern PmScene* pm_hs_scene_new(int);
extern void pm_hs_scene_free(PmScene*);
extern int pm_hs_scene_cast(PmScene*, const char*, const float*,
                            const float*, uint64_t, char*, int, int*);
extern int pm_hs_scene_cast_many(PmScene*, const char* const*, int,
                                 const float*, const float*, uint64_t,
                                 char*, int, int*);
extern void pm_hs_scene_dismiss(PmScene*, int);
extern void pm_hs_scene_advance(PmScene*, float);
extern int pm_hs_scene_advance_ex(PmScene*, float);
extern int pm_hs_plan_steps(double, int, double, double, int*, double*);
extern int pm_hs_scene_observe(PmScene*, float*, float*, float*,
                               float*, float*, uint32_t*, int, int*, int);
extern int pm_hs_scene_budget(const PmScene*, int*, int*);
extern int pm_hs_scene_count(const PmScene*);
extern int pm_hs_scene_spells(const PmScene*, int*, int);
extern int pm_hs_spell_bounds(const PmSpell*, float*, float*);
extern int pm_hs_spell_box(const PmSpell*, float*, float*, float*);
extern int pm_hs_emitter_count(const PmSpell*);
extern int pm_hs_emitter_box(const PmSpell*, int, float*, float*, float*);
extern int pm_hs_occupancy(PmSpell*, int, int*, int);
extern uint32_t pm_hs_occupancy_mask(PmSpell*);
extern int pm_hs_scene_spell_bounds(const PmScene*, int, float*, float*);

/* The one message the gate writes. Fixed ASCII, bounded, NUL terminated:
   there is no runtime to render anything else with. */
static const char pm_gate_message[] =
    "particle-magic: the runtime is not ready -- call pm_init() or "
    "pm_init_ex() first, and note that after pm_shutdown() this process "
    "cannot use the library again";

static void pm_gate_explain(char* err_buf, int err_len)
{
    int i = 0;

    if (err_buf == NULL || err_len <= 0) {
        return;
    }
    while (pm_gate_message[i] != '\0' && i < err_len - 1) {
        err_buf[i] = pm_gate_message[i];
        i++;
    }
    err_buf[i] = '\0';
}

/* Lifecycle-adjacent ---------------------------------------------------- */

/* Answered without the runtime on purpose: the header asks hosts to check
   the generation at startup, which is before pm_init. */
PM_EXPORT int pm_abi_version(void)
{
    return PM_ABI_VERSION;
}

/* The counting symbols -------------------------------------------------- */

PM_EXPORT int pm_max_particles(void)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_max_particles();
}

PM_EXPORT int pm_cast_ex(const char* circle_json,
                         const float caster_pos[3], const float caster_facing[3],
                         uint64_t seed, char* err_buf, int err_len,
                         PmSpell** out_spell)
{
    if (!pm_runtime_ready()) {
        pm_gate_explain(err_buf, err_len);
        if (out_spell != NULL) *out_spell = NULL;
        return PM_ERR_STATE;
    }
    return pm_hs_cast_ex(circle_json, caster_pos, caster_facing, seed,
                         err_buf, err_len, out_spell);
}

PM_EXPORT int pm_is_finished(const PmSpell* spell)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_is_finished(spell);
}

PM_EXPORT int pm_observe(PmSpell* spell,
                         float* pos_x, float* pos_y, float* pos_z,
                         float* size, float* life, uint32_t* color,
                         int capacity, int* batch_info, int max_batches)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_observe(spell, pos_x, pos_y, pos_z, size, life, color,
                         capacity, batch_info, max_batches);
}

PM_EXPORT int pm_observe_ex(PmSpell* spell,
                            float* pos_x, float* pos_y, float* pos_z,
                            float* size, float* life, uint32_t* color,
                            float* vel_x, float* vel_y, float* vel_z,
                            int capacity, int* batch_info, int max_batches)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_observe_ex(spell, pos_x, pos_y, pos_z, size, life, color,
                            vel_x, vel_y, vel_z, capacity, batch_info,
                            max_batches);
}

PM_EXPORT int pm_project(int plane,
                         const float* pos_x, const float* pos_y, const float* pos_z,
                         int count,
                         float* out_x, float* out_y, float* out_depth)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_project(plane, pos_x, pos_y, pos_z, count,
                         out_x, out_y, out_depth);
}

PM_EXPORT int pm_depth_order(int plane,
                             const float* pos_x, const float* pos_y, const float* pos_z,
                             int count, int* out_indices)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_depth_order(plane, pos_x, pos_y, pos_z, count, out_indices);
}

PM_EXPORT int pm_scene_cast(PmScene* scene, const char* circle_json,
                            const float caster_pos[3], const float caster_facing[3],
                            uint64_t seed, char* err_buf, int err_len, int* out_id)
{
    if (!pm_runtime_ready()) {
        pm_gate_explain(err_buf, err_len);
        return PM_ERR_STATE;
    }
    return pm_hs_scene_cast(scene, circle_json, caster_pos, caster_facing,
                            seed, err_buf, err_len, out_id);
}

PM_EXPORT int pm_scene_cast_many(PmScene* scene, const char* const* circle_jsons,
                                 int count,
                                 const float caster_pos[3], const float caster_facing[3],
                                 uint64_t seed, char* err_buf, int err_len, int* out_id)
{
    if (!pm_runtime_ready()) {
        pm_gate_explain(err_buf, err_len);
        return PM_ERR_STATE;
    }
    return pm_hs_scene_cast_many(scene, circle_jsons, count, caster_pos,
                                 caster_facing, seed, err_buf, err_len, out_id);
}

PM_EXPORT int pm_scene_observe(PmScene* scene,
                               float* pos_x, float* pos_y, float* pos_z,
                               float* size, float* life, uint32_t* color,
                               int capacity, int* batch_info, int max_batches)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_observe(scene, pos_x, pos_y, pos_z, size, life, color,
                               capacity, batch_info, max_batches);
}

PM_EXPORT int pm_scene_budget(const PmScene* scene, int* out_used, int* out_cap)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_budget(scene, out_used, out_cap);
}

PM_EXPORT int pm_scene_count(const PmScene* scene)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_count(scene);
}

PM_EXPORT int pm_scene_spells(const PmScene* scene, int* out_ids, int max_ids)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_spells(scene, out_ids, max_ids);
}

PM_EXPORT int pm_spell_bounds(const PmSpell* spell, float out_min[3], float out_max[3])
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_spell_bounds(spell, out_min, out_max);
}

PM_EXPORT int pm_spell_box(const PmSpell* spell, float out_center[3],
                           float out_axes[9], float out_half[3])
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_spell_box(spell, out_center, out_axes, out_half);
}

PM_EXPORT int pm_emitter_count(const PmSpell* spell)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_emitter_count(spell);
}

PM_EXPORT int pm_emitter_box(const PmSpell* spell, int index, float out_center[3],
                             float out_axes[9], float out_half[3])
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_emitter_box(spell, index, out_center, out_axes, out_half);
}

PM_EXPORT int pm_occupancy(PmSpell* spell, int dim, int* out_counts, int capacity)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_occupancy(spell, dim, out_counts, capacity);
}

PM_EXPORT int pm_scene_spell_bounds(const PmScene* scene, int spell_id,
                                    float out_min[3], float out_max[3])
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_spell_bounds(scene, spell_id, out_min, out_max);
}

/* host-runtime F005. The advances' error-code variants (C1.12) and the
   planner (C1.7) are gated like everything else -- the planner too, even
   though it is a pure function, because it IS the boundary layer's planner
   rather than a second copy of it, and reaching that one costs a runtime.
   The header says so where a host will read it. */
PM_EXPORT int pm_advance_ex(PmSpell* spell, float dt)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_advance_ex(spell, dt);
}

PM_EXPORT int pm_scene_advance_ex(PmScene* scene, float dt)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_scene_advance_ex(scene, dt);
}

PM_EXPORT int pm_plan_steps(double dt, int max_steps, double elapsed, double acc_in,
                            int* out_steps, double* out_acc)
{
    if (!pm_runtime_ready()) return PM_ERR_STATE;
    return pm_hs_plan_steps(dt, max_steps, elapsed, acc_in, out_steps, out_acc);
}

/* The handle-returning symbols ------------------------------------------ */

PM_EXPORT PmSpell* pm_cast(const char* circle_json,
                           const float caster_pos[3], const float caster_facing[3],
                           uint64_t seed, char* err_buf, int err_len)
{
    if (!pm_runtime_ready()) {
        pm_gate_explain(err_buf, err_len);
        return NULL;
    }
    return pm_hs_cast(circle_json, caster_pos, caster_facing, seed,
                      err_buf, err_len);
}

PM_EXPORT PmScene* pm_scene_new(int global_cap)
{
    if (!pm_runtime_ready()) return NULL;
    return pm_hs_scene_new(global_cap);
}

/* The void symbols ------------------------------------------------------ */

PM_EXPORT void pm_advance(PmSpell* spell, float dt)
{
    if (!pm_runtime_ready()) return;
    pm_hs_advance(spell, dt);
}

PM_EXPORT void pm_free(PmSpell* spell)
{
    if (!pm_runtime_ready()) return;
    pm_hs_free(spell);
}

PM_EXPORT void pm_scene_free(PmScene* scene)
{
    if (!pm_runtime_ready()) return;
    pm_hs_scene_free(scene);
}

PM_EXPORT void pm_scene_dismiss(PmScene* scene, int spell_id)
{
    if (!pm_runtime_ready()) return;
    pm_hs_scene_dismiss(scene, spell_id);
}

PM_EXPORT void pm_scene_advance(PmScene* scene, float dt)
{
    if (!pm_runtime_ready()) return;
    pm_hs_scene_advance(scene, dt);
}

/* The two with a value of their own -------------------------------------- */

PM_EXPORT double pm_age(const PmSpell* spell)
{
    if (!pm_runtime_ready()) return -7.0;
    return pm_hs_age(spell);
}

PM_EXPORT uint32_t pm_occupancy_mask(PmSpell* spell)
{
    if (!pm_runtime_ready()) return 0;
    return pm_hs_occupancy_mask(spell);
}
