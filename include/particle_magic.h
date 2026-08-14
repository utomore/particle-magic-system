/* particle_magic.h -- C ABI for the particle magic system.
 *
 * func-spec 0009 section 4.2, ADR-0011. This header is the whole contract:
 * a host that can load a shared library and call C functions can drive the
 * complete spell lifecycle without knowing that the library is written in
 * Haskell.
 *
 * FROZEN: once delivered, this header only ever gains declarations. Every
 * name, value and layout below is fixed; pm_abi_version() lets a host
 * check at startup that it was compiled against the same generation.
 * test/FFIContractSpec.hs parses this file and the Haskell foreign export
 * list and fails the build if they drift apart.
 *
 * Usage:
 *
 *   pm_init();
 *   char err[256];
 *   const float pos[3] = {0, 0, 0}, facing[3] = {0, 0, 1};
 *   PmSpell* s = pm_cast(json, pos, facing, 42, err, sizeof err);
 *   if (!s) { fprintf(stderr, "%s\n", err); return 1; }
 *   while (!pm_is_finished(s)) {
 *       pm_advance(s, 1.0f / 60.0f);
 *       int n = pm_observe(s, px, py, pz, size, life, color,
 *                          PM_MAX_PARTICLES, info, 8);
 *       ...  feed your vertex buffer from the six arrays ...
 *   }
 *   pm_free(s);
 *   pm_shutdown();
 *
 * Coordinate system: the abstract space is right-handed, OpenGL style --
 * X to the right, Y up, +Z towards the viewer. Lengths are whatever world
 * unit the magic circle's JSON is written in; time is seconds.
 *
 * A left-handed host (Unity, Unreal: +Z into the screen) must negate Z on
 * the way in and on the way out. Getting this wrong crashes nothing and
 * looks correct for purely analytic spells -- the one symptom is that a
 * `vortex` force field spins the wrong way, because a cross product is
 * genuinely handed.
 *
 * Threading: one handle is owned by one thread. The library itself takes
 * no locks (ADR-0011 D4); different handles on different threads are fine.
 *
 * Determinism: the same (json, pos, facing, seed, dt sequence) always
 * produces bit-identical output, on every platform and through either
 * consumption path (ADR-0011 D8).
 */
#ifndef PARTICLE_MAGIC_H
#define PARTICLE_MAGIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Generation of this ABI. Compare against pm_abi_version() at startup. */
#define PM_ABI_VERSION 1

/* Upper bound on the particles a single spell can produce, i.e. the
   capacity each of the six columns needs. Mirrors the core's budgetCap. */
#define PM_MAX_PARTICLES 4096

/* ... and, being frozen, it stays 4096 forever: it is the first
   generation's value, kept so code compiled against any version of this
   header keeps allocating a buffer the library will never overrun. A
   later core may raise the real cap; pm_max_particles() is the query that
   follows it, so new hosts should size their columns from that instead
   (func-spec 0011 section 2). */

/* Error codes. Functions returning a count return a non-negative number on
   success and one of these on failure; functions returning a handle return
   NULL and write a message into the caller's err_buf. */
#define PM_OK 0
#define PM_ERR_JSON (-1)
#define PM_ERR_BUDGET (-2)
#define PM_ERR_CAPACITY (-3)
#define PM_ERR_ARGS (-4)

/* Which axis the orthographic camera looks along, for pm_project and
   pm_depth_order (ADR-0008: "2D = drop one axis and pick a depth-sorting
   strategy"). Anything else is PM_ERR_ARGS. */
#define PM_PLANE_SIDE_XY 0   /* viewer at +Z: plane = (x, y), depth = -z */
#define PM_PLANE_TOP_XZ 1    /* viewer at +Y: plane = (x, z), depth = -y */

/* batch_info[4*i + 2] -- how the batch's particles are blended. */
#define PM_BLEND_ALPHA 0
#define PM_BLEND_ADDITIVE 1

/* batch_info[4*i + 3] -- the billboard geometry the batch expects. */
#define PM_SHAPE_SQUARE 0

/* Ints per batch in the batch_info array: offset, count, blend, shape. */
#define PM_BATCH_INFO_STRIDE 4

/* An active spell. Opaque: created by pm_cast, released by pm_free. */
typedef struct PmSpell PmSpell;

/* Start the runtime. Idempotent; call once before anything else. */
void pm_init(void);

/* Stop the runtime. Idempotent. Free every handle first. */
void pm_shutdown(void);

