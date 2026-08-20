# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Status

This is a **working implementation, not a greenfield project**. The cabal project builds, the hspec suite is green on Windows and Linux (CI matrix), and func-specs 0001–0025 plus enhance-0001 are all delivered and accepted. An interface a delivered spec calls frozen IS frozen — changing one needs an ADR, not a judgement call. Authoritative documents:

- `.design/system.md` — **Level 1 系統主架構，本專案的燈塔**（Traditional Chinese）: system boundary, external I/O contract, subsystem split, communication topology, development stages. Read this before any design or implementation work.
- `.design/subsystems/<slug>/design.md` — Level 2 subsystem architectures, one per subsystem in `system.md`'s `subsystems` list. Each defines the public contract, internal module split, data-flow pipeline, feature roadmap and a contract card per feature. Read the one covering the code you are about to touch.
- `.design/subsystems/<slug>/{features,enhancements,bugfixes}/` — Level 3 task documents (`F001`, `E001`, `B001`; numbering is per-subsystem). Cross-subsystem ones live in `.design/{enhancements,bugfixes}/` with a `G-` prefix. Write the document BEFORE implementing; a Todo is only done when its paired test is green.
- `.design/legacy-map.md` — **the bridge to the frozen history.** `docs/` holds 26 delivered task documents and 20 ADRs from the previous doc system; they are read-only and are NOT renumbered. Source comments still say `func-spec 0016` and remain valid pointers — resolve them through this table.
- `docs/adr/adr-NNNN-*.md` — Architecture Decision Records, still authoritative and still referenced from code. Do not silently contradict these. **New** ADRs go to `.design/adr/` numbered from `ADR-021`.
- `docs/{spell-schema.md,spell.schema.json,integration.md,release.md}` — product documentation, still live and still updated: the spell-file manual, its machine-readable schema, the host integration guide and the release policy. Six guard tests pin these paths.
- Every `.design/` document starts with YAML frontmatter (`id`, `type`, `title`, `description`, `status`, `created`, `updated`, plus `depends-on` / `related-adr` / `related-feature` on task docs). List fields are **inline arrays only**. `description` is mandatory: one Traditional-Chinese sentence, max 40 characters, no trailing period. `/arch-audit status` reads only that block, so keep `status` and `updated` current.
- `SKILL.md` — the **previous** doc system and work cycle (superseded by the `.design/` three-level ladder, kept for historical reading). The live workflow is dev-flow: `/system-design` (L1) → `/subsys-design` (L2) → `/feature-design` → `/feature-impl` (L3), with `/arch-audit status` as the mechanical gate. Key rule that carries over: one session owns at most ONE task document.
- `Init.md` — the original vision notes (superseded in detail by the architecture doc).

Key settled decisions (see ADRs for rationale): hybrid particle model, analytic-first with optional force-field layer (ADR-0001); three-layer DSL — circle structure ADT + parameter records + small math `Expr` AST, no deep GADT DSL (ADR-0002); fixed-role slots with runes, interpreted inside-out: core=essence, inner=behavior, bridge=modulation, outer=presentation (ADR-0003); dataflow architecture, no ECS (ADR-0004); JSON + hot reload as the input interface (ADR-0005); SoA + unboxed vectors, target 10k–100k particles (ADR-0006); effectful only in the `App.*` shell, `Magic.*` core has zero IO and no `Eff` in signatures (ADR-0007); dimension-agnostic core in abstract 3D space, raylib 3D backend first (ADR-0008). Later rounds settled: dynamic quad mesh rather than instancing (ADR-0009, whose "no custom shader" premise is superseded by ADR-0018); force-field composition — additive displacement, stable slot identity, reload resets state (ADR-0010); the C ABI boundary — foreign-library, JSON in, SoA copy-out, handle lifecycle (ADR-0011); multi-circle composition and the scene-layer quota, first-come-first-served (ADR-0012); the billboard vocabulary (ADR-0013); the sigil derived from a frozen circle digest (ADR-0014), persisting through the cast (ADR-0015) and spinning (ADR-0020); release compatibility — same-platform bit-exact, cross-platform structural + 2 ulp (ADR-0016); parallel-sampling determinism via pure Strategies (ADR-0017); custom shaders in the shell plus the six→nine column widening (ADR-0018); spatial summary as output, not simulation structure (ADR-0019).

