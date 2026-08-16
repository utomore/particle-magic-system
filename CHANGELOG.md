# Changelog

All notable changes to this project are documented here, one entry per
delivered function spec (details in `docs/spec/`).

Format rules (the authority is [docs/release.md](docs/release.md) §3, and
`test/ReleaseMetaSpec.hs` enforces the first of them):

- one `## <version> — <YYYY-MM-DD>` section per release, and the version
  in `particle-magic.cabal` must have a section here;
- inside a section, one entry per function spec, in numerical order,
  opening with **`00NN <title>`**;
- entries say what the round delivered, not what files moved.

## 0.1.0.0 — 2026-08-13

- **0001 framework skeleton** — package boundary (magic-core / magic-boundary /
  shell), IO/core separation, fixed-timestep loop, hot reload, end-to-end
  walking skeleton. (delivered)
- **0002 circle structure & interpreter** — `Circle` ADT, parameter runes,
  inside-out compile fold, real analytic sampling, full slot JSON schema v1.
  (delivered)
- **0003 Expr subsystem** — closed first-order math AST, total evaluator,
  text syntax parser (megaparsec), renderer. (delivered)
- **0004 Expr-rune wiring** — `RangeRune`/`ConvergeRune`/`AmplifyRune`/
  `FormulaRune`, `ExprV3`, layered time frames (behavior t = particle age,
  modulation t = seconds since cast). (delivered)
- **0005 render realization & observability** — dynamic quad mesh single
  draw call (ADR-0009), blend/billboard honored, HUD + on-screen load errors,
  keyboard spell switching, `-O2` + tasty-bench baseline;
  `advanceSpell`/`observeSpell` split. (delivered)
- **0006 lifecycle phases & formation emitters** — Drawing/Converging/
  Casting/Dissipating, formation-geometry emitters, opt-in `"phases"` JSON;
  sampler untouched, bit-for-bit compatibility for existing spells.
- **0007 force-field layer** — ADR-0010: additive displacement overlay on
  the analytic layer, semi-implicit Euler at the fixed step, particle
  identity keyed by stable `(emitter, index)` slot, three field kinds
  (gravity/attractor/vortex) behind an opt-in `"fields"` JSON key. The
  system's first cross-frame state (`FieldState`), reset on every cast;
  fieldless spells branch around the whole layer and render bit-for-bit
  what they rendered before. `app/*` untouched. Packaging debt from the
  same round: MIT license, public sublibraries, PVP bounds, this
  README/CHANGELOG. (delivered)
- **0008 2D orthographic backend** — ADR-0008 made executable: `ViewPlane` /
  `orthographic` / `depthOrder` (stable painter permutation) in
  `Magic.Project`, re-exported through `Magic.Projection`; a real 2D draw
  path (screen-space quads, painter order) beside the 3D one, switchable
  live with Tab / V. Same `FrameOutput`, no core change. (delivered)
- **0009 C ABI foreign library** — ADR-0011: `foreign-library` stanza produces
  `.dll`/`.so`, `include/particle_magic.h` is the frozen contract, JSON in and
  six SoA columns copied out, `pm_cast → pm_advance → pm_observe → pm_free`
  handle lifecycle; determinism holds across the boundary as a tested
  equivalence (FFI path ≡ Haskell path). Core and boundary unchanged.
  (delivered)
- **0010 performance & particle budget** — the hot path goes end-to-end
  unboxed: sampling builds the six columns with a count-then-fill pass
  instead of a boxed intermediate list, `FieldState` becomes flat SoA,
  `depthOrder` sorts in place, `Expr` constant-folds at compile time, and
  emitters outside their time window are skipped entirely. The budget stops
  being a bare `Int`: `ParticleBudget` (per-emitter plan plus total) and
  `maxSpellParticles` are exported through `Magic.Interface`, so a host can
  query the cap instead of hard-coding it. Measured: 0.73 ms → 0.27 ms per
  frame at 4096 particles, 161 → 65 ns per particle, `depthOrder` 10× faster,
  100 000 particles sampled in 6.5 ms. All ten example spells stay
  bit-identical, locked as a golden test before any refactor; the cap value
  itself is untouched (that move belongs to 0012). (delivered)
