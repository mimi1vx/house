# Phase 2 — Freestanding RTS spike: consolidate, unblock, prove ticks

Executes step 2 of `plans/ghc-9.14-aarch64-port.md`, consolidating the
existing in-tree attempt (untracked work found 2026-08-26: full
`kernel/platform/aarch64/` spike + `scripts/qemu-smoke.exp`, prebuilt
`build/spike.elf`). Decisions made with user:

- Scope = boot blocker + wiring/docs **+ threadDelay tick proof** (de-risks
  the faked-ticker seam before phase 3 wires real IRQs).
- Fix direction for the boot blocker: **debug-loop decides** — root cause is
  confirmed experimentally before any fix lands; candidates below are
  hypotheses ranked, not decisions.
- The whole attempt gets a **baseline commit first**, so phase-2 diffs are
  reviewable against preserved working state.

## Current state (consolidation findings)

The previous attempt built far more than a hello-world spike, and it almost
works today (verified by re-running `scripts/qemu-smoke.exp`):

- ✅ EL2/EL3→EL1 drop, FP/SIMD enable, R_AARCH64_RELATIVE self-relocation,
  VBAR_EL1 vectors with full x0–x30+SP+q0–q31 save (`start.S`).
- ✅ `hs_init()` succeeds — bump mmap honoring RTS hint addresses (incl. the
  second window around `0x4200000000`, hence the deliberate `-m 512G`),
  signal-recording shim, fake fd table all work (`tinylibc/{alloc,sys}.c`).
- ✅ Sync-exception handler emulates 16B-alignment-required `LDP/STP`
  (Debian-built GHC archives emit them); fired correctly 7× during boot.
- ❌ **Blocker:** fatal data abort `ESR=0x96000035` on an exclusive load
  (INSN=`0xc85ffc20`, LDXR-family, Rn=SP) during early RTS/Haskell
  execution. EC=0x25 (data abort same EL), DFSC=0x35 — a different fault
  class than the 0x21 alignment case the handler covers. Kernel parks,
  `spike-ok` never prints.

