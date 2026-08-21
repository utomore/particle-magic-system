# out-of-process load smoke

Host-runtime **F006**, subsystem module **M8**, interface **I6**.

The hspec suite calls `Magic.FFI`'s entry points as ordinary Haskell
functions, in a process whose GHC runtime was already up before the first
test ran. That is a real test of the logic and a complete blind spot for
four other things:

* the **export list** — `particle-magic-ffi.def` is never exercised, only
  compared as text;
* the **runtime start** — `pm_init` / `pm_init_ex`'s C path never runs;
* the **exception firewall** — nothing observes whether the calling
  *process* survives;
* the **shutdown semantics** — `pm_shutdown` is a one-way door that an
  in-process suite can never walk through.

`oop_smoke.c` is a plain C program that links **no Haskell package**. It
knows `include/particle_magic.h` at compile time and a library path at run
time; everything else is reached through `GetProcAddress` / `dlsym`.

## Building and running

```sh
test/oop/build.sh          # or: powershell test\oop\build.ps1
test/oop/run.sh            # or: powershell test\oop\run.ps1
```

`run.sh` / `run.ps1` locate the library cabal built under `dist-newstyle`,
rebuild the harness if the source is newer, force the working directory to
the repo root (the harness reads the spell and the golden by repo-relative
paths) and run every probe. **The exit code is the result**: zero when
nothing failed.

Both scripts also take a path, so the same harness can drive a packaged
drop:

```sh
packaging/pack.sh --verify --out dist/linux-x86_64
test/oop/run.sh dist/linux-x86_64
```

That second mode says an *outside* process can load the packaged library.
Whether the drop is self-contained is `packaging/pack.sh --verify`'s
assertion, and this harness does not repeat it.

### The two build modes

| mode | library | what it adds |
|---|---|---|
| shipped | `cabal build particle-magic-ffi` | everything except `firewall`, which reports SKIP |
| poison | `cabal build -foop-poison particle-magic-ffi-poison` | the `firewall` probe, through one test-only symbol |

The poison library is a separate cabal `foreign-library` behind a manual,
default-off flag, with a **different file name**, one extra module
(`Magic.FFI.Poison`) and one extra exported symbol (`pm_poison_spell`). The
shipped header, the shipped `.def` and the C# binding are untouched, which
is exactly why `test/FFIContractSpec.hs` and `test/BindingContractSpec.hs`
needed no change for any of this. See `test/oop/poison/Magic/FFI/Poison.hs`
for why the trigger is shaped that way.

Run it against the poison library like any other:

```sh
cabal build -foop-poison particle-magic-ffi-poison
test/oop/run.sh "$(find dist-newstyle -name 'libparticle-magic-ffi-poison.so' | head -1)"
```

## Probes

Each probe runs in its **own child process** and the parent loads nothing
at all. That is not tidiness: before the I3 gate landed, two of these
probes ended the calling process from inside the runtime, and "the child
died" is itself one of the signals worth reading. It also means a genuine
firewall regression is one `FAIL` line instead of a vanished harness.

| probe | what it holds the library to |
|---|---|
| `load` | every symbol under `EXPORTS` resolves; the generation matches the header; `pm_max_particles()` is positive and is what the columns are sized from. On Windows this is also a cross-process acceptance of `particle-magic-ffi.def` itself. |
| `life` | `pm_init` → cast → 120 × (`pm_advance` + `pm_observe`) → `pm_is_finished` → `pm_free` → `pm_shutdown` ×2, compared line by line against `examples/haskell/expected-output.txt`. |
| `state-uninit` | before `pm_init`, one representative of every sentinel shape answers instead of entering the runtime (C2.5 / I3). |
| `state-after-shutdown` | the library demonstrably worked, then `pm_shutdown` closed it and the same sentinels come back; a second `pm_shutdown` is a no-op. |
| `state-reinit` | the door is one-way: `pm_init` after `pm_shutdown` does nothing and `pm_init_ex` answers `PM_ERR_STATE` (C2.5). |
| `rts-config` | `pm_init_ex` with capabilities, nursery, GC mode and statistics reaches the *runtime* (C1.5) — see the platform table below. |
| `rts-prestarted` | the header's "the runtime was ALREADY running" row: `hs_init` first, then `pm_init_ex` reports `PM_ERR_STATE` in its second sense while the library stays up and usable, capabilities still apply, and statistics correctly do not. |
| `rts-prestarted-zero-caps` | the same row asked the header's own default way — zero `PmConfig`, set `size`, fill in nothing — so `capabilities` is 0, i.e. *follow the hardware*. That is a request, and it has to be applied (`n_capabilities` reaches the machine's count) rather than dropped in silence (C2.4, host-runtime B002). Linux only: Windows exports neither `hs_init` nor `n_capabilities`. |
| `firewall` | with the poison library: six shipped symbols answer `PM_ERR_INTERNAL`, `pm_free` stays a safe no-op, the process lives, and the library still casts afterwards (C2.1). |

