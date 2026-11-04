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
| 2 | `maxPhnum` 8 over **all** headers | phnum 10–13, but only 2 are `PT_LOAD`; a 70,440-byte C `hello` from the image's default gcc fails identically | cap-raise | landed — the phnum/segment split: `maxPhnum` 16 over every header, plus a separate `maxSegments` 8 for size-bearing segments (`Loader.hs:86-94`) |
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
| 20 | whole-`PT_LOAD` mapping, no demand pager | 25.5 MiB resident per mapping process | feature | landed — `house-q0g.11` (fault-driven serve, `house-q0g.12` numbers below) |

Row 0 is decisive because it is neither a bound nor a missing feature: a Linux
`svc #0` arrives as `svc_imm = 0`, which the house table defines as
`syscallYield`, with `x8` never read. Every other row could be cleared and the
first C-library call would still be mis-dispatched.

Named sites for row 0: `rust/crates/house-boot/src/c_start.rs`
(`ec == 0x15` arm, `svc_imm` extraction),
`kernel/Kernel/Userspace/Syscall.hs`, `rust/crates/house-hal-aarch64/src/svc.rs`.

Proposal: `docs/design/linux-abi-syscalls.md` (`house-q0g.13`) — x8-read
disambiguation, stage-1 delegate list, forbidden placements, and sequencing
against the provenance branch. Row 0 stays open until that layer exists.

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
are each larger than anything M2 shipped. Row 2 was never in the list because
it is not a scale problem — a one-line format fix any gcc-linked binary needs —
and it has since landed; rows 19 and 20 are as noted above.

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

## Deferred backlog: copy relocations, lazy binding, `dlopen`, TLS, IFUNC, version selection, GNU hash (`house-q0g.10`, `house-q0g.6`, `house-q0g.7`, `house-q0g.8`, `house-q0g.5`; 2026-11-04)

All seven are deliberate non-goals, not scoped slices. Line numbers below are
as verified 2026-11-04 (the table's 2026-09-27 numbers have drifted).

**Copy relocations: non-goal.** `R_AARCH64_COPY` (1024) has no relocation
constructor: it falls into the `otherwise` arm (`Loader.hs:1243`,
`UnsupportedReloc`; only 257/1025/1026/1027 are admitted, `Loader.hs:1221-1240`),
and the `COMMON` definition it would copy from is refused by
`buildExportScope`'s reserved-section arm (`Linker.hs:407-408`;
`SHN_COMMON` is `0xFFF2`, covered by `Main.hs:2089`). A static linker emits
`COPY` only for a non-PIC `ET_EXEC` main referencing DSO data, and
`validateMain` admits `ET_DYN` mains only (`Linker.hs:196`), so no staged
object can carry one: the built branch-B DSOs were measured with zero
`SHN_COMMON` symbols and only `JUMP_SLOT` relocs
(`libc-house.so.0` ×2, `libmid-house.so.0` ×1). Under provenance (ii) the
feature is empty — every object is rebuilt PIC against `house-libc`.
Revisit only if a non-PIC main were ever staged, which contradicts M4's
"our ABI, shared".

**Lazy binding: non-goal — the refusal is the design.** Bind-now is enforced
twice: per relocation at parse (`Loader.hs:1229`; `ABS64` exempt because it
is eager by construction) and per object at plan (`Linker.hs:218`, which the
comment at `Linker.hs:211-217` notes subsumes the parser rule);
`dynamicBindNow` accepts `DT_BIND_NOW` / `DF_BIND_NOW` / `DF_1_NOW`
(`Loader.hs:1048-1051`), and RELRO presence, non-emptiness and containment
are gated separately (`Linker.hs:227-232`, `Linker.hs:298-308`). A lazy PLT
would need a runtime resolver plus a writable GOT after load, contradicting
RELRO sealing; there is no fault-time patch path — `planPatches`
(`Linker.hs:422`) resolves every `JUMP_SLOT` at exec. This is M1's "no lazy
PLT in v1 — full RELRO, bind-now", unchanged, and the staged objects are
already linked `-z now` (`scripts/mk-house-image.sh:202`), so laziness buys
nothing even before the sealing argument. No revisit short of dropping
RELRO.

