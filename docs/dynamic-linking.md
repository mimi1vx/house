# Dynamic linking — open residue

The dynamic-linking work is tracked as beads under the `house-q0g` epic.
This file holds the reference material those beads cite, so the evidence
survives independently of the issue tracker.

It was distilled from `plans/dynamic-linking-{plan,future}.md` (removed
2026-10-06, when the local `plans/` notes were deleted). Line references
quoted in the beads are live; the `file:line` column in the gate table below
is **as measured on 2026-09-27** and has drifted — use the beads for
current positions.

## What landed

M1–M3.5, the loader-forgiveness slice (C1–C6, `d77be5a`), the phnum/segment
split with the `ByteString` representation, and C8 (`R_AARCH64_ABS64` +
`DT_VERSYM`, `011b538`). M3 is complete. M4 was measured on 2026-09-27 and
**closed as infeasible on the current ABI**. No milestone deletes an existing
static tool or introduces a flag day; EDSL-generated tools stay supported
alongside dynamic ones.

## The open branch

The umbrella plan's status header named it: **branch B — provenance (ii)**,
GHC's libraries rebuilt against `house-libc`, unstarted and needing the cap
retune recorded as its own decision. That route *removes* GNU hash, versioning,
TLS, IFUNC and `_rtld_global` together, because a `house-libc` closure does not
have those properties. The alternative is to honour the unsupported features
one by one (rows 3–13 below). The two routes reach the same end state; picking
one is a decision the epic needs recorded — `house-q0g`.

## M4 ordered gate table

Order is the order `Loader.parseElf` then `Linker.linkDynamic` reaches the
gate. Row 0 is the exception: it is not a parser gate at all, and it decides
the outcome.

| # | gate | measured violation (2026-09-27) | class | state |
|---|---|---|---|---|
| 0 | EL0 syscall ABI | `libc.so.6` has 411 `svc #0x0` with the number in `x8` (`mov x8, #0x5d`); EL1 reads `svc_imm = esr & 0xFFFF` and dispatches house numbers `0x00`–`0x14` | **ABI — decisive** | open — `house-q0g.13` |
| 1 | `maxElfBytes` 1 MiB | 13,024,352 B and 16,038,808 B mains | cap-raise | open — `house-q0g.1` |
| 2 | `maxPhnum` 8 over **all** headers | phnum 10–13, but only 2 are `PT_LOAD`; a 70,440-byte C `hello` from the image's default gcc fails identically | cap-raise | separate one-line format fix, not GHC-scale |
| 3 | `PT_INTERP` must be `/lib/ld-house.so.0` | every object carries `/lib/ld-linux-aarch64.so.1` | policy (relink) | open — part of slice 7 |
| 4 | unsupported `DT_*`, first in table order | `DT_RUNPATH` first rejected in the 72 KB fixtures; `DT_INIT_ARRAY`/`FINI_ARRAY` in all 9 objects | feature | landed by C5/C1–C6 |
| 5 | `DT_GNU_HASH` where v1 pins `--hash-style=sysv` | SysV `DT_HASH` count is 0 in all 9 closure objects; every one has `DT_GNU_HASH` | feature | open — `house-q0g.5` |
| 6 | symbol versioning | `DT_VERNEED`/`DT_VERSYM` in every object | feature | partially landed by C8 (honoured, not selected on) — `house-q0g.8` |
| 7 | `maxSegMemSz` 256 KiB per `PT_LOAD` | 18,521,336 B (`libHSghc-internal`), 1,685,563 B (`libc.so.6`) | cap-raise | open — `house-q0g.1` |
| 8 | Loader `maxTotalPages` 64 per object | 4,972 pages (`libHSghc-internal`) | cap-raise | open — `house-q0g.1` |
| 9 | `maxRelaCount` 4096 | 165,975 relocations in `libHSghc-internal` | cap-raise | open — `house-q0g.1` |
| 10 | `maxDynSymbols` 4096 | 59,724 (`libHSghc-internal`) | cap-raise | open — `house-q0g.1` |
| 11 | `PT_TLS` and TLS relocations | `PT_TLS` in `libc.so.6` and `libHSrts_thr`; 14 `R_AARCH64_TLS_TPREL64`, 2 `R_AARCH64_TLSDESC` | feature | open — `house-q0g.6` |
| 12 | `R_AARCH64_IRELATIVE` | 2 in `libc.so.6` | feature | open — `house-q0g.7` |
| 13 | relocation types outside RELATIVE/GLOB_DAT/JUMP_SLOT | `R_AARCH64_ABS64` ×5,704 (`libHSghc-internal`), ×3,838 (`libHSbase`) | feature | landed by C8 |
| 14 | eager binding | none of the fixtures carries `DT_BIND_NOW`/`DF_1_NOW`, while all carry JUMP_SLOTs | policy (relink `-z now`) | open — part of slice 7 |
| 15 | `maxNeeded` 8 per object | the 72 KB main needs exactly 8 — at the cap, no headroom | cap-raise | open — `house-q0g.1` |
| 16 | `maxDependencies` 8 per graph | closure is main + 8 = 9 objects, at the cap | cap-raise | open — `house-q0g.1` |
| 17 | Linker `maxObjectPages` 64 | 4,972 pages for `libHSghc-internal` | cap-raise | open — `house-q0g.1` |
| 18 | Linker `maxTotalPages` 256 | 6,526 loaded pages for the closure | cap-raise | open — `house-q0g.1` |
| 19 | 4 GiB `maxVAddr` user window | 25.5 MiB ≈ 0.6% of the window | **not binding** | no work needed |
| 20 | whole-`PT_LOAD` mapping, no demand pager | 25.5 MiB resident per mapping process | feature | open — `house-q0g.11`, `house-q0g.12` |