- **0011 host integration surface** — three add-only C exports:
  `pm_max_particles` (the cap becomes a runtime query, so the frozen
  `PM_MAX_PARTICLES` never has to change again), `pm_project` and
  `pm_depth_order` (ADR-0008's orthographic projection and painter's order
  reach non-Haskell hosts). New boundary module `Magic.Columns` — the
  validating column → buffer door the FFI shell needed. The header now
  states the colour byte order and the coordinate handedness. A C#
  reference binding (`bindings/csharp/`) and a Unity example
  (`examples/unity/`), both held to the header by a contract test and
  smoke-tested against Unity 6000.5.7f1 in batch mode — the marshaller,
  the projection entry points and the example's mesh path, re-runnable
  with `examples/unity/PmSmoke.cs`. (delivered)
- **0013 visual expressiveness (the `app/*` half)** — the demo becomes an
  instrument you can look through: alpha batches are staged back to front by
  camera distance (`App.Render.Order`, additive batches left alone since the
  sum is order-independent), the 3D view gets an orbit camera (drag) and a
  wheel dolly, the 2D view gets pan, cursor-anchored zoom and window-resize
  adaptation, and the top view gets an optional depth tint against the flat
  blob it used to be. Every control is the identity on idle input, so an
  untouched run renders exactly what func-spec 0008 delivered — asserted
  end-to-end. Core, boundary, FFI and `app/Main.hs` untouched. (delivered)
- **0012 multi-circle composition & scene layer** — ADR-0012, and the last
  row of Init.md's parameter table: `CompiledSpell` becomes a lawful
  `Semigroup`/`Monoid`, so stacking circles is a fold rather than a special
  case. Emitters, force fields and per-emitter budgets concatenate;
  `PhasePlan` merges landmark by landmark with `max`, which is the only
  merge that preserves the ordering invariant without truncating either
  component. `compileMany` / `Magic.Interface.castSpells` cast a
  composition as one spell, checked against the same cap as a single
  circle. New boundary module `Magic.Scene`: several casts alive at once
  under one global quota, first come first served, a pure value with no IO
  and no second ledger — a finished spell releases its share by being
  dropped. And the particle cap finally moves: **4096 → 16384**, the
  largest power of two whose whole per-frame CPU cost stays under 2 ms
  (measured 1.45 ms; 32768 would be 2.87 ms). The C header is untouched —
  `PM_MAX_PARTICLES` stays pinned at the first generation's 4096 and
  `pm_max_particles()` answers the new value, exactly as func-spec 0011
  designed it. All ten example spells stay bit-identical across the raise.
  (delivered)
- **0014 authoring tools** — the feedback loop for whoever writes the spell
  files. `magic-validate` is the boundary layer's third consumer and the one
  that opens no window: point it at files or directories, it loads and casts
  each one and prints `OK <path>` / `FAIL <path>` with the details indented,
  exiting with the number of failures so it drops straight into CI; `--stats`
  adds the budget, emitter split, lifetime, declared phases, field count and
  world-space extent of every spell that works. `docs/spell-schema.md` is the
  same format written for authors rather than for the compiler — every key,
  its range, the formula syntax, the error messages and a guided tour of the
  shipped examples — and `SchemaDocSpec` fails the build the day an example
  uses a key the document does not mention. The demo now rescans its spell
  directory as it runs (a throttled `ScanDir` op, no fsnotify), so files can
  be added and removed without restarting: the selection follows its path,
  a deleted current file falls to its neighbour, and an unchanged directory
  is the identity — no reload, no recast. Core, boundary and FFI untouched.
  (delivered)
- **0015 visual vocabulary (the core half)** — ADR-0013: particle form
  becomes something a player writes into the circle. `BillboardShape` moves
  into `Magic.Rune` and grows to four parameterless constructors (square /
  soft-dot / ring / spark; declaration order IS the C wire code via `Enum`),
  the outer ring gains `StyleRune` with an opt-in `"style"` JSON tag, and
  `observeSpell` splits its output into one batch per run of adjacent
  same-looking emitters — zero-copy slices, with the splitting law (batches
  concatenate to the un-split buffer, bit for bit) tested structurally.
  The C ABI grows three `PM_SHAPE_*` defines (stride untouched, C# binding
  forced along by the existing mirror test). The demo differentiates the
  shapes with procedurally generated alpha-only sprites through the default
  shader's diffuse map — no custom shader, no image assets; formation
  emitters stay hard squares so a drawn circle stays sharp. Every pre-0015
  example still renders one square batch, bit for bit (golden net unmoved).
  New example: `soft-bloom.json`. (delivered)
