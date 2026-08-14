# Changelog

All notable changes to this project are documented here, one line per
delivered function spec (details in `docs/func-spec/`).

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
