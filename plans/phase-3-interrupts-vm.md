# Phase 3 — H-layer adaptation: interrupts (GICv3) + VM adaptation

Details doc for step 3 of `plans/ghc-9.14-aarch64-port.md`. Written 2026-08-26,
after phases 1–2 completed (see `plans/porting-log.md`).

## Decisions made with user (2026-08-26)

- **GIC-native IRQ API now** — `H.Interrupts` exposes GIC INTIDs, not the x86
  `IRQ0..IRQ15` enum; downstream call sites updated in this phase (full compile
  of those modules still lands in phase 4).
- **VM adaptation in phase 3** — `H.VirtualMemory` rewritten for aarch64
  page-table format with `userspace.h` C support; verified by structure-level
  round-trip tests, *not* by activating user page tables (EL0 execution stays
  out of scope).
- **Separate verification target** — new `irq-check` kernel; `spike-check`
  stays green as the pure-RTS regression baseline.

## Current state

Phase 2 left a freestanding stock-RTS kernel booting under HVF and TCG:
identity-mapped RAM (`mmu.c`), exclusive-op emulation, bump allocator with
reserved size headers, iconv/locale shims, and a **wall-clock-paced fake
timerfd** serving GHC's ticker. Ticks do not yet come from hardware;
`house_rts_tick()` (ISR→recorded-SIGVTALRM replay) exists in `sys.c` but has
no caller. `start.S` routes all four IRQ vector slots to `vec_fatal`; there is
no GIC or timer driver. `QEMU -M virt,gic-version=3` is already pinned in
`make spike-run`.

The old `kernel/H/Interrupts.hs` programs the i8259 PIC via `in`/`out` ports
and registers handlers through a C-side `setIRQTable`. Its only consumers:
`House.hs` (`enableInterrupts`), `Kernel/Interrupts.hs`,
`SimpleExec.hs` (`enableIRQ IRQ0`), `UserMode.hs`, `Kernel/UserProc.hs`,
`Kernel/Driver/{PS2,NE2000/*}`. The only hardcoded address constants in the H
layer live in `H/VirtualMemory.hs` (i386 two-level PTEs, `Word32` VAddr,
`userspace.h` imports) — the master plan's mention of MemRegion/AdHocMem
constants was imprecise; those modules have none.

## Design

### Interrupt path (stock-RTS-conformant)

- **GICv3** (system-register CPU interface; matches pinned
  `gic-version=3`): `ICC_SRE_EL1.SRE=1`, redistributor (CPU0 frame,
  `GICR_WAKER` wake) at QEMU-virt `0x080A_0000`, `GICR_ISENABLER0` bits for
  the two timer PPIs, `GICD_CTLR` group enables, `ICC_PMR=0xff`,
  `ICC_IGRPEN1_EL1=1`. Ack = `ICC_IAR1_EL1`, EOI = `ICC_EOIR1_EL1`
  (EOImode=0 → priority drop with EOI). Single core: no targeting, no nesting
  (I-bit masked throughout the ISR).
- **Timers**: EL1 **virtual timer** (`CNTV_*`, PPI INTID 27 expected) drives
  the RTS ticker — ISR rearms `CNTV_TVAL`, then calls `house_rts_tick()`.
  EL1 **physical timer** (`CNTP_*`, PPI INTID 29 expected) acts as a second,
  independent source to exercise mask/enable/EOI and the Haskell dispatcher.
  Exact INTIDs confirmed empirically at bring-up (print IAR value).
- **Vector**: `start.S` gains a `vec_irq` entry with the same full-context
  frame as `vec_sync` (x0–x30, SP, q0–q31) calling `c_handle_irq(frame)`;
  all four IRQ slots repoint from `vec_fatal`.
- **Device-IRQ dispatch**: ISR pushes INTID into an SPSC ring (single core,
  I-masked producer ⇒ lock-free) and writes one token byte into a dedicated
  fake pipe (existing `sys.c` fd table). A Haskell dispatcher thread blocks in
  `threadWaitRead` on the pipe fd (IO-manager poll — the mechanism phase 2
  already proved with the paced timerfd), drains the ring, looks the handler
  up in a Haskell-side array of `StablePtr (H ())`, runs it inside an
  exception-catching wrapper. This replaces the old C-side `setIRQTable`
  scheme. Deviation from the original sketch: wake via pollable pipe instead
  of an `wfi` FFI spin — a `wfi`-looping thread would starve the scheduler
  between ticks, while the pipe rides the proven select/poll seam.
