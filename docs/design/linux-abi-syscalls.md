# Linux-ABI syscall emulation (M4 row 0 proposal)

Proposal for `house-q0g.13`. Docs only — no code, no loader/linker change.
Status: proposed; the decision it informs belongs to `house-q0g`
(provenance (ii) vs gate-table route).

## The collision

Stock `libc.so.6` issues 411 `svc #0x0` with the syscall number in `x8`
(e.g. `mov x8, #0x5d` = 93 = `exit`). EL1 reads `svc_imm = esr & 0xFFFF`
(`rust/crates/house-boot/src/c_start.rs:365`, inside the `ec == 0x15` arm at
`:357`) and dispatches house numbers `0x00`–`0x14`
(`rust/crates/house-hal-aarch64/src/svc.rs:3-29`,
`kernel/Kernel/Userspace/Syscall.hs:58-63`). A Linux `svc #0` therefore
arrives as `svc_imm = 0`, which the house table defines as `syscallYield` —
`x8` is never read. Clearing every other M4 row still mis-dispatches the
first C-library call. This row is decisive for exactly that reason.

## Disambiguation rule (recommended)

When `svc_imm == 0`, read `x8` from the trap frame (the 112-word save
already holds `x0`–`x30`, so no frame change is needed):

- `x8` in the translated first-cut set below → translation path.
- otherwise → current house dispatch (`yield`). Back-compatible: existing
  house EL0 tools never set `x8`, and no translated number is zero.

Known edge, accepted: `x8 == 0` is Linux `io_setup`, which keeps house
`yield` under this rule. A stock binary calling `io_setup` parks as a yield
instead of failing closed — wrong, but silent only for binaries that get
past everything else, and none do yet. The escape hatch is migrating house
`yield` off imm 0; that is an ABI break for every existing EL0 tool and is
explicitly **not** proposed here. Revisit only if a translated binary is
ever observed issuing `io_setup`.

## Translation surface

The layer lives at the trap boundary only: the `ec == 0x15` arm in
`c_start.rs` (x8 read + route), a lock-free `x8 → house-op` map beside
`house_svc_dispatch` in `svc.rs` (validate-then-park shape, same errno
conventions), and completion in the existing Haskell `parkLoop` (resume `x0`
carries the result; negative errnos already match Linux convention).
Loader (`Loader.parseElf`), linker (`Linker.linkDynamic`), and every
dynamic-linking slice stay untouched — see "Forbidden placements".

Arg widening is mechanical: Linux passes `x0`–`x5`, house handlers read
`x0`–`x3` today; the frame holds all of them.

### Stage 1 — pure delegates (first cut)

| Linux arm64 | house op | note |
|---|---|---|
| `read` 63 | `READ 0x05` | fd slice, validate-then-park unchanged |
| `write` 64 | `WRITE 0x01` | inline; extend uart from fd 1 to fd 2 (stock stderr), else `EBADF` as today |
| `openat` 56 | `OPEN 0x04` | `AT_FDCWD` + absolute paths only; other dirfd/flags → `EINVAL` |
| `close` 57 | `CLOSE 0x07` | as-is |
| `lseek` 62 | `SEEK 0x0A` | as-is |
| `brk` 214 | `BRK 0x03` | as-is (always parks, Haskell decides) |
| `exit` 93 / `exit_group` 94 | `EXIT 0x02` | `exit_group` collapses to process exit; no thread-group exists to distinguish |
| `getpid` 172 / `uname` 160 | trivial backends | candidates, only if glibc init proves to need more than `ENOSYS` tolerance |

Threading/teardown calls glibc issues at startup (`set_tid_address`,
`set_robust_list`, `rseq`, `rt_sigaction`/`rt_sigprocmask`) get precise
`ENOSYS` (`-38`, the existing unknown-imm value) — glibc proceeds past
several of these on `ENOSYS` today, which is what makes a delegate-plus-
`ENOSYS` first cut viable rather than a full ABI.

### Stage 2 — new backends (explicitly not first cut)

`mmap` 222 / `munmap` 215 / `mprotect` 226 have no house op behind them.
They stay precise `ENOSYS` until a backend exists; `mmap(MAP_ANONYMOUS)`
couples to the demand pager (`house-q0g.11`), so stage 2 sequences after it.
`execve` maps to house `EXEC 0x0B` only for the house-image case; stock
`execve` of a Linux binary re-enters the same translation requirement and
is out of scope for both stages.

## Forbidden placements

Per the C1–C6 criteria, no emulation inside a dynamic-linking slice: not in
the loader gates, not in the linker, not in cap retune (`house-q0g.1`), hash
/ versioning / TLS / IFUNC slices, and not in staging/relink policy. The
translation is a trap-side layer over the finished house ABI; it must be
reviewable and revertible without touching any of the seven slices.

## Sequencing vs the provenance branch

Under provenance (ii) this row is irrelevant to a `house-libc`-linked image:
nothing in such an image issues a Linux `svc #0`, so the house table
dispatches every call correctly with no layer at all. This proposal is the
precondition for the **stock** target only. Sequence it against the
provenance decision (`house-q0g`), not before it: if branch B wins, this row
stays open-but-irrelevant; if the gate-table route wins, this layer is the
last gate after the seven slices land. Building it first would spend the
largest M4-adjacent work item on a target the project may never pick.

## What house-oz9.5 takes from this (proposal level)

`house-oz9.5` asks what a real Haskell EL0 binary needs past the
`Userspace.Asm` gap and is blocked on this proposal. At proposal level the
split is:

- From here: the disambiguation rule and the stage-1 list. The oz9.5
  decision (whether stock GHC output is ever an EL0 target) consumes both:
  "yes" requires this layer plus the seven slices; "no" (EDSL only) needs
  neither, because the EDSL emits house `svc #imm` directly and never a
  Linux `svc #0`.
- Orthogonal: the three missing `Instr` constructors (64-bit store,
  indirect call, divide). They gate EDSL expressiveness, not the ABI
  collision, and are unblocked by this proposal either way.

No code in either bead changes that split; oz9.5 stays a decision note.
