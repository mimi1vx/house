# Port House to GHC 9.14 — aarch64-first, no GHC patches

## Current state

House/hOp v0.8.93 is a Haskell micro-kernel built by downloading GHC **6.8.2**
sources, patching them (HaLVM + house patches: custom primops
`registerForIRQ#`/`waitNextInterrupt#`, a new blocked state, modified
base/RTS), building stage1, then linking a GRUB multiboot IA32 kernel against
tiny libc/gmp/m/libgcc shims (`support/`). ~167 Haskell modules under
`kernel/`, plus Hugs-based font tooling and Linux-host Makefiles. The branch
is at the initial commit — no porting work started.

Decisions made with user:
- **Goal:** bootable interactive shell in QEMU (feature parity adapted to hardware below).
- **Strategy:** **no GHC-tree patches** — stock GHC 9.14; IRQ plumbing redesigned on stock RTS facilities.
- **Target/host:** **aarch64 primary**, built in a linux/arm64 Apple container.

Consequences of aarch64 (stated assumptions):
- Boot = QEMU `-M virt -kernel house.elf` (direct ELF). GRUB/floppy/mkbe2gbf/genext2fs become obsolete (left dormant, not deleted).
- Console = PL011 serial (`-nographic`). No VGA/VBE, no PS/2 keyboard, no ISA NE2000 / i8255x on `virt`; those drivers are excluded from the build initially.
- `H.IOPorts` (x86 `in`/`out`) has no aarch64 equivalent → CPP-gated / replaced by MMIO accessors; drivers depending on it are excluded initially.
- i386 path stays in-tree, dormant ("aarch64 primary").

## Architecture of the port

Stock **GHC 9.14.1 aarch64-linux bindist** (Debian-family glibc container —
the only official 9.14.1 aarch64 bindist is `deb10`; no musl build exists)
+ **non-threaded RTS**, linked freestanding:

- Tiny libc shim (grown from existing `support/tiny_c` idea): string/mem funcs,
  a **bump `mmap`/`mprotect`/`munmap`** backing the RTS block allocator,
  `write`→PL011 UART, and a **faked ticker/signal API** (`setitimer` /
  `timer_create`/`sigaction` recorded, ticks synthesized from the ARM generic
  timer ISR calling the recorded SIGVTALRM handler). This last seam replaces
  exactly what the old RTS patches did — but lives in *our* C, not GHC's.
- `cbits/aarch64/start.S` + `c_start.c`: EL1 setup, stacks, VBAR_EL1 vectors,
  GIC init, generic-timer IRQ, then `hs_init()`/`main`.
- `H.Interrupts` redesign (replaces primops + patched Select.c/Signals.c):
  C ISR masks at GIC, pushes IRQ# into a ring buffer; a Haskell dispatcher
  thread does `wfi` (FFI) → drains ring → runs registered `StablePtr (H ())`
  handlers → EOI/unmask. All inside stock RTS guarantees.
- Linker script places `.text` at the chosen load address with `start.S` first;
  `mbchk` replaced by `readelf` entry/layout checks.

## Plan