`--list` prints exactly this set of names; `test/OopSmokeSpec.hs` asserts
that this table and the registry in `oop_smoke.c` agree in both directions,
so a probe added to one and not the other turns `cabal test` red.

## Verdicts and exit codes

A child's exit code is its whole result:

| child exit | meaning |
|---|---|
| 0 | passed |
| 20 | ran to the end, but an assertion did not hold |
| 21 | not applicable here — see SKIP below |
| anything else, including a signal | **the child did not survive** |

The parent turns those into one line per probe and a summary:

```
probe life                   PASS
oop-smoke: 5 passed, 0 failed, 3 skipped, 0 pending
```

and exits zero **iff** `failed == 0`.

* **SKIP** — the probe does not apply to this library or this platform, and
  says which: no `pm_poison_spell` (shipped build), or no RTS symbol to
  read (Windows). It is never silent.
* **PENDING** — a state probe did not come back alive *and* this library
  has no `pm_init_ex`, i.e. the I3 gate (host-runtime F003) is not in it.
  Not a failure: the fix simply is not in this binary. The gate **is**
  landed today, so a PENDING now would mean it had been removed.

## What this harness deliberately does not do

* **Handle safety** — use-after-free, double free, forged pointers. That is
  `test/FFIHandleSpec.hs`'s job in process, where the outcome is an error
  code rather than a platform-dependent crash shape.
* **Projection and the spatial summary** — the golden's trailing
  `projection` block is `test/Acceptance11Spec.hs`'s.
* **Timing.** No wall-clock number is printed. A number in this output
  would become somebody's benchmark; benchmarks live in `bench/`.
* **Threads.** Concurrent advance is `test/FFIThreadSpec.hs`'s.

## The golden and its platform rule

There is no golden of this harness's own. It reuses
`examples/haskell/expected-output.txt`, which is already held from two
sides by `test/ExampleHostSpec.hs`: S3 recomputes it through
`Magic.Interface` and S4 reproduces it through the in-process C ABI. This
is the third route — a different process, loading the real shared object —
reproducing the same file, which is what makes "in-process and
out-of-process see the same simulation" a checked sentence rather than a
hopeful one. A fresh golden here would be a truth nobody recomputes.

The comparison follows the rule that golden already has
(`ExampleHostSpec.sameLine`):

| column | windows/x86_64 (the reference platform) | elsewhere |
|---|---|---|
| `frame`, `batches`, `particles`, `blend`, every word | character for character | character for character |
| `age`, `checksum` | character for character | relative tolerance `1e-5` |

Measured: 0 of 120 lines differ on Windows; 9 of 120 differ on Linux, all
in the last digit of `checksum` — libm's `sin`/`cos` are not correctly
rounded and the sum magnifies it (ADR-0016). Dropping the two decimal
columns off-reference instead of tolerating them would *lower* what this
harness checks there, which is the opposite of the point.

`life` also refuses to pass on empty data: the spell starts with zero
particles, so "every line matched" means nothing unless the run really
produced particles and really compared 121 lines. Both are asserted.

Each frame's six columns are additionally folded into an FNV-1a 64 digest
(`test/PerfGoldenSpec.hs`'s definition) and the last frame's value is
printed. That is a **diagnostic, not an assertion** — it has no recomputed
golden, so pinning it to a committed constant would create a truth nobody
maintains. It is there to be read by eye across platforms, and to be the
ready-made material if the goldens ever become bit-exact everywhere.

## Where the RTS settings can be checked

`rts-config` asks for capabilities = 2, a 64 MiB nursery, the non-moving
collector and runtime statistics, then reads the runtime back:

| assertion | windows | linux |
|---|---|---|
| `pm_init_ex` returns `PM_OK`, and the full lifecycle still runs | yes | yes |
| `n_capabilities` | no — not exported | yes |
| `getRTSStatsEnabled()` | no | yes (needs no struct layout at all) |
| `RtsFlags.GcFlags.minAllocAreaSize`, `.useNonmoving` | no | yes, when built with `PM_OOP_WITH_RTS_HEADERS` |

Windows exports none of it — `particle-magic-ffi.def` closes the export
face — so there the probe reports SKIP **with that sentence**, which is
itself the cross-process evidence for the per-platform table in the header.

On Linux the RTS symbols are not exported by
`libparticle-magic-ffi.so` either: they come from
`libHSrts-…-ghc9.14.1.so` on its dependency chain, and `dlsym` finds them
through the handle. `build.sh` adds `-I$(ghc --print-libdir)/…/rts-*/include`
when it can find `Rts.h`, which supplies the **layout** of `RTS_FLAGS` and
nothing else — the pointer still comes from `dlsym`, so not one Haskell
symbol is linked. Without those headers the probe simply asserts two things
instead of four and says so.

`PM_OOP_HAS_RTS_STATS` is likewise decided by `build.sh` / `build.ps1`
reading the header, so the harness does not hard-code a field that the
header is the authority on.
