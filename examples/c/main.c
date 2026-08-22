/* main.c -- the smallest possible C host for the particle magic library
 * (func-spec 0009 §8 S6).
 *
 * It does what a game engine does, minus the drawing: load a spell file,
 * cast it, then run 120 frames of advance + observe, feeding nothing to a
 * GPU and instead printing one line per frame. Those lines are the manual
 * smoke's evidence: they must match the in-process reference exactly,
 * which is what makes "the library is complete, rendering lives outside
 * it" a checkable statement rather than a slogan.
 *
 * Build (Windows, from the repo root, after `cabal build particle-magic-ffi`):
 *
 *   cabal build particle-magic-ffi
 *   DLL=$(find dist-newstyle -name 'particle-magic-ffi.dll' | head -1)
 *   cp "$DLL" .
 *   gcc -Iinclude examples/c/main.c particle-magic-ffi.dll -o pm_demo.exe
 *   ./pm_demo.exe assets/spells/ring-fire.json
 *
 * Build (Linux/macOS): the same, with libparticle-magic-ffi.so and
 * -L/-lparticle-magic-ffi (plus -Wl,-rpath,. so the loader finds it).
 */
#include <stdio.h>
#include <stdlib.h>

#include "particle_magic.h"

#define MAX_BATCHES 8
#define FRAMES 120

/* One fixed step, in both precisions. pm_plan_steps plans in double (a
   float accumulator drifts against a double simulation); pm_advance_ex
   takes a float. Deriving one from the other is what keeps the planned
   time and the advanced time the same number rather than two numbers that
   slowly disagree. */
#define FIXED_DT_F (1.0f / 60.0f)
#define FIXED_DT   ((double)FIXED_DT_F)

/* The ceiling on steps in one frame -- the spiral-of-death guard. 8 is
   the value the repo's own demo shell has run on (app/Main.hs,
   lcMaxStepsPerFrame). */
#define MAX_STEPS_PER_FRAME 8

/* The six SoA columns a host would otherwise map straight onto a vertex
   buffer. Allocated once from pm_max_particles(), refilled every frame.
   Same shape as examples/c/scene.c, which sizes from the scene's cap. */
struct columns {
    float    *pos_x, *pos_y, *pos_z, *size, *life;
    uint32_t *color;
    int       capacity;
};

static int alloc_columns(struct columns *c, int capacity)
{
    c->capacity = capacity;
    c->pos_x = (float *)malloc((size_t)capacity * sizeof(float));
    c->pos_y = (float *)malloc((size_t)capacity * sizeof(float));
    c->pos_z = (float *)malloc((size_t)capacity * sizeof(float));
    c->size  = (float *)malloc((size_t)capacity * sizeof(float));
    c->life  = (float *)malloc((size_t)capacity * sizeof(float));
    c->color = (uint32_t *)malloc((size_t)capacity * sizeof(uint32_t));
    return c->pos_x && c->pos_y && c->pos_z && c->size && c->life && c->color;
}

static void free_columns(struct columns *c)
{
    free(c->pos_x); free(c->pos_y); free(c->pos_z);
    free(c->size);  free(c->life);  free(c->color);
}

static char *read_file(const char *path, long *size_out)
{
    FILE *f = fopen(path, "rb");
    char *buffer;
    long size;

    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);

    buffer = (char *)malloc((size_t)size + 1);
    if (!buffer) {
        fclose(f);
        return NULL;
    }
    if (fread(buffer, 1, (size_t)size, f) != (size_t)size) {
        fprintf(stderr, "short read on %s\n", path);
        free(buffer);
        fclose(f);
        return NULL;
    }
    buffer[size] = '\0';
    fclose(f);
    if (size_out) {
        *size_out = size;
    }
    return buffer;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "assets/spells/ring-fire.json";
    const float caster_pos[3]    = {1.5f, 0.25f, -2.0f};
    const float caster_facing[3] = {0.0f, 0.0f, 1.0f};

    struct columns cols;
    static int     batch_info[MAX_BATCHES * PM_BATCH_INFO_STRIDE];

    char      err[512];
    char     *json;
    PmSpell  *spell;
    int       frame;
    int       cap;
    double    acc = 0.0;

    pm_init();

    if (pm_abi_version() != PM_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch: library %d, header %d\n",
                pm_abi_version(), PM_ABI_VERSION);
        pm_shutdown();
        return 2;
    }

    /* Ask the library how big the columns have to be. The header's frozen
       macro is this ABI's floor, not the cap this build enforces -- sizing
       from it would refuse every spell between the two numbers, and the
       all-or-nothing rule turns that refusal into a frame that is not
       drawn at all. */
    cap = pm_max_particles();
    if (!alloc_columns(&cols, cap)) {
        fprintf(stderr, "out of memory for %d particles\n", cap);
        free_columns(&cols);
        pm_shutdown();
        return 1;
    }

    json = read_file(path, NULL);
    if (!json) {
        free_columns(&cols);
        pm_shutdown();
        return 1;
    }

    err[0] = '\0';
    spell = pm_cast(json, caster_pos, caster_facing, 20260814u, err, (int)sizeof err);
    free(json);
    if (!spell) {
        fprintf(stderr, "cast failed: %s\n", err);
        free_columns(&cols);
        pm_shutdown();
        return 1;
    }

    printf("spell: %s\n", path);
    for (frame = 0; frame < FRAMES; ++frame) {
        int    batches;
        int    i;
        int    steps = 0;
        int    total = 0;
        double checksum = 0.0;

        /* A real host passes the measured wall-clock delta here. This is a
           headless smoke with no clock, so it synthesises exactly one
           fixed step's worth: the planner answers 1 step and hands back an
           accumulator of 0, every frame. */
        if (pm_plan_steps(FIXED_DT, MAX_STEPS_PER_FRAME, FIXED_DT, acc,
                          &steps, &acc) != PM_OK) {
            fprintf(stderr, "frame %d: pm_plan_steps failed\n", frame);
            pm_free(spell);
            free_columns(&cols);
            pm_shutdown();
            return 1;
        }
        while (steps-- > 0) {
            if (pm_advance_ex(spell, FIXED_DT_F) != PM_OK) {
                fprintf(stderr, "frame %d: pm_advance_ex failed\n", frame);
                pm_free(spell);
                free_columns(&cols);
                pm_shutdown();
                return 1;
            }
        }

        batches = pm_observe(spell, cols.pos_x, cols.pos_y, cols.pos_z,
                             cols.size, cols.life, cols.color,
                             cols.capacity, batch_info, MAX_BATCHES);
        if (batches < 0) {
            fprintf(stderr, "frame %d: pm_observe failed with %d\n", frame, batches);
            pm_free(spell);
            free_columns(&cols);
            pm_shutdown();
            return 1;
        }

        for (i = 0; i < batches; ++i) {
            total += batch_info[i * PM_BATCH_INFO_STRIDE + 1];
        }
        for (i = 0; i < total; ++i) {
            checksum += (double)cols.pos_x[i] + (double)cols.pos_y[i]
                      + (double)cols.pos_z[i]
                      + (double)cols.size[i] + (double)cols.life[i];
        }

        printf("frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f\n",
               frame, pm_age(spell), batches, total,
               batches > 0 ? batch_info[2] : -1, checksum);
    }

    printf("finished: %d\n", pm_is_finished(spell));

    /* Freeing twice is safe (the handle is generation-tagged and the
       second call is a no-op), and so is shutting down twice; the smoke
       still frees exactly once, which is what a host should do. */
    pm_free(spell);
    free_columns(&cols);
    pm_shutdown();
    pm_shutdown();
    return 0;
}