**`dlopen`: non-goal for v1 — there is no host primitive.** `linkDynamic`
runs only on the exec path (`Process.hs`: `prepareImage` →
`prepareDynamicImage` → `linkDynamic`); no `svc` number re-enters it, and
there is no post-exec scope merge or out-of-exec init-array path, so a
runtime load has nothing to attach to. `house-libc` stubs `dlopen`/`dlsym`
to `NULL` and `dlclose`/`dlerror` to failure (`"no dl"`,
`rust/crates/house-libc/src/compat.rs:50-64`), so a ported caller fails
closed at load, never halfway at runtime. Sequencing against provenance
(ii): `dlopen` *of glibc objects* is moot twice over — row 0 plus C7's
`_rtld_global` finding — while a runtime load primitive for `house-libc`
objects (plugin-style) is the only form that could ever matter, and it
needs its own slice (new `svc`, live-pdir link re-entry, scope merge, init
execution, dependency pinning), none of it started and none of it M4.
Revisit condition: a named consumer plus that slice; until then the stubs
stay failing-closed.

**TLS: non-goal — nothing in-branch carries it, and the refusal runs
first.** The staged main links `ghc -O0 -dynamic -fPIE -pie` with no
`-threaded` (`scripts/mk-house-image.sh:294`), so the manifest's main needs
`libHSrts-1.0.3`, never `libHSrts_thr`; `house-libc` declares no
thread-local storage (no `thread_local!` anywhere under
`rust/crates/house-libc/src/` — `threads/tls.rs` is resolver text only,
`__tlsdesc_static` / `__aarch64_tlsdesc_resolve`, emitting no TLS data).
Measured 2026-11-04 across every house-built object (12 objects: `build-b`,
`staging`, `root`, `house-image/house-libs`, `proto` `libc-house.so.0`
flavours): zero `PT_TLS` segments, zero TLS-range relocations, zero `VER*`
tags — reloc types are `JUMP_SLOT`, `ABS64`, `RELATIVE` only. The three
refusal sites still fail closed: `PT_TLS` (`Loader.hs:740-741`), `DT_TLS_*`
(`Loader.hs:938`, with TLS-adjacent tags pinned in `rejectedDynTags`,
`Main.hs:2932-2939`), and TLS-range relocs (`Loader.hs:1241`). The `PT_TLS`
check runs before any field validation, so malformed `p_memsz`/`p_filesz`
mismatch, out-of-window `p_vaddr`, or wrong-alignment variants resolve
`TlsUnsupported` by construction, never past it. Vectors `elfExecTls` /
`elfDynTls` / `elfTls` (`Main.hs:1330-1331,1569,3171-3172`), mirrored by
`repack.py:259,376,522` and gated host-side by
`scripts/dynamic-elf-check.sh:162,178`. Revisit only if a `-threaded` RTS
or thread-local `house-libc` storage were ever staged — which is the
feature, not a gate.

**IFUNC: non-goal — the only IRELATIVE in the measured world is glibc's.**
The 2 `R_AARCH64_IRELATIVE` relocs live in stock `libc.so.6` (gate-table row
12 reference), which is unloadable twice over — row 0 (Linux `svc #0`
mis-dispatch) plus C7's `_rtld_global` finding — so no staged load can
reach them. The house-built closure measured above carries zero `IRELATIVE`;
the refusal (`Loader.hs:1242`, mirrored `repack.py:256-257`) plus the
`elfM2Irelative` vector (`Main.hs:1383,3121-3122`) stays as the fail-closed
record. A resolver-via-trampoline would need a new exec-path re-entry (the
C5 `Trampoline.hs` precedent supervises EL0 execution during a load, but no
`svc` re-enters `linkDynamic` — the same missing host primitive as
`dlopen`), and building it buys nothing while `house-libc` exports no
IFUNC. Revisit only with a named `house-libc` IFUNC consumer plus that
re-entry slice.

