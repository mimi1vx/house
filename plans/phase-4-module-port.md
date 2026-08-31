# Phase 4 — mechanical module port: reduced Main links and boots

Details doc for step 4 of `plans/ghc-9.14-aarch64-port.md`. Written 2026-08-31,
after phases 1–3 completed (see `plans/porting-log.md`).

## Decisions made with user (2026-08-31)

- **Phase-4 gate extends to a boot banner**: the small PL011 console-output
  driver lands in phase 4, so `house-check` proves build → link → boot →
  welcome banner over PL011, then blocks. Step 5 is then pure input work
  (UART RX → KeyPress → LineEditor).
- **Bare-minimum shell command set** in the reduced Main: `help`, `lambda`,
  `preempt`, `wastemem` only. Excluded-hardware commands are simply absent
  from `help`, not stubbed.

## Current state

Phases 1–3 left a stock-RTS freestanding kernel platform (spike + irq-check
green under hvf and tcg), a GIC-native `H.Interrupts`, an aarch64
`H.VirtualMemory`, and downstream IRQ call sites that typecheck with
`ghc -fno-code`. The real kernel (`House.hs`, GHC 6.8.2 build with
`-fglasgow-exts -fallow-undecidable-instances -fallow-overlapping-instances`,
`ldhouse` linker, `mbchk`) has never been compiled against GHC 9.14. The
current aarch64 build hand-lists every module in
`kernel/platform/aarch64/Makefile` (`ghc -c` per module) and links with a
manual `ld -T aarch64.ld`.

Measured today (import-closure walk over `kernel/`, excluding `platform/` and
`user/`):

- Full `House.hs` closure: **~123 in-tree modules** (of 159 `.hs`/`.lhs`).
- Bare-minimum shell closure (Console/LineEditor/Keyboard/Monad.Util/
  CmdLineParser/Grammar + H layer): **~35–40 in-tree modules** — the exact
  set falls out of `ghc --make`.
- `launchConsoleDriver` lives in `Kernel.Driver.IA32.Screen` (excluded) → a
  new PL011 consumer is required. `launchKeyboardDriver` lives in
  `Kernel.Driver.PS2` (excluded) → step 5 replaces `kbdChan` with a UART-RX
  producer; phase 4 passes an empty `Chan KeyPress` (shell blocks after the
  banner).
- `Data.PackedString` is confined to `Kernel/PCI/{DevInfo,ParseVendors}.hs`
  (both excluded) → **no shim needed**.
- `Kernel.Timer` is a 3-liner used only by excluded modules → drops out.
- The `H.IOPorts` "CPP-gating" carry-forward is **moot**: every consumer
  (`SimpleExec`, `CMOS`, `PS2`, `NE2000`, `Intel8255x`, `IA32/Screen`,
  `PCI/ConfigSpace`, `H.All`) is excluded; `H.IOPorts` itself is pure FFI
  declarations that compile fine. Logged as a deviation, no gating.
- `Console = MVar ConsoleData{consoleChan :: Chan ConsoleCommand, …}` with
  ops `PutChar/NewLine/CarriageReturn/ClearEOL/MoveCursorBackward/ClearScreen`
  (`Kernel/Types/Console.hs`) — a terminal-emulating PL011 consumer is ~50
  lines. `uart_putc`/`uart_puts` already exist in `platform/aarch64/uart.c`.
- `Kernel.Debug`, `Kernel.Console`, `Kernel.Types.Console`, `H.Mutable`,
  `H.Utils` already compile (phase-3 `VM_HS` list). The churn surface is the
  ~15 modules new to the 9.14 build — the feared Gadgets/Net churn is
  **excluded**, so phase 4 is smaller than the "large" tag suggests.

## Design

### Entry module `kernel/HouseA64.hs` (new)

Trimmed copy of `House.hs`: no gfx/VBE/GIF/Gadgets, no Net, no PCI, no
user-mode (`SimpleExec`/`UserProc`/`H.UserMode`), no Grub-module commands
(no multiboot modules on the `-kernel` boot path), no CMOS/reboot/PS2/mouse.
Keeps: `H.Monad`/`H.Concurrency`/`H.Interrupts.enableInterrupts`, `idle`,
`Kernel.Debug.v_defaultConsole`, `Kernel.Console`, `Kernel.LineEditor`,
`Kernel.Driver.Keyboard` (interpreter+decoder are arch-independent), the
grammar machinery (`Util.CmdLineParser`, `Util.Grammar`, `Monad.Util`),
command set `help`/`lambda`/`preempt`/`wastemem`, same `welcome` string.

