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
(details: [docs/arch/architecture.md](docs/arch/architecture.md), ADRs in
[docs/adr/](docs/adr/)):

- **Pure core** (`magic-core`, zero IO): circle ADT, rune vocabulary, a small
  math-expression AST, the circle→emitters compiler, and the analytic
  particle sampler (particle state is a pure function of time — fully
  deterministic and replayable). Depends only on `base`, `vector`, `deepseq`.
- **Pure boundary** (`magic-boundary`): the system's only public surface —
  `Magic.Interface` (cast/step/observe), `Magic.Codec` (JSON in/out,
  formula-text parsing), `Magic.Projection` (orthographic projection +
  painter ordering, for 2D hosts) and `Magic.Scene` (several casts at once
  under one global particle quota).
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
`Magic.Projection` if you render in 2D, and `Magic.Scene` if you run several
spells at once. Nothing else is part of the contract.

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

That equality is exact within one machine. Between machines it is exact in
structure — same particles, same order, same counts — and accurate to a
couple of ulp in the position columns, because C's `sin`/`cos` are not
required to be correctly rounded and two libm implementations legitimately
differ in the last bit (measured: at most `1.79e-07` between Windows and
Linux on x86_64; size, life and color identical). See
[ADR-0016](docs/adr/adr-0016-release-compatibility-policy.md).

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

Determinism guarantee: on a given platform, the same
`(Circle, CastContext, dt sequence)` always produces bit-identical output —
spells are replayable and testable as pure functions. Across platforms the
guarantee narrows to structure plus a couple of ulp in the positions
(ADR-0016).

## Repository layout

- `.design/system.md` — the Level 1 system architecture, and the project's
  lighthouse document (Traditional Chinese)
- `.design/subsystems/<slug>/design.md` — the six Level 2 subsystem
  architectures: magic semantics, the Expr language, particle simulation,
  the boundary/host surface, the render shell, and authoring plus
  engineering
- `.design/legacy-map.md` — the bridge to `docs/`, which holds the frozen
  design history of the previous doc system (26 task documents, 20 ADRs)
- `docs/integration.md` — host integration guide: Haskell, C/C++, Unity (C#)
  and any other shared-library host — data contract, coordinate system,
  pitfalls, current limits
- `docs/roadmap.md` — completeness assessment and the ordered candidate list
  for the next function specs
- `docs/spell-schema.md` — the spell-file format for the people who write
  them: every key, its range, the formula syntax and the shipped examples
  (Traditional Chinese; kept honest by `test/SchemaDocSpec.hs`)
- `docs/adr/` — architecture decision records
- `docs/spec/` — per-iteration function specs (design-before-code, each
  todo paired 1-to-1 with a test module)
- `assets/spells/*.json` — example spells
- `include/particle_magic.h` — the frozen C ABI contract; `cbits/`, `src/ffi/`
  and `examples/c/` are its implementation and reference host
- `tools/` — `magic-validate`, the authoring CLI: it loads and casts every
  spell file you point it at and reports what broke, or (with `--stats`) the
  budget, lifetime, phases, fields and spatial extent of the ones that work.
  Third consumer of the boundary layer, and the one that opens no window:

      cabal run magic-validate -- --stats assets/spells

  One `OK <path>` / `FAIL <path>` line per file, details indented; the exit
  code is the number of failures, so it drops straight into CI.
- `cabal build all && cabal test` — build and run the full test suite;
  `cabal run particle-magic` — the raylib demo (first build compiles raylib's
  C sources; it rescans `assets/spells` as it runs, so files can be added and
  removed without restarting it); `cabal bench` — pure-core baselines

## Building and CI

GHC 9.14.1 and cabal 3.16.1.0 (the `tested-with:` field is the authority;
CI installs exactly that compiler). On Linux, h-raylib needs the X11/GL
development headers at compile time — `libx11-dev libxrandr-dev
libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev` on Debian and
Ubuntu. Nothing in CI opens a window: the demo executable is built, never
run, and its logic half is covered headless by the test suite.

Pull requests into `main` run three steps on both Tier 1 platforms,
ordered most-expensive-first because a red build makes the other two
meaningless:

```
cabal build all                            # includes the demo, the C ABI shared library and the benchmarks
cabal test                                 # the full hspec suite
cabal run magic-validate -- assets/spells  # exit code = number of bad spell files
```

Supported platforms (this table is the same list as the CI matrix, and a
test fails if the two drift apart — see
[docs/release.md](docs/release.md)):

| Tier | What it means | Platforms |
|---|---|---|
| **Tier 1** | Verified by CI before merging: build, test, validate. A regression is a defect. | `windows-latest` (x86_64), `ubuntu-latest` (x86_64) |
| **Tier 2** | Expected to work, not covered by CI. Breakage gets fixed but does not block a release. | macOS, other Linux distributions |
| Unsupported | Nobody has tried. | ARM, WASM, mobile |

The first build on a cold cache is slow — h-raylib compiles raylib's C
sources — and warm builds are not.

CI does **not** run on ordinary branch pushes: this repository is private,
so runner minutes are billed (and Windows runners cost double), and the
gate belongs where the decision is. Day to day, run `cabal test` yourself;
CI runs on a pull request into `main`, on a `v*` tag, and whenever you
trigger it by hand. The reasoning and the numbers are in
[ADR-0016](docs/adr/adr-0016-release-compatibility-policy.md) D5.

## Releases

Releases are git tags: `v` followed by the four-segment cabal version,
character for character (`v0.1.0.0`). There is no Hackage upload; the tag
exists so that a `source-repository-package` user has something to pin.

The public sublibraries follow PVP, so a breaking change to a frozen
interface is a major bump. `PM_ABI_VERSION` in the C header moves
independently of the package version — the header is add-only, so its
generation only advances if that rule is ever broken.

The full procedure, the version-bump rules and the compatibility promises
are in [docs/release.md](docs/release.md); the reasoning is in
[ADR-0016](docs/adr/adr-0016-release-compatibility-policy.md).

## License

MIT — see [LICENSE](LICENSE).