**Version selection: non-goal — versions are gone under provenance (ii).**
C8 honours and bounds-checks `DT_VERSYM` and records the index but
deliberately does not select on it; `DT_VERNEED` / `DT_VERDEF` stay
tolerated skips (`Loader.skipDynTag`, reason `ver`, `Loader.hs:426`;
`Loader.skippableDynTags`, `Loader.hs:434`). The gap C8 named — a single
provider carrying a different version than the reference asks for — is empty
in-branch: the B2 manifest records `verneed=0,versym=0` for the rebuilt prim
and `libc-house.so.0` (`scripts/mk-house-image.sh:475-476`), and the
on-disk measurement above finds zero `VERSYM` / `VERDEF` / `VERNEED` tags in
every house-built object, so every symbol reads `VER_NDX_GLOBAL` (vectors
`Main.hs:1366-1367`). With no versioned symbol staged, no mismatch case
exists for the duplicate-export refusal (`Linker.hs:411`) to miss —
ambiguity and mismatch are both `Left` by construction, under the same
single-provider invariant as `house-q0g.9`. Revisit only if a versioned DSO
were ever staged, which contradicts the `--hash-style=sysv` unversioned
rebuild recipe.

**GNU hash: non-goal — provenance (ii) removed it from every staged object.**
The v1 recipe pins `--hash-style=sysv` at every link step
(`scripts/mk-house-image.sh:55,202,259,326`), and the B2 manifest records
`hash=sysv,verneed=0,versym=0` for the rebuilt prim and `libc-house.so.0`
(`scripts/house-image.manifest`). Measured 2026-11-04 across every
house-built object on disk (13 objects with dynamic sections: the
`build-b`, `staging`, `root`, `house-image/house-libs` and `proto`
`libc-house.so.0` flavours, the `build-b`/`proto` hello-dyn mains, and the
`house-image`/`house-probe` mains — `PT_DYNAMIC` tags parsed directly, no
readelf on this host): every one carries SysV `DT_HASH` (tag 4) and zero
`DT_GNU_HASH` (`0x6FFFFEF5`). The only `hash=gnu` entries left in the
manifest are stock objects (base, internal, rts, ffi, gmp, libm, libc,
ld-linux) — unloadable twice over (row 0 plus C7's `_rtld_global` finding),
so no staged load can reach a GNU-hash table. The two refusal sites still
fail closed: the parser (`Loader.hs:927`, tag constant `Loader.hs:222`,
SysV admitted `Loader.hs:909`) and the plan gate
(`Linker.validateSymbolMetadata`, `Linker.hs:235-242`, `requires SysV
symbols`). The fail-closed record is fourfold: vector `elfM2GnuHash`
(`Main.hs:1361,3060-3061,3628`) swaps the SysV entry for a GNU-hash tag and
asserts `Left (BadDyn "GNU hash unsupported")`; `0x6FFFFEF5` is pinned in
`rejectedDynTags` (`Main.hs:2936-2938`, enforced `Main.hs:1413,1425`);
mirrored by `repack.py:86,353-354`; and gated host-side both ways by
`scripts/dynamic-elf-check.sh:175,178` (built artifacts must carry SysV
`HASH` and lack `GNU_HASH`) and `:367` (the stock closure must still stop
at `BadDyn: GNU hash unsupported`). Revisit only if a GNU-hash DSO were
ever staged, which contradicts the `--hash-style=sysv` rebuild recipe.

## What is unstarted

Whole-`PT_LOAD` mapping was the recorded accepted M3 cost (since retired by
the `house-q0g.11` demand pager). Of the M4 success box's "remain open"
list, copy relocations, lazy binding and `dlopen` are disposed above
(`house-q0g.10` deferral paragraphs), as are TLS, IFUNC, version
*selection* and GNU hash (the `house-q0g.6`, `house-q0g.7`, `house-q0g.8`
and `house-q0g.5` paragraphs in the same section); weak symbols as
*reference* semantics landed (`house-q0g.9`). `house-q0g.10`
exists to give each a scope or an explicit deferral.

## Notes worth keeping

- `maxNeeded` is at the cap with no headroom, and a threaded build needs
  `libHSrts_thr` instead of `libHSrts`, which adds both a `PT_TLS` segment and
  2 `R_AARCH64_TLSDESC`. The cap retune and the TLS slice are coupled.
- `maxPhnum` counts over *all* program headers while only 2 are `PT_LOAD`.
  Not GHC-specific: any gcc-linked binary trips it.
- The measured closures are never staged. No `initramfs-staging` file, no
  manifest, no `/lib` pin, and no initramfs file count may move as a
  consequence of loader work.

## house-q0g.1 retune decision (2026-10-06)

One reviewed bound decision for branch B (provenance (ii), GHC libraries
rebuilt against `house-libc`). Sizing target is the branch-B `house-libc`
closure, not the stock bindist closure: the 2026-09-27 violation numbers
(165,975 relocs, 59,724 symbols, 4,972 pages, 18.5 MB PT_LOAD) are reference
upper bounds, not sizing targets — stock needs the row-0 syscall layer
(`house-q0g.13`) regardless, so admitting its scale buys nothing. Re-measured
2026-10-06 (`br` comment on `house-q0g.1`): house fixtures max 9,640 B file /
3,328 B PT_LOAD / 3 pages / 6 relas / 5 syms / 2 needed / 2 deps; house-image
main 71,936 B / 4,480 B / 3 pages / 37 relas / 24 syms / 8 needed; stock
`libm.so.6` 591,960 B / 579,440 B / 143 pages / 21 relas / 1,280 syms.
`loadElf` stays `ByteString` (`Loader.hs:602`); no representation change even
at 16 MiB.

- `maxElfBytes` 1 MiB → 16 MiB (`1 shiftL 20` → `1 shiftL 24`) admits the
  13 MB / 16 MB mains (row 1) with `ByteString`, still refuses the 20 MB
  `libHSghc-internal` at file size — `house-q0g.1`.
- `maxSegMemSz` 256 KiB → 1 MiB (`256 * 1024` → `1024 * 1024`) admits `libm`
  579,440 B with 1.8x headroom, refuses `libc` 1.6 MB / `base` 2.5 MB /
  internal 18.5 MB — `house-q0g.1`.
- Loader `maxTotalPages` 64 → 256 admits `libm` 143 pages with 1.8x headroom,
  refuses `base` 660 / internal 4,973 / `libc` 417 — `house-q0g.1`.
- `maxRelaCount` 4096 → 32768 admits `base` 13,265 with 2.4x headroom for B1,
  refuses internal 165,975 — `house-q0g.1`.
- `maxDynSymbols` 4096 → 16384 admits `base` 9,720 with 1.7x headroom, refuses
  internal 59,724 — `house-q0g.1`.
- `maxNeeded` 8 → 16: main needs exactly 8 at the cap, 2x headroom; coupled
  to TLS (threaded RTS adds `PT_TLS` + 2 `TLSDESC`, still refused by
  `house-q0g.6`) — `house-q0g.1`.
- `maxDependencies` 8 → 16: closure main + 8 = 9 at the cap, symmetric with
  `maxNeeded`; 2x would be 32 but that admits DoS-scale graphs — `house-q0g.1`.
- Linker `maxObjectPages` 64 → 256, same as Loader pages, admits `libm`
  143 — `house-q0g.1`.
- Linker `maxTotalPages` 256 → 1024 admits main + `libm` (146) and single
  `base` (660) but refuses the full stock 6,526-page closure — `house-q0g.1`.

## house-q0g.4 cap revisit (2026-11-04)

One reviewed bound decision for the rebuilt GHC objects (`house-q0g.4` S4).
Sizing target is the rebuilt `libHSghc-internal` scale, measured live from
the S3 fallback link (file 29,983,288 B; max `PT_LOAD` 9.64 MiB; load pages
4,900; relocations 164,541; dynamic symbols 59,892; 8 phdrs) with the stock
manifest line 5 as the reference upper bound (20.4 MB file; 18.5 MB PT_LOAD;
4,973 pages; 165,975 relocs; 59,724 syms). The stock shape stays the larger
number everywhere except file size (the quick `-O0` rebuild is fatter than
bindist), so sizing to the larger of the two admits both.

- `maxElfBytes` 16 MiB → 32 MiB (`1 shiftL 24` → `1 shiftL 25`) admits the
  rebuilt ~30 MB file at 1.1x and the stock 20.4 MB at 1.6x. File-size
  headroom stays thin by the q0g.1 precedent (the 16 MB mains sat at the old
  cap): the file is a deterministic build output, and the transient cost is
  one retained `ByteString` per loaded object, freed after serve.
- `maxSegMemSz` 1 MiB → 32 MiB admits the stock 18.5 MB `PT_LOAD` at 1.8x
  (the q0g.1 headroom shape) and the rebuilt 9.6 MB at 3.4x.
- Loader `maxTotalPages` 256 → 8192 admits stock 4,973 pages at 1.65x.
- `maxRelaCount` 32768 → 262144 admits 165,975 at 1.6x.
- `maxDynSymbols` 16384 → 131072 admits 59,892 at 2.2x.
- Linker `maxObjectPages` 256 → 8192, same as Loader pages, admits internal.
- Linker `maxTotalPages` 1024 → 8192 admits the branch-B demo closure
  (~5,560 pages: internal 4,900 + base 649 + prim + libc-house + probe) at
  1.5x, including headroom for future house RTS/GMP objects; the
  stock-scale full closure stays refused by the dependency gate, not the
  page budget.

Hostile vectors, unchanged in kind: parse-time transient allocation is
bounded per object (the retained file bytes are also the demand-pager serve
source since `house-q0g.11`, so the file bound caps retained memory, not
just parse work); mapping work is PTE markers rather than RAM, so the page
bounds cap marker state; relocation, symbol, hash-bucket and string-table
processing stay linear with per-entry validation (`maxNeeded`, name-length
caps untouched). The string table is always inside the retained file bytes,
so its bound can never exceed the file bound; buckets match symbol count
1:1 by linker construction (`lld` emits `nbucket == nsyms`, verified live),
so the bucket bound rides the symbol bound. Dependency fan-out is untouched
(`maxNeeded` 16, `maxDependencies` 16): the DoS-scale-graph refusal from
q0g.1 stands.

Two bounds the triage could not see (the manifest has no string-table or
bucket columns, and S3 stopped at the file cap before reaching them) bind
live and join this one decision rather than a ninth and tenth edit:
`maxDynStrSz` 64 KiB → 4 MiB admits the rebuilt 3.93 MB table at 1.1x
(deterministic build output, same thin-file rationale as `maxElfBytes`),
and `maxDynHashBuckets` 4096 → 131072 admits 59,892 buckets at 2.2x,
matching `maxDynSymbols`. `maxSymbolNameLen` 256 still admits the longest
rebuilt name (239 chars) and stays put.

## house-q0g.11 demand pager (2026-11-04)

`PT_LOAD` pages are committed at load as PTE markers (valid-clear L3 desc,
magic `0xDE` in bits[63:56], bit1 = final writable) instead of mapped
(`H.VirtualMemory.setDemandPage`, the first deliberate touch of
`H.VirtualMemory`/`H.Pages` by any dynamic slice). First touch faults: EL1
(`house_handle_user_fault` returns 2) parks FAULT and the supervisor
materializes exactly that page from the retained object bytes with the
marker perms, then resumes the faulting insn. Permission faults still kill
(non-COW RO store parks KILL, unchanged); COW still breaks in Haskell
(a present page is never claimed as served, so `breakCow` is not starved).
Budgets draw from the shared 10%-of-buddy cap at serve time; setPage paths
keep their current-pdir invalidate (ASID/TLBI discipline unchanged, no new
shootdown needed for fresh pages). Grant-list and syscall-mask semantics
are untouched (both keyed by pdir, inherited/cleared as before).

Loader-touched pages (relocation targets, init/fini arrays) are served
eagerly at load so the loader never faults; supervisor user-copies serve
ranges first, except NUL-terminated scans, which serve page-by-page to the
NUL so a string ending near the top of its page never drags the next page
in. Markers ride fork (replanted in the child with the parent's current
perms; materialized pages share COW as before) and die on exec
(`freeUserPages` clears them) and reap (tables freed wholesale). Load-time
M3.1 sharing is preserved on the eager subset, so `loaderrefs` still
witnesses sharing synchronously; serve-time cross-process sharing of
faulted pages is a follow-up (each process still materializes its own
touched set privately).

## house-q0g.12 RAM-per-process, N=2 (2026-11-04, re-measured)

Geometry: `loaderrefs` (two concurrent `/bin/hello-dyn`, waited to exit
without reaping, then counted via a page-table walk), hvf and tcg, 512M,
smp2. Counts are mapped user pages (stack included) per live process.

- Eager baseline (pre-pager, from the initramfs objects): 10 `PT_LOAD`
  pages per closure (main 3 + `libc-house.so.0` 4 + `libmid-house.so.0` 3)
  + 1 stack = **11 pages = 44 KiB resident per mapping process**.
- Pager: **5 mapped pages per process (20 KiB), both processes, both
  accelerators** (`loaderrefs ok pages=Just 5/Just 5` on hvf and tcg).
- Saving: **6 pages (24 KiB, 55%) per process** for this closure.
- Cost kept per process, freed on reap: the retained object bytes, bound
  Σ filesz = 4,739 + 8,804 + 4,664 = **18,207 B (~18 KiB)** in the Haskell
  heap (not buddy-resident). No cross-process byte sharing yet — the bound
  scales with file size, so a stock-scale closure would want the shared
  page-cache follow-up; the house fixtures stay single-digit KiB.
- No leak: buddy `105944/105952` before and after consecutive runs
  (±1 transient, non-accumulating across three runs); `cowLiveCount` and
  ASID slots return to baseline (asserted by the verb itself).

The 25.5 MiB row-20 figure stays as the stock-bindist reference (that
closure is not loadable — row 0): the runnable `house-libc` closure above
is what the pager was measured against.

## house-q0g.3 B2 outcome (2026-11-04)

`libHSghc-prim` is rebuilt against `house-libc` (`scripts/mk-house-image.sh`
builds a `house-libs/` overlay: the el0tiny shared flavour plus the prim
archive re-linked `ld.lld -shared --hash-style=sysv -z now`, NEEDED on
`libc-house.so.0` and the B3-owned internal object; the main link takes
`-Lhouse-libs` first with `--trace` proving the overlay won). The manifest
gains the rebuilt prim line and the pulled-in `libc-house.so.0` line: both
read `hash=sysv,bindnow=1,relro=1,tls=0,verneed=0,versym=0`, removing rows
5, 6, 11, 12 per object. The probe graph (`house-probe` + rebuilt prim +
`house-libc`) links past every parser and cap gate to `DependencyMissing:
libHSghc-internal-...` — the first typed error past the stock closure's
GNU-hash refusal, and B3's work item.

`libHSbase` is not rebuilt: the bindist archive is vanilla non-PIC objects
(`ld.lld` refuses them with `R_AARCH64_ADR_PREL_PG_HI21`, and TEXTREL output
is loader-refused), so its rebuild needs dynamic objects from a source-built
GHC. Its 19 house-missing C imports are named for that follow-up: 16 libm
transcendentals plus `clock_gettime`/`clock_getres`/`getrusage`/`times`, none
of which has a house svc number backing it. `libHSghc-internal` shows the
same vanilla shape (`house-q0g.4` inherits the blocker).

## house-q0g.4 triage outcome (2026-11-04)

Verdict: re-scope. The bindist archive cannot yield a loader-acceptable
shared object; the rebuild needs dynamic objects from a source-built GHC.
The bead stays open on that plan; the manifest line 5 stays as the stock
reference upper bound and the house-probe `DependencyMissing:
libHSghc-internal` remains the typed frontier.

Evidence, measured in `house-port:latest` against the bindist 9.14.1 closure
(`aarch64-linux-ghc-9.14.1-fbc8`):

- B2's success explained: the prim archive is 1 member whose 7 relocs are
  all `R_AARCH64_ABS64` (link-time-resolvable data words), so the B2
  `ld.lld -shared` recipe links clean.
- The internal archive is 285 members (220 unique basenames). Reloc census
  over the extracted objects: 91,722 `ABS64`, 83,972 `ADR_PREL_PG_HI21`,
  83,968 `ADD_ABS_LO12_NC`, 52,251 `JUMP26`, 45,034 `ADR_GOT_PAGE` /
  `LD64_GOT_LO12_NC` pairs, 25,295 `PREL32`, 10,434 `PREL64`, 2,050
  `CALL26` — the `adrp`/`add` pairs are the vanilla non-PIC shape.
- The B2 recipe reproduced and refused: `ld.lld -shared --hash-style=sysv
  -z now -z relro --whole-archive libHSghc-internal-…​.a` fails with
  `error: relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against
  symbol '…TimerManager_con_info'; recompile with -fPIC` (first of
  thousands; `ADD_ABS_LO12_NC` the same).
- `-z notext` is not an escape: TEXTREL/`DF_TEXTREL` output is
  loader-refused (`Loader.hs:916,1038`, `build-probe/repack.py:344-356`,
  `scripts/dynamic-elf-check.sh:178`, `kernel/test/Main.hs:1344-1345`).
- Rejected without trial: re-linking from the stock `.so` (an input `.so`
  contributes no code, so the output would be an empty NEEDED wrapper and
  the closure stays GNU-hash) and patchelf-class hash surgery (no tool
  rebuilds a SysV `.hash` from `.gnu.hash`; version stripping breaks
  binding).
- Import gap for the follow-up: the stock internal `.so` carries 428
  undefined dynamic symbols, 102 of them versioned `@GLIBC_2.17` C imports.
  About 11 are already house-libc exports (assert, errno, abort, fprintf,
  memcpy/memmove/memcmp/memset, puts, strlen, nl_langinfo); the ~91 missing
  are ~30 libm transcendentals (`acos`…`tanh`, `exp`, `log`, `pow`,
  `ldexp`), POSIX process/file/event (`fork`, `pipe`, `dup2`, `waitpid`,
  `epoll_create`/`ctl`/`wait`, `eventfd`, `sigaddset`/`emptyset`/`procmask`,
  `poll`, `flock`, `fcntl[64]`), terminal (`tcgetattr`/`setattr`, `isatty`),
  `sysconf`/`utime`, `iconv_open`/`close`/`iconv`, allocation
  (`malloc`/`calloc`/`realloc`/`free`), plus the data objects
  `stderr`/`environ`. Base's gap was 19 symbols; internal is ~5x the libc
  surface.
- Cap coupling: a rebuilt internal stays at stock scale (165,975 relocs /
  59,724 syms / 4,973 pages), so the `house-q0g.1` retune — which
  deliberately sized away from the 20 MB object — must be revisited for
  this object (rows 1, 7, 8, 9, 10, 17, 18).

Re-scoped plan:

1. Source-build GHC 9.14.1 (Hadrian, aarch64 Linux, stock toolchain) to
   obtain `-fPIC` dynamic objects for `ghc-internal` (and `base`, already
   queued) — one-time cost, typically 30–90 min container time.
2. Recompile the packages' C bits (`iconv`, `SetEnv`, `gmp_wrappers`, …)
   `-fPIC` against house-libc headers.
3. Apply the B2 `ld.lld` recipe (`--hash-style=sysv -z now`, NEEDED on
   `libc-house.so.0`) to the PIC objects.
4. Close the ~91-symbol house-libc gap (libm + POSIX + `stderr`/`environ`
   data) against the syscall layer (row 0, `house-q0g.13`) before the link
   can go `--no-undefined`.
5. Revisit the `house-q0g.1` caps for internal scale.

## house-q0g.9 weak-reference decision (2026-11-04)

A weak *definition* (`STB_WEAK` + `STV_PROTECTED`) names one provider for one name; a weak *reference* (undefined `STB_WEAK`) asks the scope to choose between providers. Those are different features: the first is admitted since C8 because the duplicate-export refusal keeps exactly one provider per name, while the second stays unimplemented — an ambiguous weak reference resolves `Left`, never a priority pick, because there is no measured basis for a choice (C7 decoded 0 weak symbols in the 9,595-relocation population) and fail-closed keeps the single-provider invariant checkable in a test. `SHN_COMMON` (copy relocations, unstarted per `house-q0g.10`) and duplicate exports stay refused for the same reason: no shadowing, no fallback, one name means one provider.
