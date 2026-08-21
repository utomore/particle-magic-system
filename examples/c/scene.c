/* scene.c -- a C host driving several spells at once (func-spec 0018 §7 S5).
 *
 * examples/c/main.c is the single-cast loop. This one is the other mode:
 * one PmScene* holding several casts under one global particle quota, so
 * a host does not have to keep its own book of live PmSpell* handles and
 * their sizes.
 *
 * It prints a trace of the four events that make a scene a scene, in
 * order, so the run is its own evidence:
 *
 *   1. two spells coexist, and pm_scene_budget accounts for both;
 *   2. a third is refused with PM_ERR_QUOTA -- and the scene is
 *      completely unchanged by the refusal;
 *   3. the first spell reaches the end of its life, and its share of the
 *      quota comes back on its own (nobody freed anything);
 *   4. the third cast, retried, now succeeds.
 *
 * Build (Windows, from the repo root):
 *
 *   cabal build flib:particle-magic-ffi
 *   DLL=$(find dist-newstyle -name 'particle-magic-ffi.dll' | head -1)
 *   cp "$DLL" .
 *   gcc -Iinclude examples/c/scene.c particle-magic-ffi.dll -o pm_scene.exe
 *   ./pm_scene.exe assets/spells/ring-fire.json
 *
 * Build (Linux/macOS): the same, with libparticle-magic-ffi.so and
 * -L/-lparticle-magic-ffi (plus -Wl,-rpath,. so the loader finds it).
 */
#include <stdio.h>
#include <stdlib.h>

#include "particle_magic.h"

#define MAX_BATCHES 64
#define MAX_SPELLS 16
#define SEED 20260814u

/* One fixed step in both precisions, and the per-frame step ceiling --
   same discipline and same value as examples/c/main.c. */
#define FIXED_DT_F (1.0f / 60.0f)
#define FIXED_DT   ((double)FIXED_DT_F)
#define MAX_STEPS_PER_FRAME 8

static const float caster_pos[3]    = {1.5f, 0.25f, -2.0f};
static const float caster_facing[3] = {0.0f, 0.0f, 1.0f};

/* The six SoA columns, sized from the scene's own cap rather than from
   pm_max_particles(): the query bounds ONE spell, a scene holds several. */
struct columns {
    float    *pos_x, *pos_y, *pos_z, *size, *life;
    uint32_t *color;
    int       batch_info[MAX_BATCHES * PM_BATCH_INFO_STRIDE];
    int       capacity;
};

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    char *buffer;
    long  size;

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
    return buffer;
}

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

/* What one cast of this circle costs the quota. There is no way to ask
   without casting, so ask a throw-away scene with room for anything. */
static int probe_budget(const char *json)
{
    PmScene *probe = pm_scene_new(1 << 24);
    char     err[512];
    int      id = -1, used = -1, cap = 0;

    err[0] = '\0';
    if (pm_scene_cast(probe, json, caster_pos, caster_facing, SEED,
                      err, (int)sizeof err, &id) != PM_OK) {
        fprintf(stderr, "probe cast failed: %s\n", err);
    } else {
        pm_scene_budget(probe, &used, &cap);
    }
    pm_scene_free(probe);
    return used;
}

/* PM_OK -> the new id; anything else -> the code, with the reason
   printed. Either way the caller learns what the scene did. */
static int cast_into(PmScene *scene, const char *json, const char *label)
{
    char err[512];
    int  id = -1;
    int  used = 0, cap = 0;
    int  code;

    err[0] = '\0';
    code = pm_scene_cast(scene, json, caster_pos, caster_facing, SEED,
                         err, (int)sizeof err, &id);
    pm_scene_budget(scene, &used, &cap);
    if (code == PM_OK) {
        printf("cast %s -> id %d   (spells %d, quota %d/%d)\n",
               label, id, pm_scene_count(scene), used, cap);
    } else {
        printf("cast %s -> %s (%d): %s   (spells %d, quota %d/%d)\n",
               label,
               code == PM_ERR_QUOTA    ? "PM_ERR_QUOTA"
               : code == PM_ERR_BUDGET ? "PM_ERR_BUDGET"
               : code == PM_ERR_JSON   ? "PM_ERR_JSON"
                                       : "PM_ERR_ARGS",
               code, err, pm_scene_count(scene), used, cap);
    }
    return code == PM_OK ? id : code;
}