## Where the code lives

| Path | cabal target | What |
|---|---|---|
| `src/core/` | `magic-core` (public sublibrary) | Pure core, zero IO. build-depends whitelist: base, vector, deepseq, parallel |
| `src/boundary/` | `magic-boundary` (public sublibrary) | JSON codec, `Magic.Interface`, scene layer, expression grammar, projection re-export |
| `src/ffi/` | `particle-magic-ffi` (foreign-library) | C ABI shell; 31 exported symbols, contract frozen in `include/particle_magic.h` |
| `app/` | `particle-magic` (executable) | h-raylib demo shell — every line of IO in the project lives here |
| `tools/` | `magic-validate`, `magic-inspect`, `magic-schema` | Authoring CLIs; `magic-schema` deliberately depends on no part of the library |
| `test/`, `bench/` | `spec`, `bench` | hspec suite (headless — no window, no h-raylib) and tasty-bench baselines |
| `assets/`, `include/`, `bindings/`, `examples/` | — | Shaders and spell files, the C header, the C# binding, three reference hosts |

The layering is enforced by package structure, not by discipline: the executable, the CLIs and the FFI shell depend on `magic-boundary` only, so they physically cannot import core internals. `test/BoundarySpec.hs` guards it, and the dependency whitelists are part of the contract rather than an accident of what happened to be needed.

## What This Project Is

A proof-of-concept for a **particle magic system** game: players compose magic spells from parameters, and every spell is rendered/expressed through a particle system. Effects are meant to *be* the magic (part of the gameplay model), not decoration.

Core concept — "Circle as Data": a magic circle (魔法陣) is data interpreted by a pre-written interpreter, leveraging Haskell's strengths to make spells composable and unbounded. A spell activates from a point + normal vector, constructs an initial 2D face (the drawn magic circle), extrudes/expands along the normal into 3D, then drives the particle system with a mathematical model.

Magic circle structure (all slots optional, freely combinable by the player):
- Outer ring: 2 layers (circle/square/diamond shapes)
- Interlayer: 1 layer (the bridging factor between outer and inner)
- Inner ring: 2 layers
- Core: up/down/left/right nodes plus a center node

## Technology Decisions (fixed by design doc)

- **Language**: Haskell (GHC 9.14.1 installed via ghcup; use the machine's latest versions)
- **Build**: cabal (cabal-install 3.16.1.0)
- **Libraries**: h-raylib (rendering), Aeson (serialization), effectful (effect system), megaparsec (formula grammar), vector (unboxed buffers), parallel (Strategies-based parallel sampling)
- **Explicitly NOT using an ECS architecture**
- **Performance**: SoA (Structure of Arrays) with unboxed vectors — delivered and measured (100k particles sampled in 6.5 ms single-threaded, 2.5 ms across 16 capabilities). The dense grid in the original notes was never needed: the analytic model has no neighbour queries, and particle-to-particle interaction is a permanent non-goal.

## Design Principles (from Init.md)

- Pure functional core: core modules must be pure functions; push effects to the edges (effectful at the boundary)
- Modular, data-flow architecture designed from the inside out
- Lean heavily on Haskell's type system
- Dimension-agnostic core: the same system must work for 2D and 3D games — the essence is unchanged, only the projection/mapping to 2D or 3D space differs
- Well-specified system boundary: define required input format, output format, and a clean external interface for the whole system
- An architecture diagram is an expected deliverable

## Commands

The project is initialized; all of these work today:

```
cabal build all
cabal test
cabal test --test-options='--match "pattern"'   # single test (hspec)
cabal run particle-magic                        # the h-raylib demo shell
cabal run magic-validate -- <file|dir> [--json] # load and cast a spell file
cabal run magic-inspect  -- <file>              # what a spell file adds up to
cabal run magic-schema   -- --check             # JSON Schema golden comparison
cabal bench
cabal repl
```

Note: h-raylib on Windows compiles raylib's C sources; first builds are slow and require a working C toolchain (the ghcup-bundled MinGW works).

## Working Language

The user writes design docs and communicates in Traditional Chinese. Respond in Chinese when the user writes in Chinese; code, identifiers, and comments should be in English.
