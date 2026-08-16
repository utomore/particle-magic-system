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
 * Scenes:
 *
 * The loop above drives ONE cast. A host that wants several alive at once
 * -- a fireball still burning while a shield goes up -- opens a scene
 * instead (func-spec 0018, ADR-0012):
 *
 *   PmScene* sc = pm_scene_new(8192);
 *   int id;
 *   if (pm_scene_cast(sc, json, pos, facing, 42, err, sizeof err, &id) != PM_OK)
 *       fprintf(stderr, "%s\n", err);
 *   for (;;) {
 *       pm_scene_advance(sc, 1.0f / 60.0f);
 *       int n = pm_scene_observe(sc, px, py, pz, size, life, color,
 *                                MY_CAPACITY, info, MY_MAX_BATCHES);
 *       ...  same six columns, same batch_info layout as pm_observe ...
 *   }
 *   pm_scene_free(sc);
 *
 * Two things to get right:
 *
 *   * Size your columns from the scene's own global_cap, NOT from
 *     pm_max_particles(). The query bounds ONE spell; a scene may hold
 *     several, so its total is whatever cap you asked for. Getting this
 *     backwards shows up as PM_ERR_CAPACITY on the second cast, not the
 *     first.
 *   * Pick one mode per cast and stay in it. A spell inside a scene has
 *     no PmSpell* of its own -- there is no way to hand one to pm_free,
 *     and no way to move an existing PmSpell* into a scene. Single cast:
 *     pm_cast + pm_free. Several: pm_scene_cast + pm_scene_dismiss.
 *
 * Threading is per handle here too: one scene is owned by one thread.
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
 * produces bit-identical output through either consumption path
 * (ADR-0011 D8), on a given platform. Across platforms the guarantee is
 * the structure -- the same particles, in the same order, in the same
 * counts -- but the position columns can differ in their last bit or
 * two: C's sin() and cos() are not required to be correctly rounded, and
 * two libm implementations legitimately disagree on the last ulp. The
 * measured spread between windows/x86_64 and linux/x86_64 is at most
 * 1.79e-07 in pos_x and pos_z, with size, life and color bit-identical
 * (func-spec 0019 S2, ADR-0016). Replay a recording on the machine that
 * made it and it is exact; compare two machines and compare with a
 * tolerance.
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

/* Scene quota refusal: the spell itself compiles, but the scene's
   global_cap has no room left for it (func-spec 0018). Only the
   pm_scene_cast* entry points can return it. */
#define PM_ERR_QUOTA (-5)

/* Grid dimension whose cell count fits one uint32_t: 3*3*3 = 27 <= 32,
   which is what lets pm_occupancy_mask answer without an array
   (func-spec 0025). 27 is this system's own nine-grid -- up/down/left/
   right plus center -- extruded along the face normal. */
#define PM_OCCUPANCY_DIM_DEFAULT 3

/* Which axis the orthographic camera looks along, for pm_project and
   pm_depth_order (ADR-0008: "2D = drop one axis and pick a depth-sorting
   strategy"). Anything else is PM_ERR_ARGS. */
#define PM_PLANE_SIDE_XY 0   /* viewer at +Z: plane = (x, y), depth = -z */
#define PM_PLANE_TOP_XZ 1    /* viewer at +Y: plane = (x, z), depth = -y */

/* batch_info[4*i + 2] -- how the batch's particles are blended. */
#define PM_BLEND_ALPHA 0
#define PM_BLEND_ADDITIVE 1

/* batch_info[4*i + 3] -- the billboard geometry the batch expects. A host
   that predates a shape code may draw such batches as PM_SHAPE_SQUARE. */
#define PM_SHAPE_SQUARE 0
#define PM_SHAPE_SOFT_DOT 1
#define PM_SHAPE_RING 2
#define PM_SHAPE_SPARK 3

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

/* --- Scenes (func-spec 0018, ADR-0012) ---------------------------------
 *
 * Several casts alive at once under one global particle quota. Every
 * entry point below tolerates a NULL scene (no-op or neutral value), as
 * the single-spell ones tolerate a NULL PmSpell*.
 */

/* A scene: several casts alive at once under one global particle quota
   (func-spec 0012, ADR-0012). Opaque; created by pm_scene_new, released
   by pm_scene_free. A spell inside a scene has no PmSpell* of its own --
   pick one mode or the other, never both for the same cast. */
typedef struct PmScene PmScene;

/* global_cap = total particles the scene may hold across every live
   spell. Size YOUR six columns from this, not from pm_max_particles()
   (which bounds one spell). A negative cap is legal and means a scene
   that admits nothing. Never returns NULL in this generation. */
PmScene* pm_scene_new(int global_cap);

/* Release a scene and everything still live inside it. Freeing NULL is a
   no-op; freeing twice is undefined behaviour. */
void pm_scene_free(PmScene* scene);

/* Cast one circle into the scene. Returns PM_OK (with *out_id set to the
   new spell's id), PM_ERR_JSON, PM_ERR_BUDGET, PM_ERR_QUOTA or
   PM_ERR_ARGS, writing the reason into err_buf. On every failure path the
   scene is left exactly as it was. */
int pm_scene_cast(PmScene* scene, const char* circle_json,
                  const float caster_pos[3], const float caster_facing[3],
                  uint64_t seed, char* err_buf, int err_len, int* out_id);

/* The same, for `count` circles composed into ONE spell (the Monoid of
   func-spec 0012: emitters concatenated, budgets summed, phase landmarks
   maxed). circle_jsons is an array of `count` NUL-terminated UTF-8
   strings; count == 0 casts the empty composition. */
