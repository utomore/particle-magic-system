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
#define DT (1.0f / 60.0f)

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

    /* The six SoA columns a host would otherwise map straight onto a
       vertex buffer. Allocated once, refilled every frame. */
    static float    pos_x[PM_MAX_PARTICLES];
    static float    pos_y[PM_MAX_PARTICLES];
    static float    pos_z[PM_MAX_PARTICLES];
    static float    size[PM_MAX_PARTICLES];
    static float    life[PM_MAX_PARTICLES];
    static uint32_t color[PM_MAX_PARTICLES];
    static int      batch_info[MAX_BATCHES * PM_BATCH_INFO_STRIDE];

    char      err[512];
    char     *json;
    PmSpell  *spell;
    int       frame;

    pm_init();

    if (pm_abi_version() != PM_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch: library %d, header %d\n",
                pm_abi_version(), PM_ABI_VERSION);
        pm_shutdown();
        return 2;
    }

    json = read_file(path, NULL);
    if (!json) {
        pm_shutdown();
        return 1;
    }

    err[0] = '\0';
    spell = pm_cast(json, caster_pos, caster_facing, 20260814u, err, (int)sizeof err);
    free(json);
    if (!spell) {
        fprintf(stderr, "cast failed: %s\n", err);
        pm_shutdown();
        return 1;
    }

    printf("spell: %s\n", path);
    for (frame = 0; frame < FRAMES; ++frame) {
        int    batches;
        int    i;
        int    total = 0;
        double checksum = 0.0;

        pm_advance(spell, DT);
        batches = pm_observe(spell, pos_x, pos_y, pos_z, size, life, color,
                             PM_MAX_PARTICLES, batch_info, MAX_BATCHES);
        if (batches < 0) {
            fprintf(stderr, "frame %d: pm_observe failed with %d\n", frame, batches);
            pm_free(spell);
            pm_shutdown();
            return 1;
        }

        for (i = 0; i < batches; ++i) {
            total += batch_info[i * PM_BATCH_INFO_STRIDE + 1];
        }
        for (i = 0; i < total; ++i) {
            checksum += (double)pos_x[i] + (double)pos_y[i] + (double)pos_z[i]
                      + (double)size[i] + (double)life[i];
        }

        printf("frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f\n",
               frame, pm_age(spell), batches, total,
               batches > 0 ? batch_info[2] : -1, checksum);
    }

    printf("finished: %d\n", pm_is_finished(spell));

    /* Freeing twice would be undefined behaviour; shutting down twice is
       not (both calls below are part of the smoke). */
    pm_free(spell);
    pm_shutdown();
    pm_shutdown();
    return 0;
}