/* PM_ABI_VERSION as compiled into the library. */
int pm_abi_version(void);

/* The particle cap this build actually enforces -- the capacity each of
   pm_observe's six columns needs. Today it answers PM_MAX_PARTICLES; it
   is the value to allocate from, because unlike the macro it tracks the
   core (see PM_MAX_PARTICLES above). */
int pm_max_particles(void);

/* Compile a magic circle from UTF-8 JSON and cast it at (caster_pos,
   caster_facing) with the given seed. Returns NULL on failure, writing a
   human-readable, NUL-terminated, truncation-safe UTF-8 reason into
   err_buf (which may be NULL, as may the two vectors -- they then read as
   the origin facing +Z). */
PmSpell* pm_cast(const char* circle_json,
                 const float caster_pos[3], const float caster_facing[3],
                 uint64_t seed, char* err_buf, int err_len);

/* pm_cast with the failure classified: returns PM_OK, PM_ERR_JSON (the
   JSON did not decode) or PM_ERR_BUDGET (it did, but asks for more
   particles than PM_MAX_PARTICLES). *out_spell is the new handle, or NULL
   on any failure. */
int pm_cast_ex(const char* circle_json,
               const float caster_pos[3], const float caster_facing[3],
               uint64_t seed, char* err_buf, int err_len,
               PmSpell** out_spell);

/* Advance the spell's clock by dt seconds. Sampling happens in
   pm_observe, so several fixed steps per rendered frame cost nothing
   extra. */
void pm_advance(PmSpell* spell, float dt);

/* 1 once the spell has outlived its lifetime, 0 while it is running. */
int pm_is_finished(const PmSpell* spell);

/* Seconds since this spell was cast. */
double pm_age(const PmSpell* spell);

/* Sample the spell at its current age into six caller-owned columns of
   `capacity` elements each, plus one batch descriptor per batch:
   batch_info[4*i + 0] = offset of the batch's first particle,
   batch_info[4*i + 1] = particle count, [+2] = PM_BLEND_*, [+3] = PM_SHAPE_*.
   Returns the number of batches written (>= 0), or PM_ERR_CAPACITY if the
   particles do not fit in `capacity`, the batches do not fit in
   `max_batches`, or a needed pointer is NULL. On the error path nothing is
   written at all -- the host never sees a half-updated frame.

   The `color` column is packed 0xRRGGBBAA -- R in the highest byte, A in
   the lowest:

       uint8_t r = (c >> 24) & 0xFF;
       uint8_t g = (c >> 16) & 0xFF;
       uint8_t b = (c >>  8) & 0xFF;
       uint8_t a =  c        & 0xFF;

   It is already interpolated along the spell's colour curve by `life`, so
   there is no palette to look up; alpha usually reaches zero at the end
   of a particle's life. `size` is the billboard's half-extent (edge
   length = 2 * size) and `life` runs 0 (just born) to 1 (about to die). */
int pm_observe(PmSpell* spell,
               float* pos_x, float* pos_y, float* pos_z,
               float* size, float* life, uint32_t* color,
               int capacity, int* batch_info, int max_batches);

/* Orthographic projection of `count` abstract-space positions onto
   PM_PLANE_*: plane coordinates into out_x / out_y, painter's depth into
   out_depth (larger = further away). No spell handle: projection is a
   function of the positions alone, so any columns will do -- pm_observe's
   output, one batch of it, or your own.

   Returns PM_OK, or PM_ERR_ARGS (NULL where a pointer is needed, negative
   count, unknown plane) with nothing written at all. */
int pm_project(int plane,
               const float* pos_x, const float* pos_y, const float* pos_z,
               int count,
               float* out_x, float* out_y, float* out_depth);

/* Painter's order for `count` positions: out_indices receives
   [0 .. count-1] permuted far to near, equal depths keeping their input
   order. Draw in this order and nearer particles land on top without a
   depth buffer -- which is what a 2D host needs for PM_BLEND_ALPHA
   batches (additive batches commute and need no sorting).

   Returns PM_OK, or PM_ERR_ARGS with nothing written. */
int pm_depth_order(int plane,
                   const float* pos_x, const float* pos_y, const float* pos_z,
                   int count, int* out_indices);

/* Release a handle. Freeing NULL is a no-op; freeing twice is undefined
   behaviour, as in any C API. */
void pm_free(PmSpell* spell);

#ifdef __cplusplus
}
#endif

#endif /* PARTICLE_MAGIC_H */