int pm_scene_cast_many(PmScene* scene, const char* const* circle_jsons, int count,
                       const float caster_pos[3], const float caster_facing[3],
                       uint64_t seed, char* err_buf, int err_len, int* out_id);

/* Remove a spell early. Unknown or already-finished ids are a no-op, so a
   host may dismiss without checking whether the spell outlived itself. */
void pm_scene_dismiss(PmScene* scene, int spell_id);

/* Advance every live spell by dt seconds and drop the ones that finished
   -- which is also how their share of the quota is released. */
void pm_scene_advance(PmScene* scene, float dt);

/* Sample every live spell into the caller's six columns, exactly as
   pm_observe does for one spell; batches are concatenated in spell-id
   order and are NOT merged across spells. Same batch_info layout, same
   PM_BATCH_INFO_STRIDE, same all-or-nothing error path. Which spell a
   batch came from is not reported (func-spec 0018 section 8). */
int pm_scene_observe(PmScene* scene,
                     float* pos_x, float* pos_y, float* pos_z,
                     float* size, float* life, uint32_t* color,
                     int capacity, int* batch_info, int max_batches);

/* *out_used = particles committed by the live spells, *out_cap =
   global_cap. Either pointer may be NULL. Returns PM_OK or PM_ERR_ARGS. */
int pm_scene_budget(const PmScene* scene, int* out_used, int* out_cap);

/* How many spells are live. 0 for a NULL scene. */
int pm_scene_count(const PmScene* scene);

/* The live spells' ids in admission order, into a caller-owned array.
   Returns the number written, or PM_ERR_CAPACITY (nothing written) when
   they do not fit in max_ids -- ask pm_scene_count first. */
int pm_scene_spells(const PmScene* scene, int* out_ids, int max_ids);

/* --- Where a spell is (func-spec 0025, ADR-0019) ------------------------
 *
 * The library's third output, after the six particle columns and errors:
 * a spatial summary, for broad-phase collision, AoE tests and frustum
 * culling. It is a QUERY, not part of pm_observe -- most spells are pure
 * visuals and should pay nothing for it.
 *
 * Read-only in the strongest sense: calling any of these advances no
 * clock and changes no particle, so the same pm_observe before and after
 * gives bit-identical columns.
 *
 * The core does not cull for you. It has no camera concept at all (the
 * abstract space does not know which dimension it is drawn in), so what
 * it owes a host is the envelope; the DECISION is the host's.
 *
 * An "oriented box" is a center, three orthonormal axes and three
 * half-extents along them. The axes come out as 9 floats, ROW MAJOR:
 * out_axes[0..2] = U (face right), [3..5] = V (face up), [6..8] = the
 * face normal. A box is much tighter than its AABB for the usual
 * spell -- a beam that flies 8 units forward does not claim 8 units
 * sideways -- so prefer it if your host can carry one; pm_spell_bounds
 * is the axis-aligned answer for hosts that would rather not.
 */

/* The whole spell's world AABB over its ENTIRE life (not just up to now),
   as two corners. PM_OK, or PM_ERR_ARGS with nothing written. */
int pm_spell_bounds(const PmSpell* spell, float out_min[3], float out_max[3]);

/* The same extent as an oriented box, in the caster's frame. Constant for
   the spell's whole life, and the frame pm_occupancy divides up. */
int pm_spell_box(const PmSpell* spell, float out_center[3],
                 float out_axes[9], float out_half[3]);

/* How many emitters this spell compiled to: the index range
   pm_emitter_box accepts. 0 for a NULL handle. */
int pm_emitter_count(const PmSpell* spell);

/* One emitter's box, fitted to what it can have reached BY NOW (unlike
   pm_spell_box, which covers the whole life). An index outside
   [0, pm_emitter_count) is PM_ERR_ARGS with nothing written. */
int pm_emitter_box(const PmSpell* spell, int index, float out_center[3],
                   float out_axes[9], float out_half[3]);

/* How many live particles fall in each cell of a dim*dim*dim grid over
   pm_spell_box's frame. Cell (k*dim + j)*dim + i counts the particles at
   step i along the box's U axis, j along V and k along the normal -- U
   fastest.

   The frame is fixed for the spell's whole life on purpose: cell 5 means
   the same region on frame 10 and frame 11, which is what makes "these
   particles entered that region" expressible at all. Early on, most
   cells are empty; that is information, not waste.

   Returns the number of cells written (dim*dim*dim), PM_ERR_ARGS for a
   non-positive dim or a NULL handle, or PM_ERR_CAPACITY when
   capacity < dim*dim*dim -- with nothing written at all. */
int pm_occupancy(PmSpell* spell, int dim, int* out_counts, int capacity);

/* The PM_OCCUPANCY_DIM_DEFAULT fast path: bit c is set exactly when cell
   c of a 3x3x3 pm_occupancy would be non-zero. One call, no array to
   size, no capacity to check -- an overlap test is one popcount or one
   bitwise AND. Bits 27..31 are always clear; a NULL handle answers 0. */
uint32_t pm_occupancy_mask(PmSpell* spell);

/* pm_spell_bounds for one spell inside a scene: pm_scene_spells hands out
   the ids, this hands out the boxes. An unknown id -- stale, finished,
   never issued -- is PM_ERR_ARGS with nothing written. There is no
   whole-scene union on purpose: folding these is three lines in the host,
   and a box around everything is a number almost nothing can use. */
int pm_scene_spell_bounds(const PmScene* scene, int spell_id,
                          float out_min[3], float out_max[3]);

#ifdef __cplusplus
}
#endif

#endif /* PARTICLE_MAGIC_H */
