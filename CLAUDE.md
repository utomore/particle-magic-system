# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

This is a **greenfield project with a completed architecture design, but no code yet**. No cabal project or build setup exists. Authoritative documents:

- `docs/architecture.md` — the system architecture design (Traditional Chinese): module structure, data flow, core type sketches, JSON input format, interpreter design, performance strategy, risk analysis. Read this before any design or implementation work.
- `docs/adr/adr-NNNN-*.md` — Architecture Decision Records. Do not silently contradict these; if a decision must change, update the ADR.
- `docs/spec/func-NNNN-*.md` — function specs, one per module/implementation iteration: ADTs, techniques, data structures, pipeline, build order, and a Todo list with 1-to-1 test mapping. Write the spec BEFORE implementing an iteration; a Todo is only done when its paired test is green. First one: `func-0001-framework-skeleton.md` (package boundaries, IO/core boundary, walking skeleton).
- `docs/bugfix/bug-NNNN-*.md`, `docs/enhance/enhance-NNNN-*.md`, `docs/analysis/report-YYYY-MM-DD-*.md` — defect records, improvement proposals, and health-check reports. Created on demand; only `analysis/report-*` is date-named, everything else is four-digit numbered.
- Every doc starts with YAML frontmatter (`id`, `type`, `title`, `description`, `status`, `created`, `updated`, `depends-on`, `related-adr`, `related-spec`) — see SKILL.md 「文檔 metadata 標準」. `description` is mandatory on every doc: one Traditional-Chinese sentence, max 40 characters, no trailing period, stating the document's theme (not its details). The `dev-flow` skill's `scan-status.mjs` reads only that block, so keep `status` and `updated` current whenever a doc changes.
- `SKILL.md` — the documentation system and work cycle rules (doc types, metadata standard, func-spec template, Todo↔test discipline, multi-collaborator mode). Follow it when adding docs or starting an implementation round. Key rules: one Claude session owns at most ONE func-spec; specs must be decoupled (depend only on permanent interfaces and completed specs); specs marked **重大基建功能** (critical infrastructure) must be fully accepted before dependent specs start, and their permanent interfaces are frozen once delivered.
- `Init.md` — the original vision notes (superseded in detail by the architecture doc).

Key settled decisions (see ADRs for rationale): hybrid particle model, analytic-first with optional force-field layer (ADR-0001); three-layer DSL — circle structure ADT + parameter records + small math `Expr` AST, no deep GADT DSL (ADR-0002); fixed-role slots with runes, interpreted inside-out: core=essence, inner=behavior, bridge=modulation, outer=presentation (ADR-0003); dataflow architecture, no ECS (ADR-0004); JSON + hot reload as the input interface (ADR-0005); SoA + unboxed vectors, target 10k–100k particles (ADR-0006); effectful only in the `App.*` shell, `Magic.*` core has zero IO and no `Eff` in signatures (ADR-0007); dimension-agnostic core in abstract 3D space, raylib 3D backend first (ADR-0008).

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
- **Libraries**: h-raylib (rendering), Aeson (serialization), effectful (effect system)
- **Explicitly NOT using an ECS architecture**
- Performance direction to consider: dense grid, SoA (Structure of Arrays) with unboxed vectors

## Design Principles (from Init.md)

- Pure functional core: core modules must be pure functions; push effects to the edges (effectful at the boundary)
- Modular, data-flow architecture designed from the inside out
- Lean heavily on Haskell's type system
- Dimension-agnostic core: the same system must work for 2D and 3D games — the essence is unchanged, only the projection/mapping to 2D or 3D space differs
- Well-specified system boundary: define required input format, output format, and a clean external interface for the whole system
- An architecture diagram is an expected deliverable

## Commands

Once the cabal project is initialized, standard commands apply:

```
cabal build
cabal run <executable>
cabal test
cabal test --test-options='--match "pattern"'   # single test (hspec)
cabal repl
```

Note: h-raylib on Windows compiles raylib's C sources; first builds are slow and require a working C toolchain (the ghcup-bundled MinGW works).

## Working Language

The user writes design docs and communicates in Traditional Chinese. Respond in Chinese when the user writes in Chinese; code, identifiers, and comments should be in English.