- **0016 sigil geometry (a circle's figure is derived from the circle)** —
  ADR-0014: the drawing phase stops being six concentric bands of fog and
  becomes strokes — curves walked at a constant pace. New core module
  `Magic.Sigil` carries `hashCircle` (a structural digest of the whole
  `Circle`, floats entering by their bits; frozen on delivery and listed in
  architecture §11, since it picks how every spell looks), `sigilPlan`
  (structure sets the skeleton — which layers exist, at which radii, how
  symmetric; the digest sets the ornament — which stroke, at which phase,
  with which parameters) and closed-form sampling for six stroke kinds
  (arc ring, star polygon, spokes, ticks, rose, 3×3 lattice glyph band).
  `SpawnPattern` gains one constructor, `SpawnOnStroke`. Because index
  order is now position along the curve, spec 0002's frozen birth schedule
  makes the sigil *draw itself* — no new scheduling machinery at all.
  `Magic.Codec` is untouched: no schema bump, no new rune, no new JSON key.
  Force fields are deliberately outside the digest, so spec 0007's law that
  fields change nothing else the interpreter produces survives intact.
  Bit-for-bit compatibility is waived for exactly the Drawing and
  Converging windows of spells that declare `phases`; from castStart on,
  every phased spell samples exactly its casting emitter, and unphased
  spells are untouched. New example: `lattice-seal.json`. (delivered)
- **0017 the sigil persists through the cast** — ADR-0015: the spell is
  now fired *out of* a magic circle that is still there, instead of
  consuming it. Formation emitters live until `ppEnd` (the whole cast)
  rather than dying at `castStart`, and the synthesized convergence curve
  is gone — the sigil holds the position it was drawn at. Two numbers and
  one `Maybe` in the compiler: `firstBirth` reads `envDelay` and
  `envLifetime` and never `envDuration`, so extending the spawn window
  leaves the drawing pace bit-for-bit intact and costs the sampler
  nothing (not a line of it changed, no new state, no new mechanism).
  `emCount` is untouched, so the budget and `ParticleBudget` are
  identical; `Magic.Codec`, the schema and the C ABI are untouched too.
  Because formation emitters stay `emPhase = Drawing`, ADR-0010 D6's
  "only casting particles feel the fields" turns from a vacuous promise
  into a real law — a gravity well bends the spell and leaves the circle
  exactly where it was drawn — and is now tested as one. The bit-for-bit
  boundary narrows to `t < min(phDraw, castStart - formLife)`, measured
  and matched frame for frame; the second term caught a pre-existing bug
  where a circle with `phConverge < formLife` (bare-sigil) started fading
  before it had finished being drawn. (delivered)
- **0018 the scene layer on the C ABI** — ADR-0012 D8 lifted: its condition
  was that the scene API be used for a round on the Haskell side before
  being frozen into a C contract, and spec 0012 met it. A non-Haskell host
  now gets the same multi-spell capability a Haskell one has — several
  casts alive under one global particle quota, first-come-first-served
  admission, quota released the moment a spell ends — instead of keeping
  its own book of `PmSpell*` handles and their sizes. Ten purely additive
  exports (`pm_scene_new` / `_free` / `_cast` / `_cast_many` / `_dismiss` /
  `_advance` / `_observe` / `_budget` / `_count` / `_spells`), one opaque
  `PmScene*`, one new error code `PM_ERR_QUOTA` (−5) — the one failure a
  host can act on rather than only log, since the spell compiled and the
  scene is merely full. `PM_ABI_VERSION` stays 1; the frozen entry-point
  list grows 11 → 21 and nothing in it changes. The C surface is the
  item-for-item image of `Magic.Scene`'s export list and adds no semantics
  of its own: `Acceptance18Spec` states that as an equivalence over
  generated histories of interleaved casts, dismissals and frames, checking
  the six columns, the batch descriptors, the admission verdict and the
  quota ledger after every single step. `pm_scene_observe` shares
  `pm_observe`'s copy-out verbatim, so the layout, the capacity rule and
  the all-or-nothing error path are the same code rather than merely alike.
  Which spell a batch came from is deliberately not reported — `observeScene`
  does not know either, and the C side is not allowed to know more. A scene
  owns its spells outright (they have no `PmSpell*`), which is what keeps
  `pm_free` and `pm_scene_dismiss` from ever naming the same cast. C#
  binding and a C example (`examples/c/scene.c`) follow. `src/core` and
  `src/boundary` untouched. (delivered)
- **0019 engineering: CI, release policy, the second platform** — ADR-0016.
  "This branch is good to merge" stops depending on one Windows machine:
  `.github/workflows/ci.yml` runs build → test → `magic-validate` on
  `windows-latest` and `ubuntu-latest` for every pull request into `main`
  (plus `v*` tags and on demand — this repository is private, so runner
  minutes are billed and Windows costs double, and the gate belongs at the
  merge rather than at every push; ADR-0016 D5). Four text-contract
  tests keep the workflow, the cabal metadata, `README.md` and
  `docs/release.md` from drifting apart (support tiers ≡ CI matrix, the
  declared `tested-with` ≡ the compiler CI installs, every dependency
  carries a PVP upper bound, the tag format is derived from the version
  rather than copied). `docs/release.md` is the new procedure: tier
  definitions, version-bump rules, the `v0.1.0.0` tag format, and the
  rule that `PM_ABI_VERSION` and the package version move independently.
  The round's real product is what the first non-Windows run of the suite
  found: 1156 examples, and 23 bit-for-bit goldens red — every one of
  them in the position columns, none anywhere else. Root cause measured
  directly rather than guessed: IEEE-754 does not require `sin`/`cos` to
  be correctly rounded, and mingw's libm and glibc's differ on the last
  bit for ~1.3% of arguments (63 of 4096 `Float` angles for `sin`, 46 for
  `cos`, worst case 1 ulp each), which reaches the output as at most
  1.79e-07 in `pbPosX`/`pbPosZ` with `pbPosY`, `pbSize`, `pbLife` and
  `pbColor` bit-identical. So the determinism claim narrows honestly
  instead of being quietly widened: bit-for-bit within a platform,
  structure plus two ulp across platforms. Goldens are re-scoped, not
  re-recorded (`test/GoldenPlatform.hs`); the C header's "on every
  platform" sentence is corrected, without an ABI generation bump — it is
  a comment, not a declaration. (delivered)
- **0020 the sigil's time dimension (it turns)** — ADR-0020: a magic circle
  now reads as running machinery rather than a decal. The whole figure
  rotates about its face centre, neighbouring rings counter-rotate, and
  each stroke winds up while the spell charges and then holds that speed.
  `SigilSpin` (rate, charge-up acceleration, charge-up end) rides inside
  `SigilStroke`; `spinAngle` is a piecewise closed form of the cast clock
  — quadratic to `castStart`, linear after — whose angular speed is
  bounded by `|rate| + |accel|·castStart` no matter how long the spell
  runs, which is what a sigil that now lives for the entire cast (0017)
  requires. The rotation is applied about the face origin, so it is an
  isometry: func-spec 0016's three laws hold word for word,
  `strokeRadius` and `emitterBounds` are unchanged, and `Magic.Compile`
  needed no edit at all — one case of `positionIn` and the derivation in
  `Magic.Sigil` are the entire change. The starting phase stays in
  0016's `skPhase`, so `spinAngle sp 0 = 0`: the sigil at `t = 0` is
  bit-for-bit the figure 0016 drew, and the derived geometry of every
  shipped spell is byte-identical (the new digest bits do not collide
  with 0016's). `Magic.Codec`, the schema, the C ABI, the particle budget
  and the dependency list are all untouched, and no cross-frame state is
  added — the angle is a pure function of `t`. Casting particles and
  spells without `phases` are bit-for-bit unaffected at every instant;
  ADR-0020 also rules that this is the last round the two formation
  goldens are re-recorded bit-exactly. (delivered)
- **0021 magic vocabulary: the sum types grow up** — the mechanisms were
  complete and the value ranges were not: four elements, four face shapes,
  four trajectories, three force fields. This round takes them to nine,
  eight, eight, six and (for radiation) four, and it is entirely
  additive — eighteen new constructors, not one existing case edited — so
  every spell written before it renders bit for bit what it always did.
  Elements gain the three missing 五行 members plus the 陰陽 pair, split
  five alpha / four additive; face shapes gain polygon, star, cross and
  annular sector, each with a conservative `shapeRadius` bound asserted
  as a property (the one failure mode GHC cannot catch — a bound that is
  too small silently breaks a host's frustum culling); trajectories gain
  wave, ballistic, pulse and zigzag, all still closed forms of particle
  age with no state to carry; force fields gain wind, turbulence and
  spring, chosen under a hard criterion — `fieldAccel`'s position-only
  signature is frozen, so velocity-dependent fields (drag, magnetism) are
  explicitly deferred rather than smuggled in — with the turbulence
  wobble built as an analytic curl, hence exactly divergence-free.
  Radiation gains inward convergence and tangential swirl. `BlendMode` is
  deliberately NOT extended: it is C-ABI vocabulary and belongs to a spec
  that knows it is changing the wire format, so 陰 is expressed as a dark
  low-alpha ramp instead. That restraint is what lets the round settle
  func-spec 0015 §8-5's ledger the way ADR-0012 D5 always framed it — by
  composition: `castSpells [wuxing-seal, yin-yang]` puts two blends in
  one `FrameOutput`, which no single circle can do, since a circle has
  exactly one element. Also delivered: the second tier of top-view
  readability (depth flattening and an outline floor, both size-only and
  both off by default, `G` in the demo), two new example spells, and a
  widened golden net — `soft-bloom` and `lattice-seal` had gone three
  rounds without one, and their baselines were recorded on the pre-0021
  build so the compatibility law above rests on twelve examples rather
  than ten. The C ABI, the schema version, `ParticleBuffer`, the particle
  budget and the dependency list are untouched. (delivered)
- **0025 spatial output and several activation points** — ADR-0019: the
  system gains a third output. Until now a host could learn what a
  spell's particles look like and nothing about where the spell *is* —
  `emitterBounds` was one same-radius cube, Haskell-only, and there was
  no spell-level union and no occupancy information at all. `Magic.Space`
  answers all three: `emitterBox` resolves the same interval arithmetic
  per axis in the emitter's own face frame (travel goes on the normal,
  spread stays in plane), which measures 1.5%–13% of the frozen cube's
  volume across the shipped examples; `spellBounds`/`spellBox` fold them;
  and `occupancyOf` grids the live particles in one O(n) read-only pass,
  with `occupancyMask` returning all 27 cells of the default 3×3×3 grid
  as a single `Word32` — 27 being this system's own nine-grid extruded
  along the normal, not a coincidence. The grid's frame is the whole-life
  box and does not move while the spell runs, because a cell that means a
  different region each frame cannot answer "did anything enter here".
  `emitterBounds` itself is bit-for-bit unchanged, witnessed against
  values captured from the pre-0025 build: it is a frozen export whose
  numbers a host may already depend on, so the tighter bound arrives as a
  new function rather than a better version of the old one. All of it is
  a *query*, not a `FrameOutput` field — most spells are pure visuals and
  should pay nothing, and nothing here influences a single particle
  (calling any of it leaves `observeSpell` bit-identical). This is a
  summary, not a spatial partition: architecture §7 and §11 stand, and
  ADR-0019 records the line so nobody cites this round as a precedent.
  The other half: a spell can fire from more than one place. `Anchor`
  could always express an arbitrary position and normal — the formation's
  node emitters have used it since 0006 — so all that was missing was
  somewhere for a player to write it down. `"anchors"` is the third
  circle-level opt-in property after `phases` and `fields`, and particles
  are *shared out* between activation points rather than multiplied by
  them: `spellBudget` is identical to the single-point spell's, so adding
  a point is a choice of shape, never a way around `power` or the cap.
  Seven add-only C entry points and `PM_OCCUPANCY_DIM_DEFAULT` carry it
  all across the ABI with `PM_ABI_VERSION` still 1. New example
  `twin-lance.json`; every example and golden that existed before this
  round is untouched. (delivered)
