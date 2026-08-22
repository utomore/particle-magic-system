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
 *
 *   int cap = pm_max_particles();
 *   ...  allocate px, py, pz, size, life and color: cap elements each.
 *        Ask the query, never the PM_MAX_PARTICLES macro -- see below ...
 *
 *   PmSpell* s = pm_cast(json, pos, facing, 42, err, sizeof err);
 *   if (!s) { fprintf(stderr, "%s\n", err); return 1; }
 *
 *   double acc = 0.0;
 *   while (!pm_is_finished(s)) {
 *       int steps;
 *       pm_plan_steps(1.0 / 60.0, 8, seconds_since_last_frame,
 *                     acc, &steps, &acc);
 *       while (steps-- > 0) pm_advance_ex(s, 1.0f / 60.0f);
 *       int n = pm_observe(s, px, py, pz, size, life, color,
 *                          cap, info, 8);
 *       ...  feed your vertex buffer from the six arrays ...
 *   }
 *   pm_free(s);
 *   pm_shutdown();
 *
 * The 8 handed to pm_plan_steps is the ceiling on steps in one frame --
 * the spiral-of-death guard. See "Fixed timesteps" at the bottom of this
 * header for why the loop is not a hand-rolled while (acc >= dt).
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
 *   double acc = 0.0;
 *   for (;;) {
 *       int steps;
 *       pm_plan_steps(1.0 / 60.0, 8, seconds_since_last_frame,
 *                     acc, &steps, &acc);
 *       while (steps-- > 0) pm_scene_advance_ex(sc, 1.0f / 60.0f);
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
 * Threading works the same for a scene as for a spell -- see the Threading
 * section below; concurrent casts into one scene count the quota once per
 * spell, not once per thread.
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
 * Threading (host-runtime F004, ADR-022 D4):
 *
 * Three promises first, because they are what you would otherwise have to
 * discover by experiment.
 *
 *   * This library never starts an OS thread of its own. Every line of it
 *     runs on a thread you called it from.
 *   * The per-frame path -- advancing, observing, any query -- takes no
 *     lock at all. Nothing you call once a frame can block on anything
 *     else this library is doing.
 *   * An internal failure poisons ONE handle. That handle answers
 *     PM_ERR_INTERNAL from then on (or its sentinel, for the entry points
 *     with no error channel); every other handle, and your process, carry
 *     on untouched.
 *
 * Safe to run concurrently -- the library's problem, not yours:
 *
 *   * Any operations on different handles, with no restriction.
 *   * Several advances of the SAME handle: no lost updates. N concurrent
 *     pm_advance calls move the clock exactly N steps, never N-1.
 *   * Several pm_scene_cast / pm_scene_cast_many / pm_scene_dismiss calls
 *     on the same scene: no lost updates either, and the quota is counted
 *     once per spell. Cast twice into a scene with room for one and you
 *     get one PM_OK and one PM_ERR_QUOTA, never two of either.
 *   * An advance concurrent with an observe or a query: the reader sees a
 *     complete snapshot, from before the step or from after it, never half
 *     of each.
 *   * pm_abi_version, pm_max_particles, pm_project, pm_depth_order and
 *     pm_plan_steps: stateless, any thread, any time.
 *
 * Yours to serialise -- the library cannot see enough to do it for you:
 *
 *   * pm_free / pm_scene_free against any other call on the SAME handle.
 *     The handle dies the moment it is freed, so a concurrent call lands
 *     on either side of that: it either runs or answers PM_ERR_ARGS.
 *     Neither crashes, but which one you get is not defined.
 *   * pm_init / pm_init_ex / pm_shutdown against any call at all. Those
 *     are the runtime's lifecycle, not a handle's.
 *   * Two observes writing into the SAME host arrays. That memory is
 *     yours; the library cannot know two calls share it.
 *   * Handing a handle to another thread. Publish it through a queue, a
 *     lock or a job dependency, as with any C API -- the handle is only
 *     visible to a thread that got it through a real synchronisation.
 *   * An advance and an observe you need PAIRED ("this frame's picture
 *     must be this frame's step"). Both are safe; their order is not
 *     promised.
 *
 * What is NOT promised, precisely: the ORDER of concurrent operations on
 * one handle. Only that none of them is dropped. For advancing that is a
 * distinction without a difference -- each step adds the same dt to
 * whatever came before, so the end state is the same however they
 * interleave -- but the ids handed out by concurrent casts arrive in no
 * particular order.
 *
 * Handle safety: every handle is generation-tagged. It is not a pointer
 * you may dereference -- it is an opaque token whose value encodes which
 * table it belongs to, which slot, and which generation of that slot.
 * Pass one back that has already been freed, free one twice,
 * forge one, or hand a PmScene* to a PmSpell* entry point, and the
 * library recognises it and answers PM_ERR_ARGS. It does NOT read freed
 * memory and it does NOT terminate your process (ADR-022 D3, revising
 * ADR-0011 D4). Seven frozen entry points have no error channel to say it
 * with, and keep the same promise by doing nothing at all: pm_advance,
 * pm_free, pm_scene_free, pm_scene_dismiss and pm_scene_advance return
 * void and are no-ops; pm_age returns 0.0; pm_occupancy_mask returns 0.
 * Two of those seven have a variant that can say it -- pm_advance_ex and
 * pm_scene_advance_ex return PM_ERR_ARGS where the void pair silently
 * does nothing -- so a host that wants the diagnosis calls those instead.
 * The one case that cannot be caught is a forged value that happens to
 * equal a currently live handle -- that is the shared ceiling of any
 * handle scheme, not a gap in this one.
 *
 * Never terminates your process: every entry point here runs inside an
 * exception firewall (ADR-022 D2). Whatever goes wrong inside the library
 * -- exhausted memory, a defect, a case nobody wrote -- it is caught at
 * this boundary and reported as PM_ERR_INTERNAL rather than taking your
 * host down with it. The seven entry points with no error channel answer
 * their own equivalent: pm_cast and pm_scene_new return NULL, pm_age
 * returns -6.0 (an age is never negative, so the value is unambiguous),
 * pm_occupancy_mask returns 0, and the five void ones do nothing. When
 * the call carries an err_buf, the reason is written there in the usual
 * truncation-safe UTF-8.
 *
 * PM_ERR_INTERNAL from pm_is_finished is -6, which C reads as true, so
 * the usual `while (!pm_is_finished(s))` loop ends rather than spinning
 * forever on a spell that can no longer answer.
 *
 * Two things this promise does NOT include. It is not an error-handling
 * channel: a well-behaved call never sees PM_ERR_INTERNAL, and one that
 * does has found a bug in this library, not in your code. And it is not
 * all-or-nothing -- pm_observe guarantees that a PM_ERR_CAPACITY failure
 * writes no byte at all, while an exception raised part way through a
 * copy may leave your arrays half updated. On that path the library
 * promises exactly two things: it returns, and it says PM_ERR_INTERNAL.
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

/* This ABI's first-generation capacity FLOOR, frozen at 4096 forever. It
   is not the cap and it does not mirror anything: the core's own cap has
   been higher than this since func-spec 0012, and being frozen this macro
   could not follow. What it is good for is exactly one thing -- code
   compiled against any version of this header allocates a buffer the
   library will never overrun. */
#define PM_MAX_PARTICLES 4096

/* ... so size your columns from pm_max_particles() instead. The query
   follows the core, the macro cannot (func-spec 0011 section 2). A host
   that sizes from the macro is not broken -- it keeps working, and keeps
   getting PM_ERR_CAPACITY out of pm_observe for every spell that wants
   more than PM_MAX_PARTICLES particles, which the all-or-nothing rule
   turns into a frame that is not drawn at all. */

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

/* The firewall caught an exception: something inside the library is
   broken (ADR-022 D2). Never your call's fault, never worth retrying --
   but always worth a bug report. The library stays usable and, above all,
   your process stays alive. See "Never terminates your process" below. */
#define PM_ERR_INTERNAL (-6)

/* You called out of order: using the library before pm_init, or
   initialising again after pm_shutdown. */
#define PM_ERR_STATE (-7)

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
/* Stretched along each particle's own velocity. The stretch is NOT a
   batch parameter -- there is no room for one and never will be, see
   PM_BATCH_INFO_STRIDE -- it is derived per particle from the velocity
   columns pm_observe_ex hands out. A host that wants trails must call
   pm_observe_ex; one that calls pm_observe still gets these batches and
   may draw them as PM_SHAPE_SQUARE, which is the pre-trail picture. */
#define PM_SHAPE_TRAIL 4

/* Ints per batch in the batch_info array: offset, count, blend, shape.
   Frozen. A shape with parameters would need a wider stride, which is
   exactly why no shape has parameters (ADR-0013, ADR-0018). */
#define PM_BATCH_INFO_STRIDE 4

/* An active spell. Opaque: created by pm_cast, released by pm_free. */
typedef struct PmSpell PmSpell;

/* --- The runtime (host-runtime F003, ADR-022 D1) ------------------------
 *
 * The library is Haskell inside, so it carries the GHC runtime with it.
 * That runtime is YOURS to configure: this library never starts OS threads
 * behind your back and never picks a capability count for you.
 *
 * One state machine governs it, and both platforms answer identically
 * because the answer comes from the machine rather than from the runtime:
 *
 *     UNINIT --(pm_init / pm_init_ex)--> RUNNING --(pm_shutdown)--> CLOSED
 *        |                                                            |
 *        +----- every other entry point answers PM_ERR_STATE ---------+
 *
 * Before pm_init and after pm_shutdown every entry point answers a
 * sentinel instead of entering the runtime, because entering it is what
 * would end your process: the counting ones return PM_ERR_STATE, pm_cast
 * and pm_scene_new return NULL (with the reason in err_buf where there is
 * one), pm_age returns -7.0, pm_occupancy_mask returns 0, and the five
 * void ones do nothing. pm_abi_version is the one exception -- the C layer
 * answers it directly, so a startup generation check is safe before
 * pm_init.
 *
 * pm_shutdown is a ONE-WAY DOOR. Afterwards this process may not use the
 * library again: pm_init_ex answers PM_ERR_STATE, pm_init does nothing,
 * and every other symbol keeps answering its sentinel. A long-lived host
 * (a game engine, the Unity editor) should simply never call it. Same rule
 * on Windows and on Linux.
 *
 * Which settings take effect where
 * --------------------------------
 * Measured 2026-08-20 against the shipped artefacts; macOS is inferred
 * from the Linux path and has not been run.
 *
 *     platform                        caps  nursery  gc_mode  stats
 *     windows x86_64 (standalone DLL)  yes    yes      yes     yes
 *     linux x86_64 (.so)               yes    yes      yes     yes
 *     macos (.dylib, not yet run)      yes    yes      yes     yes
 *
 *     any platform, but the GHC runtime was ALREADY running in this
 *     process before you asked (a Haskell host, or you called hs_init
 *     yourself):
 *                                      yes     no       no      no
 *
 * On that last row pm_init_ex answers PM_ERR_STATE, the capability count
 * still takes effect through the runtime's own API, and the library is
 * up and usable. Nothing is ever ignored in silence.
 *
 * PM_ERR_STATE therefore says one of two things, and they are easy to tell
 * apart because the second can only ever happen on your FIRST call:
 *
 *   1. the call was out of order -- nothing happened at all; or
 *   2. the library is up and usable, but part of your configuration could
 *      not be applied in this process (the row above).
 *
 * Capabilities and the parallel sampler: sampling splits a window of 8192
 * rows or more across capabilities. At capabilities = 1 that split costs
 * something and buys nothing, so a host that samples large spells wants
 * 2..4 -- and usually NOT 0 (every core on the machine), which competes
 * with your own job system. The output is identical either way (ADR-0017).
 */

/* GC mode for PmConfig.gc_mode. */
#define PM_GC_DEFAULT 0
#define PM_GC_NONMOVING 1

/* Runtime statistics for PmConfig.stats. The runtime can only be told to
   collect them WHILE STARTING UP, so a host that wants the process-wide GC
   numbers has to say so here. Without it getRTSStatsEnabled() is false and
   those numbers are reported as UNAVAILABLE -- not as zero, which is what
   the runtime itself hands back and is indistinguishable from "nothing
   paused for GC". */
#define PM_STATS_OFF 0
#define PM_STATS_ON 1

/* Bounds pm_init_ex validates PmConfig against. Outside them it answers
   PM_ERR_ARGS and starts nothing -- the runtime would otherwise abort the
   whole process on a bad value. */
#define PM_MAX_CAPABILITIES 256
#define PM_NURSERY_MIN_BYTES 8192
#define PM_NURSERY_MAX_BYTES 1073741824

/* Runtime settings. Zero the whole struct, set size to sizeof(PmConfig),
   fill in what you care about. Add-only: a later generation may append
   fields, and `size` is how this library knows which ones you compiled
   against. A size it does not recognise is PM_ERR_ARGS rather than a
   silent partial application. */
typedef struct PmConfig {
    uint32_t size;           /* sizeof(PmConfig) */
    uint32_t capabilities;   /* 0 = follow the hardware; else 1..PM_MAX_CAPABILITIES */
    uint64_t nursery_bytes;  /* 0 = the runtime's default (4 MiB) */
    uint32_t gc_mode;        /* PM_GC_DEFAULT or PM_GC_NONMOVING */
    uint32_t stats;          /* PM_STATS_OFF or PM_STATS_ON -- decided only here */
} PmConfig;

/* Start the runtime with the host's settings. Call it INSTEAD of pm_init,
   once, before anything else.

   Returns PM_OK; PM_ERR_ARGS, meaning the config is out of range and
   nothing was started; or PM_ERR_STATE in either of the two senses above.

       PmConfig cfg = {0};
       cfg.size = sizeof cfg;
       cfg.capabilities = 4;
       cfg.stats = PM_STATS_ON;
       int rc = pm_init_ex(&cfg);
*/
int pm_init_ex(const PmConfig* config);

/* Start the runtime with the library's conservative defaults: one
   capability, the default collector, no statistics. Idempotent; call once
   before anything else. After pm_shutdown it does nothing at all. */
void pm_init(void);

/* Stop the runtime. Idempotent, and a one-way door: see above. Free every
   handle first. */
void pm_shutdown(void);

/* PM_ABI_VERSION as compiled into the library. */
int pm_abi_version(void);

/* The particle cap this build actually enforces -- the capacity each of
   pm_observe's six columns needs.

   It already answers more than PM_MAX_PARTICLES, and will answer more
   again the next time the core's cap rises -- which is precisely why it,
   and not the frozen macro, is the value to allocate from (see
   PM_MAX_PARTICLES above). */
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
   particles than pm_max_particles() reports -- the enforced cap, not the
   frozen macro). *out_spell is the new handle, or NULL on any failure. */
int pm_cast_ex(const char* circle_json,
               const float caster_pos[3], const float caster_facing[3],
               uint64_t seed, char* err_buf, int err_len,
               PmSpell** out_spell);

/* Advance the spell's clock by dt seconds. Sampling happens in
   pm_observe, so several fixed steps per rendered frame cost nothing
   extra.

   A dt that is NaN, infinite or negative does nothing at all -- the
   clock is not moved by one bit. It used to poison the age, after which
   pm_is_finished answered 0 forever and a `while (!pm_is_finished(s))`
   loop never ended. A dt of 0 is legal and is likewise a no-op. This
   returns void and so cannot say which of the two happened; pm_advance_ex
   below is the same call with that one answer added. */
void pm_advance(PmSpell* spell, float dt);

/* pm_advance with the argument check reported: PM_OK, or PM_ERR_ARGS --
   leaving the spell's clock untouched -- for a NULL or otherwise invalid
   handle and for a dt that is NaN, infinite or negative. A dt of 0 is
   legal and is a no-op. For every legal dt this and pm_advance run the
   identical code and produce identical state. */
int pm_advance_ex(PmSpell* spell, float dt);

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

/* pm_observe plus three velocity columns, in units per second.

   Same batch semantics, same batch_info layout and stride, same
   all-or-nothing capacity rule -- the two share one implementation. The
   six original columns are bit-for-bit what pm_observe writes; pm_observe
   IS this function with vel_x/vel_y/vel_z NULL, so an existing host needs
   no recompile and sees no change whatsoever.

   The three velocity pointers are optional and independent: pass NULL for
   any you do not want. A spell whose circle contains no "trail" style
   computes no velocity, and then a non-NULL column is filled with zeros
   rather than reported as an error -- whether a given spell trails is the
   spell's business, and the host's call should not have to change shape
   because the player loaded a different circle.

   Velocity is the backward difference of the particle's rendered position
   over a fixed 1/240 s step, plus the force-field layer's own integrated
   velocity where fields apply. It is therefore deterministic and frame
   rate independent: the same spell trails identically at 30 and 240 fps.
   A particle in its first 1/240 s is differenced one-sidedly from birth,
   and one at exactly age 0 reports zero.

   To draw a PM_SHAPE_TRAIL batch: stretch each particle's quad along its
   velocity direction, by a length that grows with |v| -- and clamp that
   length, or a fast particle will streak across the whole screen. */
int pm_observe_ex(PmSpell* spell,
                  float* pos_x, float* pos_y, float* pos_z,
                  float* size, float* life, uint32_t* color,
                  float* vel_x, float* vel_y, float* vel_z,
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

/* Release a handle. Freeing NULL is a no-op, and so is freeing a handle
   that is already released, was never issued here, or belongs to the other
   handle space -- see "Handle safety" above. */
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
   that admits nothing.

   Returns NULL only when no scene could be made at all: before pm_init
   or after pm_shutdown (see the state machine above), if the firewall
   catches an internal failure, or if the handle registry has no slot
   left -- which takes 2^30 live handles and so is not reachable by any
   real host. Not a cap refusal and not an argument error; those are
   reported by pm_scene_cast, not here. Check it anyway: it costs one
   branch and it is the only wrong answer this call can give. */
PmScene* pm_scene_new(int global_cap);

/* Release a scene and everything still live inside it. Freeing NULL is a
   no-op, and so is freeing a scene handle that is already released or was
   never issued here -- see "Handle safety" above. */
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
   -- which is also how their share of the quota is released.

   Same dt rule as pm_advance: NaN, infinite or negative does nothing at
   all, zero is a legal no-op. */
void pm_scene_advance(PmScene* scene, float dt);

/* pm_scene_advance with the same check reported, exactly as
   pm_advance_ex reports pm_advance's. */
int pm_scene_advance_ex(PmScene* scene, float dt);

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

/* --- Fixed timesteps (host-runtime F005) --------------------------------
 *
 * Your render frame rate and this library's simulation step are separate
 * things, and the accumulator that keeps them separate is YOURS -- this
 * library holds no per-spell clock of its own for it. What it does hold
 * is the arithmetic, and there is exactly one copy of it:
 *
 *     static double acc = 0.0;
 *     int steps;
 *     pm_plan_steps(1.0 / 120.0, 8, frame_seconds, acc, &steps, &acc);
 *     for (int i = 0; i < steps; i++) pm_advance(spell, 1.0f / 120.0f);
 *
 * The hand-rolled `while (acc >= FIXED_DT)` this replaces has two faults
 * that only show up in the field. It has no clamp, so one loading hitch
 * or one breakpoint asks for hundreds of steps in a single frame and the
 * next frame is later still -- the spiral of death. And its accumulator
 * is usually a float, which drifts against a double simulation. Both are
 * fixed by looping *out_steps times instead.
 */

/* Plan one frame's fixed steps. Pure: it reads and writes nothing but its
   own arguments, and is the same implementation the library uses
   internally, so a host driving its loop with this steps bit-identically
   with one written in Haskell.

   Double precision on purpose -- a float accumulator drifts. pm_advance's
   float dt is unaffected.

   dt <= 0 plans zero steps and hands the accumulator back untouched (it
   is a setting, not a per-frame input, so unlike pm_advance's dt it is
   not rejected). A negative elapsed reads as zero. When the backlog
   exceeds max_steps the plan clamps to max_steps and DROPS the rest, so
   the simulation slows down instead of freezing.

   Returns PM_OK, or PM_ERR_ARGS -- writing nothing at all -- when either
   out pointer is NULL, when dt, elapsed or acc_in is not finite, when
   max_steps is negative, or when acc_in is negative. On PM_OK,
   *out_steps is in [0, max_steps] and *out_acc is >= 0.

   Needs the runtime: call pm_init() or pm_init_ex() first, as for every
   other entry point here. Being a pure function does not exempt it --
   the point of this call is that it is not a second copy of the
   planner, and reaching the only copy means crossing into the runtime.
   Before it is up, this returns PM_ERR_STATE and writes nothing. */
int pm_plan_steps(double dt, int max_steps, double elapsed, double acc_in,
                  int* out_steps, double* out_acc);

#ifdef __cplusplus
}
#endif

#endif /* PARTICLE_MAGIC_H */