- **Ticker seam switch-over**: once the ISR path works, `house_timerfd_due()`
  returns 0 whenever ISR ticking is active (flag set by timer init before
  `hs_init`). The ticker thread parks harmlessly on EAGAIN; hardware PPI 27
  becomes the sole tick source. `spike-check` then verifies `threadDelay`
  pacing end-to-end off real interrupts — stronger than the phase-2 wall-clock
  stand-in.

### H.Interrupts API (GIC-native)

```haskell
newtype IntId = IntId Word32 deriving (Eq, Ord, Ix, Enum, Show)
ppiVirtTimer, ppiPhysTimer :: IntId          -- 27, 29 (confirmed at bring-up)
spi :: Word32 -> IntId                       -- 32+n
enableInt, disableInt, eoi    :: IntId -> H ()
installHandler                :: IntId -> H () -> H ()   -- idempotent dispatcher start
enableInterrupts, disableInterrupts :: H ()              -- daif I-bit via FFI
```

### VM adaptation

- `VAddr = Word64`; user window chosen below the kernel image and outside the
  RTS alias window — assumed **0x0100_0000 .. 0x3FFF_FFFF** (RAM base is
  0x4000_0000; final bounds stated in the module and porting log).
- Page-map structures become aarch64 4KB-granule format: L0 index [47:39],
  L1 [38:30], L2 [29:21], L3 [20:12]; L0–L2 allocated eagerly per PageMap,
  L3 on demand (mirrors the old pdir/ptable split one level deeper). Descriptors
  carry AF (bit 10 — mandatory), AP/UXN/nG and AttrIdx consistent with the
  MAIR setup in `mmu.c`.
- `userspace.c` (new, freestanding): defines the page-pool window symbols
  `min_user_addr`/`max_user_addr` consumed by `H.Pages` (carved from guest RAM
  away from image/bump-pool/alias regions), `init_page_dir`/`current_pdir` as a
  recorded pointer, `invalidate_page` = `TLBI VAAE1IS` + DSB/ISB (safe no-op
  semantics while tables are never loaded into TTBR0).

## Plan

1. **[small] GICv3 + timer C drivers** — `kernel/platform/aarch64/{gic.c,timer.c,irq.h}`;
   init called from `c_start` before `hs_init`; boot prints redistributor/GIC
   state and arms the virtual timer. — verify: spike boot log shows `gic ok`;
   first IAR-read INTID confirms 27/29 expectations.
2. **[medium] IRQ vector + ISR tick switchover** — `vec_irq` in `start.S`
   (shared frame layout with `vec_sync`), `c_handle_irq` in `c_start.c`
   (rearm, `house_rts_tick()`, ring push, pipe wake), `house_timerfd_due`
   gated off when ISR ticks active. — verify: **`make spike-check` green under
   hvf and tcg** — ticks now hardware-sourced; temporary C ISR counter print
   removed after confirmation.
3. **[medium] Ring buffer + `H.Interrupts` rewrite + IrqCheck kernel** —
   `irq.c` (SPSC ring, pipe handoff), rewritten `kernel/H/Interrupts.hs`
   (API above, Haskell-side handler table, idempotent dispatcher via
   `threadWaitRead`), new `IrqCheck.hs`: counts PPI-27 and PPI-29 ticks in
   registered handlers, prints both counters periodically, asserts both
   advanced; new `scripts/qemu-irq.exp` + top-level `irq-build`/`irq-run`/
   `irq-check` mirroring the spike targets; platform Makefile grows the new
   objects and second Haskell entry. — verify: `make irq-check` green (hvf +
   tcg) *and* `make spike-check` still green.
4. **[medium] VM adaptation** — rewrite `kernel/H/VirtualMemory.hs`
   (Word64 VAddr, L0–L3 descriptors, AF/attrs, new bounds); new
   `userspace.c` stubs incl. pool window; mechanical churn fixes in the
   dependency closure this uncovers (`H.Pages`, `Kernel/Debug.hs`, `H.Mutable`,
   `H.Unsafe`, `Util/Word12` — thin modules, base-library drift only);
   extend `IrqCheck.hs` with an allocPageMap/setPage/getPage/unsetPage
   round-trip assertion. — verify: irq-check additionally reports `vm-ok`;
   spike-check untouched-green.