static void report(PmScene *scene, struct columns *c, int frame)
{
    int ids[MAX_SPELLS];
    int batches, i, total = 0, listed;
    int used = 0, cap = 0;

    batches = pm_scene_observe(scene, c->pos_x, c->pos_y, c->pos_z,
                               c->size, c->life, c->color,
                               c->capacity, c->batch_info, MAX_BATCHES);
    if (batches < 0) {
        printf("frame %3d  pm_scene_observe failed with %d\n", frame, batches);
        return;
    }
    for (i = 0; i < batches; ++i) {
        total += c->batch_info[i * PM_BATCH_INFO_STRIDE + 1];
    }
    pm_scene_budget(scene, &used, &cap);
    listed = pm_scene_spells(scene, ids, MAX_SPELLS);

    printf("frame %3d  spells %d [", frame, pm_scene_count(scene));
    for (i = 0; i < listed; ++i) {
        printf("%s%d", i ? " " : "", ids[i]);
    }
    printf("]  batches %2d  particles %5d  quota %d/%d\n",
           batches, total, used, cap);
}

/* Run frames until the scene is down to `target` live spells, or the
   budget of frames runs out. Returns the frame number reached. */
static int run_until(PmScene *scene, struct columns *c, int frame,
                     int target, int limit)
{
    int    end = frame + limit;
    double acc = 0.0;

    while (frame < end && pm_scene_count(scene) > target) {
        int steps = 0;

        /* Same planner as the single-cast example: a real host passes the
           measured frame time, this one synthesises exactly one fixed
           step, so the trace keeps its one-step-per-frame rhythm. */
        if (pm_plan_steps(FIXED_DT, MAX_STEPS_PER_FRAME, FIXED_DT, acc,
                          &steps, &acc) != PM_OK) {
            fprintf(stderr, "frame %d: pm_plan_steps failed\n", frame);
            return frame;
        }
        while (steps-- > 0) {
            if (pm_scene_advance_ex(scene, FIXED_DT_F) != PM_OK) {
                fprintf(stderr, "frame %d: pm_scene_advance_ex failed\n", frame);
                return frame;
            }
        }
        ++frame;
        if (frame % 60 == 0) {
            report(scene, c, frame);
        }
    }
    return frame;
}

int main(int argc, char **argv)
{
    const char    *path = (argc > 1) ? argv[1] : "assets/spells/ring-fire.json";
    struct columns cols;
    PmScene       *scene;
    char          *json;
    int            one, cap, frame = 0, refused, third;

    pm_init();

    if (pm_abi_version() != PM_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch: library %d, header %d\n",
                pm_abi_version(), PM_ABI_VERSION);
        pm_shutdown();
        return 2;
    }

    json = read_file(path);
    if (!json) {
        pm_shutdown();
        return 1;
    }

    one = probe_budget(json);
    if (one <= 0) {
        free(json);
        pm_shutdown();
        return 1;
    }

    /* Room for exactly two of this spell, so the third has to wait for
       one of them to end. */
    cap = 2 * one;
    printf("spell: %s\n", path);
    printf("one cast costs %d particles; global_cap = %d (room for two)\n\n", one, cap);

    if (!alloc_columns(&cols, cap)) {
        fprintf(stderr, "out of memory for %d particles\n", cap);
        free(json);
        pm_shutdown();
        return 1;
    }

    scene = pm_scene_new(cap);

    /* (1) two spells coexist -- staggered, so they do not end together */
    cast_into(scene, json, "A");
    frame = run_until(scene, &cols, frame, 0, 90);
    cast_into(scene, json, "B");
    report(scene, &cols, frame);

    /* (2) the third does not fit, and the refusal changes nothing */
    refused = cast_into(scene, json, "C");
    printf("   after the refusal, the scene is untouched: ");
    report(scene, &cols, frame);

    /* (3) A ends on its own and gives its share back */
    printf("\nrunning until A ends ...\n");
    frame = run_until(scene, &cols, frame, 1, 600);
    report(scene, &cols, frame);

    /* (4) ... so C now gets in */
    printf("\n");
    third = cast_into(scene, json, "C (retried)");

    printf("\nrunning to the end ...\n");
    frame = run_until(scene, &cols, frame, 0, 1200);
    report(scene, &cols, frame);

    printf("\nrefused code %d, retried id %d, spells left %d\n",
           refused, third, pm_scene_count(scene));

    pm_scene_free(scene);
    free_columns(&cols);
    free(json);
    pm_shutdown();
    return 0;
}