Row 0 is decisive because it is neither a bound nor a missing feature: a Linux
`svc #0` arrives as `svc_imm = 0`, which the house table defines as
`syscallYield`, with `x8` never read. Every other row could be cleared and the
first C-library call would still be mis-dispatched.

Named sites for row 0: `rust/crates/house-boot/src/c_start.rs`,
`kernel/Kernel/Userspace/Syscall.hs`, `rust/crates/house-hal-aarch64/src/svc.rs`.

## The seven slices

M4 reopens only when a Linux-ABI syscall layer exists **and** these land. The
count is checkable against the table:

1. cap retune — rows 1, 7, 8, 9, 10, 15, 16, 17, 18 (one bound review, not
   nine edits; `loadElf` is already `ByteString`, so a 16 MiB image may force a
   representation change in the same slice) → `house-q0g.1`
2. dynamic-tag tolerance and array execution — row 4 → landed
3. GNU hash and symbol versioning — rows 5, 6 → `house-q0g.5`, `house-q0g.8`
4. a new relocation family for `R_AARCH64_ABS64` — row 13 → landed (C8)
5. TLS: `PT_TLS`, `TPREL64`/`TLSDESC`, `tpidr_el0` — row 11 → `house-q0g.6`
6. IFUNC via `R_AARCH64_IRELATIVE` — row 12 → `house-q0g.7`
7. staging and relink policy: SONAME layout under `/lib`, `-z now`, stripped
   RUNPATH, and the `/lib` version re-pin that follows — rows 3, 14

Only two of the seven are the cheap part the old note assumed was the whole
problem. Three (GNU hash + versioning, TLS with a `tpidr_el0` resolver, IFUNC)
are each larger than anything M2 shipped. Row 2 is not in the list because it
is not a scale problem; rows 19 and 20 are as noted above.

## Explicit non-goal

Running stock Linux binaries. Even with a perfect ELF dynamic loader, Linux-ABI
binaries fault on the first syscall: EL0 offers custom `svc #imm` numbers, not
Linux `svc #0`. Closing that needs a syscall emulation/translation layer — a
separate proposal (`house-q0g.13`), not part of M4. M4 deliberately stopped at
"our ABI, shared".

That target holds for a `house-libc`-linked image and **cannot** hold for the
stock bindist closure: C7 measured that glibc's `libc.so.6` is not loadable by
this loader regardless of loader work, because its own `R_AARCH64_ABS64`
targets `_rtld_global`, which asserts a glibc dynamic loader's internal state.

## What is unstarted

Whole-`PT_LOAD` mapping is the recorded accepted M3 cost. The demand pager,
version *selection*, weak symbols as *reference* semantics, TLS, copy
relocations, IFUNC, lazy binding and `dlopen` are each unstarted — the M4
success box lists them as "remain open", each with "unstarted" in the Later
section. `house-q0g.10` exists to give each a scope or an explicit
deferral.

## Notes worth keeping

- `maxNeeded` is at the cap with no headroom, and a threaded build needs
  `libHSrts_thr` instead of `libHSrts`, which adds both a `PT_TLS` segment and
  2 `R_AARCH64_TLSDESC`. The cap retune and the TLS slice are coupled.
- `maxPhnum` counts over *all* program headers while only 2 are `PT_LOAD`.
  Not GHC-specific: any gcc-linked binary trips it.
- The measured closures are never staged. No `initramfs-staging` file, no
  manifest, no `/lib` pin, and no initramfs file count may move as a
  consequence of loader work.