5. **[trivial] Downstream IRQ call sites** — `Kernel/Interrupts.hs` (table
   keyed by IntId), `SimpleExec.hs` (`IRQ0` → `ppiVirtTimer`), `UserMode.hs`,
   `Kernel/UserProc.hs`, `Kernel/Driver/PS2.hs`, `Kernel/Driver/NE2000/*`
   (mechanical type renames; those drivers stay excluded from the build).
   Best-effort `ghc -fno-code` typecheck per module; full compilation remains
   a phase-4 gate. Update `plans/porting-log.md` (phase-3 entry incl. any
   INTID/attr discoveries) and tick the master-plan checkbox.
   — verify: grep finds no remaining references to the deleted x86 enum.

Explicitly deferred to phase 4 (rationale: no consumer compiles in the
phase-3 build): `H.IOPorts` CPP-gating; trimming the orphaned alignment-
emulation paths in `c_handle_sync` (porting-log open item).

## Files

- Create: `kernel/platform/aarch64/{gic.c,timer.c,irq.c,irq.h,userspace.c,IrqCheck.hs}`,
  `scripts/qemu-irq.exp`.
- Modify: `kernel/platform/aarch64/{start.S,c_start.c,Makefile}`,
  `kernel/platform/aarch64/tinylibc/sys.c`, `kernel/H/Interrupts.hs` (rewrite),
  `kernel/H/VirtualMemory.hs` (rewrite), `kernel/H/Pages.hs` + closure churn,
  `kernel/Kernel/Interrupts.hs`, `kernel/SimpleExec.hs`, `kernel/H/UserMode.hs`,
  `kernel/Kernel/UserProc.hs`, `kernel/Kernel/Driver/{PS2.hs,NE2000/*}`,
  `Makefile` (irq-* targets), `plans/porting-log.md`,
  `plans/ghc-9.14-aarch64-port.md` (checkbox + pointer).
- Delete: nothing.

## Risks

- **PPI INTID / GICv3 sequencing surprises** (27-vs-26/29 mix-ups,
  redistributor wake, SRE traps): mitigated by printing IAR/GICR state in
  step 1; driver isolated in `gic.c` so a `gic-version=2` fallback is a
  contained rewrite if GICv3 fights back.
- **ISR-context replay of the RTS SIGVTALRM handler** — the long-flagged
  highest-risk seam — is exercised first against the minimal spike (step 2)
  while the failure surface is tiny. Fallback: flip one flag back to timerfd
  pacing (cooperative-only timing) and route only device IRQs through the
  dispatcher; phase 3's interrupt deliverables survive intact.
- **Dispatcher liveness depends on the poll() shim** registering the fake
  pipe correctly — low (same mechanism paced the phase-2 timerfd), but if
  `threadWaitRead` misbehaves, fallback is a `threadDelay`-polled drain loop.
- **Descriptor attr/MAIR mismatches are invisible to structure-only VM tests**
  and will only surface when user tables are actually walked — accepted;
  activation is out of scope and the assumption is logged.

## Alternatives considered

- **Keep the x86 enum as a compat alias over GIC INTIDs** — rejected: user
  chose the clean break; aliasing would hide INTID semantics from every
  future driver.
- **Defer VM adaptation** — rejected: user explicitly scoped it into phase 3
  (master-plan wording corrected accordingly).
- **Wake the dispatcher via `wfi` FFI loop** (original sketch) — rejected:
  monopolizes the core between ticks and bypasses the proven IO-manager seam.
- **Route the RTS ticker through the Haskell dispatcher too** — rejected:
  ticker latency becomes scheduler-dependent exactly when preemption matters;
  direct ISR replay keeps stock-RTS scheduling semantics.

## Success criteria

- [ ] `make irq-check` passes under hvf **and** tcg: both timer counters
      advance via installed Haskell handlers (dispatcher path proven)
- [ ] `vm-ok` in the same run: PageMap alloc/set/get/unset round-trip green
- [ ] `make spike-check` still passes hvf + tcg — with ticks now delivered by
      PPI 27 interrupts, not the wall-clock timerfd stand-in
- [ ] No remaining references to the old `IRQ0..IRQ15` enum anywhere in-tree
      (`grep -r 'IRQ0' kernel/` empty outside history)
- [ ] Container builds run pinned `--platform linux/arm64` (apple-container
      rules: inspect asserts `arm64` only, no Rosetta)
- [ ] Legacy i386 flow diff stays additive-only
