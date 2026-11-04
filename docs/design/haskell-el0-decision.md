# Haskell EL0 decision (stock GHC output is not a target)

Decision for `house-oz9.5`. Docs only — no code, no loader/linker change.
Status: decided; the decision it records belongs to `house-oz9`
(Phase 1-3 residue) and sequences against `house-q0g`
(provenance (ii) vs gate-table route).

## Decision

No: stock GHC output is never an EL0 target. "Haskell userspace" means
the EDSL (`userspace/hs/Userspace/Asm.hs`). The GHC-compiled-EL0 route was
abandoned per the GHC size/libc spike in favour of the EDSL, and the
dynamic-linking triage since has only raised its price (see "What a real
binary would concretely need"). Nothing in this bead reopens that route.

## Blocker 1: `svc_imm` never reads `x8`

`svc_imm = esr & 0xFFFF` (`rust/crates/house-boot/src/c_start.rs`,
inside the `ec == 0x15` arm) dispatches house numbers `0x00`–`0x14`
(`rust/crates/house-hal-aarch64/src/svc.rs`,
`kernel/Kernel/Userspace/Syscall.hs`), so glibc's `svc #0` arrives as
House's yield. This is the same ABI gap as `house-q0g.13`, whose proposal
(`docs/design/linux-abi-syscalls.md`) already owns the disambiguation
rule and the stage-1 delegate list — this note duplicates neither and
sequences against that proposal, not before it.

Under provenance (ii) this row is irrelevant to a `house-libc`-linked
image, because nothing in such an image issues a Linux `svc #0`
(`house-q0g.13` caveat, repeated here because this bead is where the
confusion would land). EDSL tools emit house `svc #imm` directly, so the
EDSL-only target needs no `x8` layer at all. The layer stays open under
`house-q0g` for the stock target only.

## Blocker 2: no non-trivial Haskell EL0 object exists to load

No Haskell-compiled object has ever exercised the kernel-side linker.
What one would concretely need, if the stock route were ever reopened:

- Object: GHC rebuilt from source for `-fPIC` dynamic objects, then
  `libHSghc-prim` / `libHSbase` / `libHSghc-internal` re-linked
  `ld.lld -shared --hash-style=sysv -z now`, `NEEDED` on
  `libc-house.so.0`. B2 (`house-q0g.3`, landed) proves the recipe for prim
  alone; B3 (`house-q0g.4`, open, re-scoped) measured why the bindist
  archives cannot yield it: vanilla non-PIC relocs (`ADR_PREL_PG_HI21`)
  and a ~91-symbol `house-libc` gap (libm transcendentals, POSIX
  process/file/event, `stderr`/`environ`).
- Linkage: the branch-B closure (`house-q0g.2` shared flavour +
  B2/B3 rebuilds), the ~91-symbol gap closed against the syscall layer,
  and the `house-q0g.1` caps revisited for internal scale (165,975
  relocs, 59,724 syms, 4,973 pages) — the retune deliberately sized away
  from that object.
- Loader path: already exists. `Loader.parseElf` / `Linker.linkDynamic`
  accept sysv/bind-now objects (the B2 probe links past every parser and
  cap gate to `DependencyMissing`), and the demand pager
  (`house-q0g.11`) serves `PT_LOAD` on fault. The loader is not the gap;
  the object and its linkage are.

## The three missing `Instr` constructors

`Userspace.Asm` stays at 50 constructors: no 64-bit store, no indirect
call, no divide — so still no pointer table, no function pointer, no
`strtol`. The gap is recorded as accepted, not closed, for two reasons:
the module header admits no instruction without a tool that needs it, and
no current tool does. Adding speculative constructors would be the exact
generality the header policy exists to refuse.

Revisit condition: a tool that needs one (a pointer table, a function
pointer, `strtol`-class formatting). Then add the constructor with
coverage in `userspace/test/Golden.hs` and prove byte-neutrality through
the existing drift gate (`scripts/mk-userspace.sh` diffs `house-gen`
output against the checked-in `.s`) — EDSL-only, no new syscalls, no HAL
changes.