```haskell
foreign export ccall house_main :: IO ()
house_main = runH mainH   -- mirrors Spike.hs / IrqCheck.hs convention
```

`mainH`: `enableInterrupts` → `forkH idle` → `console <- launchConsoleDriver`
→ `putMVar v_defaultConsole console` → `putString console welcome` →
`textShell console` with `kbdChan` = fresh empty `Chan KeyPress`
(boot-banner gate; step 5 swaps in the UART-RX producer).

### PL011 console driver `kernel/Kernel/Driver/PL011.hs` (new)

`launchConsoleDriver :: H Console`: builds `ConsoleData` (nominal 80×25) and
forks a consumer thread mapping `ConsoleCommand` → UART FFI
(`foreign import ccall unsafe "uart_putc"`): `PutChar _ c` (with `\n` → CRLF),
`NewLine` → CRLF, `CarriageReturn` → CR, `MoveCursorBackward n` → n× BS,
`ClearScreen` → `ESC[2J ESC[H`, `ClearEOL` → `ESC[K`. VideoAttributes ignored.
Plain `Chan` reads — no `threadWaitRead` (phase-3 dispatcher lesson).

### Build split

- **`kernel/Makefile.aarch64` (new)** — the closure build, run inside the
  arm64 container:
  `ghc --make -no-link HouseA64.hs -i. -outputdir build-kernel -O1 -package mtl`
  plus an explicit `default-extensions` set replacing `-fglasgow-exts` and
  the `-fallow-*` flags. Seed set (refined add-on-error, final set pinned
  here and in the porting log): `MultiParamTypeClasses`,
  `FunctionalDependencies`, `FlexibleInstances`, `FlexibleContexts`,
  `UndecidableInstances`, `OverlappingInstances` (fallback: per-instance
  `OVERLAPPING` pragmas if 9.14 rejects the flag), `ImplicitParams`,
  `ExistentialQuantification`, `ScopedTypeVariables`, `Rank2Types`,
  `KindSignatures`, `PatternGuards`, `ForeignFunctionInterface`,
  `GeneralizedNewtypeDeriving`.
  The file also carries the **excluded-modules list** as a comment block
  (operational single source of truth).
- **`kernel/platform/aarch64/Makefile` gains a `house` target** — extends the
  proven link line: `find build-kernel -name '*.o'` + `start.o mmu.o
  c_start.o uart.o` + tinylibc + platform C + the same
  `--start-group … --end-group` static libs, `ld --build-id=none
  --gc-sections -T aarch64.ld`. `c_start.c` gains a weak `house_main`
  extern + branch (same pattern as `house_irqcheck_main`/`house_spike_main`).
  Verify via the existing `readelf -h` gate: `ENTRY(_start)`, AArch64.