1. **[small] Build environment scaffold** — `Containerfile` (linux/**arm64**
   pinned; use the `apple-container` skill conventions when executing: force
   arm64, catch silent amd64 fallback), Debian 12 base, GHC 9.14.1 via ghcup
   (minimal profile), binutils/gcc; **QEMU runs on the macOS host** (Homebrew,
   HVF) — container is build-only. Details: `plans/phase-1-build-env.md`.
   — verify: image arch assert (`arm64` only), `uname -m` → `aarch64`,
   `ghc --version` → `9.14.1`, mounted compile-and-run prints a line.

2. **[medium] Freestanding RTS spike** — new `kernel/platform/aarch64/`:
   `start.S`, `c_start.c`, tiny-libc stubs incl. faked ticker, linker script,
   minimal `Main.hs`. Details: `plans/phase-2-spike-completion.md`
   (consolidates the pre-existing spike attempt; current blocker is a
   DFSC=0x35 data abort on exclusive loads after `hs_init`). — verify: QEMU
   `-M virt -nographic -kernel spike.elf` prints a line produced by Haskell
   `putStrLn` through RTS→shim→UART, plus paced threadDelay ticks.

3. **[medium] H-layer adaptation** — rewrite `kernel/H/Interrupts.hs` with a
   GIC-native API (decided 2026-08-26: no x86 IRQ0..15 compat enum); GICv3 +
   generic-timer drivers, ISR tick switchover, Haskell dispatcher thread;
   adapt `H.VirtualMemory` to aarch64 page-table format with `userspace.c`
   support (MemRegion/AdHocMem turned out to hold no address constants).
   Details: `plans/phase-3-interrupts-vm.md`.
   — verify: `make irq-check` green (hvf+tcg): timer counters advance via
   dispatcher handlers + PageMap round-trip; `spike-check` stays green.

4. **[large] Mechanical module port** — introduce a cabal-less `ghc --make`
   build (new `kernel/Makefile.aarch64` or top-level rewrite) with a
   `default-extensions` set replacing `-fglasgow-exts/-fallow-*`; fix
   base/containers/MonadFail/API churn across the reduced-Main closure
   (measured: ~35–40 of the ~123-module full closure; Gadgets/Net/PCI
   excluded); maintain an explicit **excluded-modules list** (IA32 drivers,
   gfx, net, osker/hovel, DomOS4, user/). Keep a porting log. Gate extended
   (2026-08-31): the linked kernel also boots and prints the shell welcome
   via PL011. Details: `plans/phase-4-module-port.md`.
   — verify: `ghc --make` green for the reduced Main; `make house-check`
   (banner) green; excluded list reviewed and justified.

5. **[medium] Shell bring-up** — wire `Kernel.LineEditor` + shell to PL011 RX;
   ensure `threadDelay`/timers work via synthesized ticks. — verify: scripted
   QEMU session (`expect`-style) reaches the shell prompt, echoes a typed
   command, executes a builtin, exits cleanly.

6. **[trivial] Smoke-test automation + docs** — `make run` / `make check`
   wrapping the QEMU script; README section describing the new build. —
   verify: `make check` passes end-to-end from clean clone inside container.

## Files

- Create: `Containerfile`, `kernel/platform/aarch64/{start.S,c_start.c,gic.c,timer.c,uart.c,tinylibc/*,aarch64.ld}`, rewritten `kernel/H/Interrupts.hs`, `Makefile` (new targets; old ones retained), `scripts/qemu-smoke.exp`, `plans/porting-log.md`.
- Modify: top-level `Makefile` (add aarch64 flow alongside legacy), `kernel/H/{IOPorts,MemRegion,AdHocMem,Monad}.hs`, many `kernel/**/*.hs` (mechanical API fixes), `createFontFile.hs` (runhugs → runghc).
- Delete: nothing (legacy i386 flow left dormant).

## Risks

- **Faked ticker/signal seam** is the highest-risk piece (ISR calling RTS
  handler in IRQ context). Mitigated: proven alone in step 2–3 before mass
  porting; fallback = cooperative-only scheduling (no preemption, polled time).
- **Bindist/distro mismatch** (glibc vs musl): pair Alpine bindist ↔ Alpine
  container or Debian bindist ↔ Debian container; mismatch shows immediately
  in step 1.
- **Base-library churn surprises** in Gadgets/Net code (old Exception
  hierarchy, Set.fold arity, PackedString usage in 5 files): mechanical but
  potentially noisy; bounded by the excluded-modules list.

## Alternatives considered

- **Faithful re-patch of GHC 9.14** (Hadrian-era redo of halvm/house patches) — rejected: user chose no-patch route; orders of magnitude more work and fragile across GHC releases.
- **i386-first, then arch port** — rejected: user wants aarch64 primary; i386 stays dormant in-tree.
- **Cross-target triple `aarch64-unknown-house`** (build custom cross-GHC) — rejected: hours-long GHC builds for little gain over the bindist + shim approach.

## Success criteria

- [x] Container: `ghc --version` = 9.14.x on linux/arm64 (step 1)
- [x] Spike kernel prints Haskell-produced text via PL011 in QEMU (step 2)
      — plus paced threadDelay ticks (`ticks-ok`), hvf *and* tcg,
      `make spike-check` from clean at 512M/1G/2G/4G (see porting-log
      phase 2 for the four stacked root causes behind DFSC=0x35)
- [x] Tick counter advances via IRQ-driven dispatcher + `vm-ok` PageMap round-trip (step 3 — GICv3 PPIs 27/30, timerfd tick seam, dispatcher thread, aarch64 L0–L3 descriptors, see porting-log phase 3 + `plans/phase-3-interrupts-vm.md`)
- [x] Reduced-module kernel links; `readelf -h` shows correct entry/load addr (step 4 — `make house-check` green hvf+tcg, 15-module closure via `kernel/Makefile.aarch64`, see `plans/phase-4-module-port.md` + porting-log phase 4)
- [x] Scripted QEMU session reaches shell prompt and executes a command (step 5 — `make house-shell-check` hvf+tcg: welcome → `> ` → `help`→Usage → `lambda` → `wastemem 10`→55 via PL011 RX→KeyPress, see `scripts/qemu-house-shell.exp`)
- [ ] `make check` reproduces the above from clean state (step 6)
