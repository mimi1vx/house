# Porting log — GHC 6.8.2/i386 → GHC 9.14.1/aarch64

Running log of deviations, discoveries and fixes. One entry per completed
phase (see `plans/ghc-9.14-aarch64-port.md` for the master plan).

## Phase 1 — build environment (2026-08-26)

- Container: `house-port:latest`, built from `Containerfile`
  (debian:12-slim, ghcup MINIMAL profile, GHC 9.14.1).
- Verified: `container image inspect` → `arm64` only; in-container
  `uname -m` → `aarch64`; `ghc --version` → 9.14.1.
- **Deviation from phase-1 doc:** apt dep is `libgmp-dev`, not `libgmp10`.
  `libgmp10` provides only the runtime `.so.10`; linking any Haskell program
  fails with `/usr/bin/ld: cannot find -lgmp`. Caught by the mounted
  compile-and-run check exactly as the risks section predicted.
- QEMU 11.1.0 installed on macOS host via Homebrew (HVF accel available);
  `qemu-system-aarch64 --version` verified.
- `CONTAINER_DEFAULT_PLATFORM` intentionally **not** set globally; every
  container/build invocation passes `--platform linux/arm64` explicitly
  (apple-container skill belt-and-braces rule).
- Legacy i386 flow untouched: `git diff` on `Makefile` shows additions only
  (`container-image`, `container-shell` targets).

## Phase 2 — freestanding RTS spike (2026-08-26)

Baseline first: the stalled attempt was committed as-is
(`feat: aarch64 port scaffold + freestanding spike (pre-phase-2 baseline)`)
so every phase-2 diff reviews against preserved working state.

### Boot blocker, root-caused (debug-loop, before fixing)

The fatal `ESR=0x96000035` on `LDAXR` decomposed into four stacked causes,
each confirmed by experiment before its fix:

1. **MMU off ⇒ all data accesses are Device-nGnRnE.** Device memory forces
   natural alignment *regardless of SCTLR.A* — hence the alignment-fault
   emulations firing during boot — and disallows exclusives outright.
   Decisive experiment: unaligned `STP` succeeds once RAM is mapped Normal,
   while ordinary loads keep working; H2 ("HVF misreports misaligned
   exclusives") falsified. Fix: early identity page tables
   (`mmu.c`, L0→L1, 1GB blocks; block 0 Device for PL011/GIC, RAM Normal;
   caches deliberately stay off — Normal non-cacheable carries full access
   semantics without cache-maintenance hazards).
   Gotcha learned the hard way: TTBR0 starts the walk at L0 with 4KB
   granules — an "L2-style" table directly at TTBR0 is read as garbage
   table descriptors and every post-enable fetch storms. 48-bit VA
   (T0SZ=16) is required because the stock RTS reserves terabyte-scale
   arenas; single-table tricks cap VA below what GHC probes.
2. **Apple HVF exits guest LL/SC ops as ISV=0 data aborts** (IMPDEF
   DFSC=0x35, no instruction syndrome) that QEMU 11.1 forwards into the
   guest — upstream is only now adding QEMU-side emulation of exactly
   these classes (March 2026 patch series). Independent of mapping
   attributes: reproduced with a bare exclusive pair on a stack word
   after the MMU fix. Fix: single-core emulation of all 12
   LDXR/LDAXR/STXR/STLXR byte/half/word/double forms in `c_handle_sync`
   (`emu_exclusive`) — always-succeeding STXR is architecturally sound
   uniprocessor, mirroring QEMU's own ISV=0 strategy.
3. **Shim mmap semantics vs the stock RTS reservation ladder.** The RTS
   reserves terabyte-scale arenas at ascending hint addresses, retries on
   failure and does not check later commits. Refusing oversized requests
   poisoned GC metadata (wild `bdescr->link` → fatal fetch inside
   `GarbageCollect`); granting them as phantoms aliased live allocations.
   Fix in `alloc.c`: hinted reserves granted exactly as VA promises,
   tracked and released by `munmap`; `MAP_FIXED` commits demand backing;
   the arena window (VA 0x4200000000+, GHC's working base found by its own
   ladder) aliases the upper half of guest RAM through 2MB blocks so
   commits are backed and overruns fault loudly. Alias PA must NOT overlap
   kernel image/pool — first attempt scribbled over our own .text.
4. **Bump-malloc size headers had no reserved slot**: each allocation's
   header (`*(p-16)=n`) landed inside the previous object whenever padding
   allowed, stomping `gc_thread` fields — caught red-handed with a QEMU
   gdbstub watchpoint (`initStorage` init vs `malloc+60` stomp). Fix:
   carve the header slot out before the object (`pool_alloc`).

### Making Handles work (stock base library expectations)

- `iconv_open` failing (ENOSYS) made every TextEncoding fail, so the very
  first `putStrLn` threw an exception whose *reporting* also threw
  ("encountered an exception while trying to report an exception").
  Passthrough `iconv` trio now: GHC only converts UTF-8/ASCII locale
  variants; gconv module files don't exist freestanding.
- Empty locale name dropped base into its wide-char fallback (UCS-4 bytes
  on the wire — observed as NUL-byte output). Base derives the charset
  from `nl_langinfo(CODESET)`; it now answers `"UTF-8"`. Also
  `setlocale`→"C.UTF-8" and LANG/LC_ALL/LC_CTYPE via `getenv`.
- `pthread_join` returned ENOENT → spurious "Ticker: Failed to join".
  Ticker threads are accepted on paper and never scheduled (single CPU);
  join returns 0.
- Control-pipe writes failed because `pipe()` stored slot indices as peers
  while consumers convert them as fd numbers. Peers are fd numbers now.

### Ticker / threadDelay proof

GHC 9.14's ticker (rts/posix/ticker, timerfd-based even for `-N1`) is
served by a fake timerfd paced by wall clock: `read()` answers EAGAIN and
`poll()` reports not-ready until `tick_interval_ns` has elapsed since the
last delivered tick (the always-readable counter would make select loops
fire unboundedly — liveness without timing). `Spike.hs` runs 4×
`threadDelay 500000` printing measured deltas (~500.005 ms observed under
HVF, ~500.01 ms under TCG) and ends with `ticks-ok`.

### RAM sizing (user direction)

Starting with `-m 512G` was a bad idea (hypervisor/host-hostile, and the
host has 32GB). Guest RAM is now `SPIKE_MEM ?= 4G` at the top level: one
variable compiles the extent into the kernel (`HOUSE_RAM_BYTES`,
`BOOT_STACK_TOP` defines; boot stack sits just under ram_top, RTS alias
window takes upper-half RAM) and drives the QEMU `-m` flag, so kernel and
runner cannot disagree. Verified end-to-end (`make spike-check`): 512M,
1G, 2G, 4G — clean container build, HVF boot, paced ticks, `ticks-ok`;
TCG re-verified at 4G. Legacy i386 flow untouched (additive diff only).

### Open items carried into phase 3

- Ticks currently flow through the paced-timerfd seam; phase 3 replaces
  delivery with the ARM generic-timer ISR calling `house_rts_tick()`
  (the replay path already exists in sys.c).
- Alignment-emulation paths in `c_handle_sync` are now orphaned (Normal
  memory + SCTLR.A=0 never faults on the GHC copies) — kept until the
  phase-4 mass port proves no other source of unaligned faults, then trim.
- `-M256M` style RTS options exit(1) during flag processing with an empty
  message; unused since reservations behave, but worth understanding if
  RTS options are ever needed on the kernel command line.

## Phase 3 — GICv3 + ticks + VM adaptation (2026-08-31)

- **GICv3 + timers (step 1):** `kernel/platform/aarch64/{gic.c,timer.c,irq.h}`.
  `ICC_SRE_EL2=1` in the EL2 trampoline (otherwise EL1 `SRE_EL1.SRE` traps),
  `ICC_SRE_EL1.SRE=1`, `ICC_PMR=0xff`, `GICR_WAKER` cleared then polled,
  `GICR_IGROUPR0` marks PPIs 27/30 as Group-1, `GICD_CTLR.EnableGrp1=1`,
  `GICR_ISENABLER0` enables 27/30 (and 29 alias), `ICC_IGRPEN1_EL1=1`.
  Boot prints `gic ok` state. QEMU `virt` with both HVF and TCG reports
  `GICR_WAKER` 0/0, `GICD_CTLR` 0x50→0x52, `GICR_ISENABLER0=0x68000000`.
  **INTID discovery:** virtual timer is **27 (0x1B)** as expected; physical
  timer is **30 (0x1E)** (the non-secure PPI) — `gcm-version=3` under QEMU
  exposes 30, not the secure-alias 29. The driver now enables 27/30 (plus
  29 for completeness) at the redistributor and rearms the matching
  `CNTV_TVAL`/`CNTP_TVAL` in the ISR. Verified by printing `ICC_IAR1_EL1`
  per IRQ before the print was removed.

- **Vector + tick seam (step 2):** `start.S` gains `vec_irq` (duplicate of
  `vec_sync` frame, x0–x30/SP/q0–q31, calls `c_handle_irq(frame,fpu)`);
  all four IRQ slots now branch to `vec_irq`. `c_handle_irq` acks via
  `ICC_IAR1_EL1`, rearms the firing timer, pushes the INTID to the SPSC
  ring, and issues `ICC_EOIR1_EL1`. The RTS ticker seam is now
  **timerfd-driven by hardware:** `house_timer_init` sets
  `house_isr_active=1` and arms both timers at `cntfrq/100` (≈10 ms);
  `c_handle_irq` increments `house_isr_pending` on PPI 27, `sys.c:read`
  consumes one pending per `read(timerfd)` and returns 1 tick, and
  `house_timerfd_due` returns `pending>0` while ISR ticks are active
  (otherwise falls back to wall-clock pacing). The paced-wall-clock path
  is thus fully gated off. `spike-check` now proves ticks are
  hardware-sourced: `threadDelay 500000` still reports ≈500.005 ms (HVF)
  and `ticks-ok` passes hvf and tcg at 512M/4G with `PLIC`/`GIC` enabled.

- **Bring-up gotchas:** a hand-passed `BOOT_STACK_TOP=0x3FE00000` (off by
  ~0x1FC00000 for 512M) made the first exception save fault with
  `ESR=0x96000050 FAR=0x3FDFFFF0 ELR=0x40081070` and a storm of translation
  faults; the fix was to reuse the top-level Makefile's
  `SPIKE_DEFS_C/S` computed defines for `irq-build` (the same values
  `spike-check` uses). A second storm (`ESR=0x96000004 FAR=0x0A004000`) was
  the FP-save in the handler saving to a corrupt SP. `make clean` is now
  mandatory when `HOUSE_*` changes; the `irq-check` wrapper does it.

- **Dispatcher + `H.Interrupts` + IrqCheck (step 3):** `irq.c` implements a
  256-entry SPSC ring (`head`/`tail` volatile, I-masked producer) plus a
  1024-byte pipe pair. `house_irq_push` (ISR) stores `INTID`, `dmb`, bumps
  `head`, then `write(pipe_w, byte)`; `house_irq_pop`/`house_irq_pipe_drain`
  are consumed by Haskell. `H.Interrupts` is rewritten to the GIC-native
  API (`newtype IntId = IntId Word32`, `ppiVirtTimer=27`, `ppiPhysTimer=30`,
  `spi n = 32+n`, `enableInt/disableInt/eoi/installHandler`,
  `enable/disableInterrupts` via `DAIF.I`). The handler table is a
  Haskell-side `IOArray IntId 0..1023 (StablePtr (H ()))`; `installHandler`
  idempotently forks a dispatcher thread. The intended
  `threadWaitRead(pipe_fd)` wakeup deadlocked the single-capability RTS
  (the select-based IO manager's 1 ms timeout interacted with the tick
  delivery): diagnostic `expect` showed main's second `threadDelay` hung
  while `house_isr_pending` grew. The fallback (documented in the risks)
  is used: a `threadDelay 20000` poll that drains the pipe then a bounded
  ring drain (`64` entries per wakeup, so the dispatcher never starves the
  scheduler) and runs the handler via `StablePtr` with an
  `exception`-catching wrapper. `IrqCheck.hs` installs both timer handlers,
  counts ticks for ~2 s and asserts `>5` each, printing `irq-ok`; it now
  also extends to `vm-ok`. `scripts/qemu-irq.exp` and top-level
  `irq-build`/`irq-run`/`irq-check` mirror the spike targets, all pinned
  `--platform linux/arm64`. `make irq-check` passes hvf and tcg (e.g.
  `final virt=198 phys=198 irq-ok`, TCG `virt=163 phys=163`).

- **VM adaptation (step 4):** `H.VirtualMemory` rewritten for aarch64 4KB
  granule page tables: `VAddr = Word64`, window **`0x01000000..0x3FFFFFFF`**
  (below the kernel image at `0x40080000` and outside the RTS alias
  `0x4200000000+`), L0 index [47:39], L1 [38:30], L2 [29:21], L3 [20:12];
  L0–L2 allocated eagerly per PageMap (mirrors the old pdir/ptable split one
  level deeper), L3 on demand. Descriptors carry `AF=1` (mandatory),
  `AP=01/11` (RW/RO), `AttrIdx=0` (Normal MAIR 0xFF), `SH=Inner` (0b11),
  `nG=1`, `UXN/PXN=1`, with SW bits `[55]`/`[56]` for `dirty`/`accessed`
  so structure-level round-trip tests capture those fields (HW never walks
  the tables while `TTBR0` stays the kernel's). `userspace.h/c` provide
  the page-pool window: a 512-page (2 MB) `page_pool[512*4096]` in `.bss`
  (thus identity-mapped Normal, 0x4076xxxx, distinct from the bump heap at
  `0x42000000` and the upper-half alias), exported as
  `min_user_addr`/`max_user_addr`; `init_page_dir`/`current_pdir` are a
  recorded pointer and `invalidate_page` is `TLBI VAAE1IS`+`DSB/ISB`
  (safe no-op while tables are never loaded). Closure churn:
  `H.Utils` gains `Word64` ptr helpers, `H.AdHocMem` adds `absolutePtr64`,
  `H.Concurrency` stubs `isEmptyChan` (removed in base 4.22),
  `H.AdHocMem` drops `unsafeFreeze` (now `freeze`), `Kernel.Console`
  uses `error` not `fail` (MonadFail), and `H.Monad` gains `Applicative`
  plus a typed `trappedRunH` handler. `IrqCheck.hs` now runs an
  `allocPageMap`/`setPage`/`getPage`/`unsetPage` round-trip (RO/RW, two
  pages, distinct PageMaps, check free-of-pending-mappings) and prints
  `vm-ok`. Verified: `make irq-check` (hvf+tcg) prints `vm: round-trip ok`
  and `vm-ok` after `irq-ok`; `make spike-check` remains green hvf+tcg.

- **Downstream call sites (step 5):** `Kernel.Interrupts` table is now
  `HArray IntId 0..1023` (not `minBound..maxBound`) and `eoi` is a no-op (ISR
  already EOIs). `SimpleExec` `IRQ0→ppiVirtTimer`,
  `Kernel.UserProc` `IRQ0→ppiVirtTimer`, `H.UserMode` `IRQ→IntId`,
  `Kernel.Driver.PS2` `IRQ1→spi 1`/`IRQ12→spi 12`,
  `Kernel.Driver.NE2000` `IRQ9→spi 9` and driver `initialize` now
  `IntId-typed`; `HovelM` and interface datatypes updated similarly.
  All compile with `ghc -fno-code --make -i... -outputdir build` (base
  drift only; full link remains a phase-4 gate). `grep -rn 'IRQ0'`
  over `kernel --include='*.hs,*.lhs'` is empty; `kernel/cbits/onIRQ0`
  and generated html docs are the only remaining hits and are legacy/docs.
  `grep -rn 'IRQ0'` outside that is empty.

- **Container:** every invocation uses `--platform linux/arm64`; `container
  image inspect` asserts `arm64` only (no Rosetta). Legacy i386 flow diff
  remains additive-only.

- **Carry-forward:** `H.IOPorts` CPP-gating and trimming the now-orphaned
  `c_handle_sync` alignment-emulation paths remain deferred to phase 4.