Infrastructure gaps: no `spike-*` targets in the top-level Makefile (the
spike Makefile comment references `make spike-build`; it doesn't exist),
no `.gitignore` (13 MB of `build/` artifacts untracked), no phase-2 entry in
the porting log, `-m 512G` undocumented (reads like a typo; it isn't).

Key empirical discovery baked into comments: **GHC 9.14's non-threaded RTS
arms a `timerfd`** (not `setitimer`) — the shim serves an incrementing
counter from `read()`; periodic delivery was deferred to phase 3.

## Skills to load in build mode

- `debug-loop` — step 3 is a live debugging task; reproduce/isolate/
  hypothesize/falsify before touching anything.
- `apple-container` — every container invocation pins
  `--platform linux/arm64` explicitly (project convention; env var
  intentionally *not* global), never Rosetta.
- `sota-haskell` — for `Spike.hs` and any ghc-invocation changes.
- `karpathy-guidelines` — surgical fixes; the emulator/orphan decisions in
  step 4 must trace to the root cause.

## Plan

1. **[trivial] Ignore build artifacts** — create `.gitignore` with
   `kernel/platform/aarch64/build/`.
   — verify: `git status --short` no longer lists anything under
   `kernel/platform/aarch64/build/`.

2. **[trivial] Baseline commit** — stage everything currently untracked
   (`Containerfile`, `kernel/platform/` minus `build/`, `scripts/`,
   `plans/`) plus the `Makefile` additions; one conventional commit
   (`feat: aarch64 port scaffold + freestanding spike (pre-phase-2 baseline)`
   or matching repo style). No fixes folded in — this preserves the exact
   state that stalls.
   — verify: `git status` clean; `git log -1 --stat` shows expected files.

3. **[medium] Root-cause the DFSC=0x35 fatal abort** (debug-loop; no fix
   yet). Reproduce via `scripts/qemu-smoke.exp`. Isolate:
   - Decode fully: INSN `0xc85ffc20` is an exclusive load with Rn=SP;
     FAR/ELR/LR land in Haskell heap/code regions.
   - Cross-check accelerator: run the same ELF with `-accel tcg` vs `hvf`
     (script already takes accel as argv[3]) to split hypervisor behavior
     from architectural semantics.
   - Instrument `c_handle_sync` temporarily (dump SPSR, more GPRs) if needed.
   - Leading hypothesis H1: with MMU off, all RAM carries Device-memory
     attributes — unaligned access faults regardless of SCTLR.A (explains
     the 7 emulations) and exclusive ops to Device memory are disallowed;
     the 0x35 class surfaces under HVF. Candidate fix family: minimal
     identity page tables mapping RAM Normal Cacheable.
   - Alternate hypothesis H2: HVF-specific reporting of misaligned
     exclusives; would show as different DFSC under TCG.
   Deliverable: root cause + falsifying/confirming experiment recorded in
   `plans/porting-log.md` **before** step 4 starts.
   — verify: log entry names the fault class, the decisive experiment, and
   why the chosen fix follows from it.

4. **[small|medium] Implement the fix the root cause dictates** — expected
   shape (H1): `mmu.S`/early-C setting up MAIR, TTBR0_EL1 and a small
   identity map covering the RAM span as Normal Cacheable, enabled in
   `start.S` before vectors/BSS; SCTLR.A stays off. Re-evaluate the
   alignment emulator afterwards: with Normal memory + A=0, emulated
   `LDP/STP` cases become legal — if truly orphaned, flag in the log and
   remove only what this change orphaned. If evidence favors another cause,
   implement that instead (this step's content is owned by step 3's output).
   — verify: fresh `spike.elf` boots; smoke script sees both markers
   (`hello from stock GHC RTS` and `spike-ok`); also passes under `-accel
   tcg`.

5. **[trivial] Wire top-level Makefile targets** (legacy targets untouched):
   - `spike-build`: `container run --platform linux/arm64 --rm -v
     "$(CURDIR)":/work -w /work $(IMAGE) make -C kernel/platform/aarch64`
   - `spike-run`: host-side interactive `qemu-system-aarch64 … -nographic
     -kernel …` (same flags as the expect script)
   - `spike-check`: `clean` + `spike-build` + expect script asserting
     `spike-ok`
   Also comment `-m 512G` in `scripts/qemu-smoke.exp` (covers GHC's fixed
   heap-hint scan near `0x4200000000`) and hoist it to a variable with a
   sane default.
   — verify: `make spike-check` green from a clean tree in one command.

6. **[small] Prove ticks work (threadDelay)** — two coordinated changes:
   - `tinylibc/sys.c`: pace the fake timerfd by wall clock — `read()`
     returns `EAGAIN` until `tick_interval_ns` has elapsed since the last
     delivered tick (measured via `house_uptime_ns()`); otherwise the
     always-readable fd makes select() fire unboundedly and threadDelay
     would return instantly (liveness without timing).
   - `Spike.hs`: after the hello lines, loop 4×: `threadDelay 500000`,
     print iteration + measured inter-tick delta from `clock_gettime`,
     finish with marker `ticks-ok`.
   This validates the exact seam phase 3 will re-implement as ISR-driven
   `house_rts_tick()` replay.
   — verify: `make spike-check` (marker extended to `ticks-ok`) passes;
     log shows ~500 ms deltas (±RTS tick granularity), proving both
     liveness and pacing.

7. **[trivial] Consolidate documentation** — append the phase-2 entry to
   `plans/porting-log.md`: root cause & fix, the timerfd discovery,
   self-relocation and alignment-emulation rationale, `-m 512G` rationale;
   tick the corresponding success-criteria boxes in
   `plans/ghc-9.14-aarch64-port.md`.
   — verify: log reads as the complete record a cold-starting session
   needs; master-plan checkboxes updated.

## Files

- Create: `.gitignore`, likely `kernel/platform/aarch64/mmu.S` (or
  equivalent — decided by step 3)
- Modify: `Makefile` (append spike targets), `start.S` (MMU enable),
  `tinylibc/sys.c` (timerfd pacing), `Spike.hs` (tick loop),
  `scripts/qemu-smoke.exp` (comment + mem variable, marker default),
  `plans/porting-log.md`, `plans/ghc-9.14-aarch64-port.md` (checkboxes)
- Possibly trim (only if orphaned by the fix): alignment-emulation cases in
  `c_start.c`/`start.S`
- Delete: nothing else

## Risks

- **Root cause may be HVF-specific** — mitigated by testing TCG and HVF both
  in step 3; the fix must be principled either way (H1 holds on real
  hardware too; H2 would demand a different remedy).
- **Enabling the MMU adds classic early-boot hazards** (cacheable attrs,
  D-cache state across the enable sequence) — bounded, well-trodden
  pattern; keep the map minimal (one GB block-granular level-2 table).
- **Timerfd pacing could starve or stall the RTS** if interval bookkeeping
  is off — fallback: revert to always-readable counter (liveness-only
  proof) and note pacing as phase-3 work.
- **Tick delivery may not reach `handle_tick`** if 9.14's non-threaded RTS
  path differs from the timerfd assumption — step 6 doubles as the
  experiment; if no ticks arrive, fall back to recording SIGVTALRM +
  polled replay earlier than planned (pulls a slice of phase 3 forward).

## Alternatives considered

- Teach `c_handle_sync` to swallow/emulate the 0x35 fault class — rejected
  pending root cause: masking semantics at the handler hides the real
  Device-memory problem, and faithful LL/SC emulation without page tables
  is gnarly; revisit only if step 3 falsifies H1 *and* H2's remedy is
  worse.
- Accept the spike without tick proof, defer all timing to phase 3 —
  rejected by user choice: the faked ticker is the plan's declared
  highest-risk piece; proving it now is cheap.
- Commit nothing until phase 2 completes — rejected by user choice: the
  stalled-attempt state is itself valuable history worth pinning.

## Success criteria

- [ ] `.gitignore` keeps `build/` artifacts out; baseline commit contains
      the intact attempt and nothing generated
- [ ] `plans/porting-log.md` documents the DFSC=0x35 root cause with its
      confirming experiment (before-fix entry)
- [ ] Freshly built `spike.elf` boots under host QEMU (hvf *and* tcg) and
      prints the Haskell-produced hello line + `spike-ok` via PL011
- [ ] Spike demonstrates paced ticks: 4× `threadDelay 500000` iterations
      with measured ~500 ms deltas, ending in `ticks-ok`
- [ ] `make spike-check` performs build (in arm64 container, explicit
      `--platform`) + boot + assertion in one command
- [ ] Master-plan step-2 criteria checked off; phase-2 log entry complete
- [ ] Legacy i386 flow untouched (`git diff` shows additive changes only)