- **Top-level `Makefile`**: `house-build` / `house-run` / `house-check`
  mirroring `irq-*` (container runs pinned `--platform linux/arm64`,
  `DEFS_C`/`DEFS_S` passed so RAM/stack defines can never disagree with
  QEMU's `-m`, full clean inside `house-check`). `scripts/qemu-house.exp`
  asserts the welcome string under hvf **and** tcg.

Fallback if `--make -no-link` misbehaves: generate the module list from the
closure and loop `ghc -c` (the current hand-listing, automated) — mechanical,
no design change.

## Plan

1. **[small] Console driver + entry skeleton** — `Kernel/Driver/PL011.hs`,
   `HouseA64.hs` (full shell, empty kbdChan), `c_start.c` weak branch.
   — verify: `ghc -fno-code` typechecks both new modules in isolation.
2. **[medium] Closure build + first attempt** — `kernel/Makefile.aarch64`
   with seed extensions; run `ghc --make -no-link`; capture the full error
   inventory into the porting log before fixing anything.
   — verify: inventory recorded; extension delta vs seed noted.
3. **[large] Churn fixes to green** — fix base/containers/MonadFail/API
   drift across the ~35–40-module closure as the compiler demands
   (anticipated: MonadFail sites, `Set.fold` arity, Exception-hierarchy
   stragglers, missing Applicative instances — H-layer already fixed in
   phase 3). One porting-log entry per non-obvious fix; final
   `default-extensions` set pinned in the Makefile.
   — verify: `ghc --make -no-link` green.
4. **[small] Link + readelf gate** — `house` target in the platform
   Makefile; `readelf -h` shows correct entry and load address.
   — verify: `house.elf` links from clean `build-kernel`.
5. **[small] Boot-banner smoke** — top-level `house-build/run/check` +
   `scripts/qemu-house.exp` (welcome string, hvf + tcg).
   — verify: `make house-check` green both accels.
6. **[trivial] Excluded-modules list** — comment block in
   `kernel/Makefile.aarch64` with per-module justification (IA32 drivers,
   gfx, net, PCI, user-mode/AOut, PS2/mouse/CMOS, osker/hovel/DomOS4/L4,
   `user/`, `H.All`, `Gadgets/*`, `H.IOPorts` unused-not-gated).
   — verify: list reviewed against the closure (`ghc --make -v0` output).
7. **[trivial] Phase-3 carry-forward** — trim the orphaned
   alignment-emulation paths in `c_handle_sync` once `house-check` proves
   no other unaligned-fault source (porting-log phase-2 open item).
   — verify: `spike-check`, `irq-check`, `house-check` all still green.
8. **[trivial] Bookkeeping** — porting-log phase-4 entry; master-plan
   checkbox + pointer.

Steps 2–3 interleave in practice (each error batch feeds a fix batch); they
are split so the inventory is preserved before any edit, per debug-loop.

## Files

- Create: `kernel/HouseA64.hs`, `kernel/Kernel/Driver/PL011.hs`,
  `kernel/Makefile.aarch64`, `scripts/qemu-house.exp`.
- Modify: `kernel/platform/aarch64/Makefile` (`house` target),
  `kernel/platform/aarch64/c_start.c` (weak `house_main` branch),
  `Makefile` (`house-build/run/check`), ~15–25 `kernel/**/*.hs` (mechanical
  fixes, exact set = compiler output), `plans/porting-log.md`,
  `plans/ghc-9.14-aarch64-port.md` (pointer + checkbox).
- Delete: nothing.

## Risks

- **`-no-link` flag semantics** (assumed present since GHC 9.0): fallback is
  a generated per-module `ghc -c` loop — mechanical, no design change.
- **Extension-set holes** (e.g. `OverlappingInstances` removed in 9.14 →
  per-instance pragmas): bounded by add-on-error iteration; final set pinned.
- **Module cycles** surfacing for the first time under `--make` (old tree
  predates strict acyclicity discipline): escalate to hs-boot files or a
  small local refactor — flagged in the porting log if hit.
- **Real kernel's memory appetite** vs the spike-tuned RTS alias window /
  bump allocator: `SPIKE_MEM` is already the one knob; expect behavior
  identical to the spike's RTS reservation ladder, low risk.
- **Console consumer scheduling** on the single-capability RTS: plain Chan
  reads only (no `threadWaitRead`), same pattern as the proven spike output
  path; low risk.

## Alternatives considered

- **CPP-gate `House.hs` in place** — rejected: a separate `HouseA64.hs`
  keeps the legacy i386 flow untouched (additive-only diff is a standing
  criterion) and avoids `#ifdef` noise in the shell.
- **Compile the full ~123-module closure now** (keep gfx/net compiling) —
  rejected: user chose the bare-minimum shell; the excluded list keeps the
  churn bounded exactly where the feared legacy-API drift lives (Gadgets/
  Net/PCI). Re-inclusion is a later, optional phase.
- **cabal project instead of `ghc --make`** — rejected: master-plan decision
  (cabal-less); the freestanding link is a manual `ld -T` either way.

## Success criteria

- [ ] `make house-check` passes hvf **and** tcg: clean container build,
      kernel links, `readelf -h` shows `ENTRY(_start)`/AArch64, boot prints
      the House shell welcome via Console→PL011, then blocks on empty input
- [ ] `ghc --make -no-link` green for the reduced closure with an explicit
      pinned `default-extensions` set (recorded in `kernel/Makefile.aarch64`
      and the porting log)
- [ ] Excluded-modules list written with per-module justification; PackedString
      and IOPorts consumers confirmed absent from the closure
- [ ] `make spike-check` and `make irq-check` remain green hvf + tcg
- [ ] `c_handle_sync` alignment-emulation paths trimmed (phase-3 carry-forward)
      with all three checks green
- [ ] Legacy i386 flow diff stays additive-only
- [ ] Porting-log phase-4 entry and master-plan checkbox updated
