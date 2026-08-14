# particle-magic

A pure-core, data-driven **particle magic system** for games: magic circles
(魔法陣) are plain data — Haskell ADTs, serializable as JSON — compiled by a
pre-written interpreter into deterministic particle emitters. The visual
effect *is* the magic: every slot and rune of a circle directly determines
the particles' mathematical behavior.

The public libraries are renderer- and engine-agnostic. This repository's
executable is only a demo shell (h-raylib); a host game brings its own
renderer and consumes the system's dimension-free `RenderBatch` output. The
demo draws that one output through both a 3D perspective backend and a real
2D orthographic one, switchable at runtime — the core does not know which.

## Architecture in one paragraph

Three rings, dependencies pointing strictly inward
(details: [docs/architecture.md](docs/architecture.md), ADRs in
[docs/adr/](docs/adr/)):

- **Pure core** (`magic-core`, zero IO): circle ADT, rune vocabulary, a small
  math-expression AST, the circle→emitters compiler, and the analytic
  particle sampler (particle state is a pure function of time — fully
  deterministic and replayable). Depends only on `base`, `vector`, `deepseq`.
- **Pure boundary** (`magic-boundary`): the system's only public surface —
  `Magic.Interface` (cast/step/observe), `Magic.Codec` (JSON in/out,
  formula-text parsing) and `Magic.Projection` (orthographic projection +
  painter ordering, for 2D hosts).
- **Effect shell** (this repo's executable): fixed-timestep loop, hot reload,
  h-raylib rendering. Host games replace this ring entirely.

## Using it from another cabal project

Add the repository and depend on the boundary library (the sublibraries are
`visibility: public`):

```cabal
-- cabal.project
source-repository-package
  type: git
  location: https://github.com/utomore/particle-magic-system.git
  tag: <commit-or-tag>
```

```cabal
-- your-package.cabal
build-depends: particle-magic:magic-boundary
```

Your code imports `Magic.Interface` and `Magic.Codec` only — plus
`Magic.Projection` if you render in 2D. Nothing else is part of the contract.

## Using it from a non-Haskell engine (C ABI)

The second supported consumption mode (ADR-0011, func-spec 0009). Build the
shared library and link against `include/particle_magic.h` — that header is
the whole contract, and it is frozen: additions only.

```
cabal build particle-magic-ffi
# -> dist-newstyle/.../particle-magic-ffi.dll   (Windows, RTS embedded)
#    dist-newstyle/.../libparticle-magic-ffi.so (Linux/macOS)
```

```c
#include "particle_magic.h"

pm_init();                                  /* idempotent; starts the RTS */
PmSpell* s = pm_cast(json, pos, facing, seed, err, sizeof err);
while (!pm_is_finished(s)) {
    pm_advance(s, 1.0f / 60.0f);
    int batches = pm_observe(s, pos_x, pos_y, pos_z, size, life, color,
                             PM_MAX_PARTICLES, batch_info, 8);
    /* six SoA columns straight into your vertex buffer — the library
       never draws anything itself */
}
pm_free(s);
pm_shutdown();
```

A spell is JSON in and six float/uint32 columns out; the same
`(json, position, facing, seed, dt sequence)` produces bit-identical output
here and through the Haskell path. `examples/c/main.c` is a complete, working
host in 150 lines.

## The host surface

```haskell
import Magic.Codec     (loadCircle, saveCircle, renderLoadError)
import Magic.Interface

-- load + cast once:
main :: IO ()
main = do
  bytes <- BS.readFile "spells/my-spell.json"
  case loadCircle bytes of
    Left err -> putStrLn (renderLoadError err)
    Right circle ->
      case castSpell (CastRequest circle ctx) of
        Left cerr  -> print cerr
        Right spell -> gameLoop spell
  where
    ctx = CastContext { casterPos = V3 0 0 0
                      , casterFacing = V3 0 0 1
                      , seed = Seed 42 }

-- every simulation step:
gameLoop :: ActiveSpell -> IO ()
gameLoop spell = do
  let (spell', FrameOutput batches) = stepSpell (FrameInput dt) spell
  mapM_ drawBatchWithYourRenderer batches   -- SoA particle buffers, blend mode, billboard shape
  if isFinished spell' then pure () else gameLoop spell'
```

Advanced: `advanceSpell` / `observeSpell` split stepping (advance the
simulation several fixed steps, sample exactly once per rendered frame) —
`stepSpell` is their composition. `spellAge` reports seconds since cast.

Rendering in 2D: `Magic.Projection` does the dimension-dropping half for you
— `orthographic plane pos` returns `(V2, depth)` for a chosen `ViewPlane`
(`SideXY` or `TopXZ`), and `depthOrder plane buffer` returns a stable
far-to-near index permutation to draw in. Screen origin and scale stay yours.

Determinism guarantee: the same `(Circle, CastContext, dt sequence)` always
produces bit-identical output — spells are replayable and testable as pure
functions.

## Repository layout

- `docs/architecture.md` — the system design (Traditional Chinese)
- `docs/integration.md` — host integration guide: Haskell, C/C++, Unity (C#)
  and any other shared-library host — data contract, coordinate system,
  pitfalls, current limits
- `docs/roadmap.md` — completeness assessment and the ordered candidate list
  for the next function specs
- `docs/adr/` — architecture decision records
- `docs/func-spec/` — per-iteration function specs (design-before-code, each
  todo paired 1-to-1 with a test module)
- `assets/spells/*.json` — example spells
- `include/particle_magic.h` — the frozen C ABI contract; `cbits/`, `src/ffi/`
  and `examples/c/` are its implementation and reference host
- `cabal build all && cabal test` — build and run the full test suite;
  `cabal run particle-magic` — the raylib demo (first build compiles raylib's
  C sources); `cabal bench` — pure-core baselines

## License

MIT — see [LICENSE](LICENSE).
