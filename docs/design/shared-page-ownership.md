# Shared page ownership

`cowRefs` (`kernel/Kernel/Userspace/Process.hs`) is the sole registry for
shared user pages. `shareBump` / `unshareBump` / `dropShare` are the only
operations, each a single `atomicModifyIORef'` step.

Every release on the Haskell side routes through `releaseBacking` ->
`dropShare`:

- `freeUserPages` walks the user range, clears each mapping, and calls
  `releaseBacking` for the backing host page.
- `freePDir` walks the whole root the same way.
- `shareAddrSpace` bumps the count for each shared mapping; rollback uses
  `unshareBump` so the restoring root keeps its page.
- `breakCow` handles the copy-on-write fault: sole-mapped pages remap RW in
  place and delete the entry; shared pages copy to a fresh host page and
  decrement the old entry. The live count is observable via `cowLiveCount`,
  which the `forktest` leak check asserts returns to zero.

One exception exists and is documented here rather than assumed away:
`house_vm_munmap` (`rust/crates/house-hal-aarch64/src/mm/vm.rs`) frees pages
without consulting `cowRefs`. It is reachable only from EL1 diagnostics
(`Kernel/Shell/Vm.hs`); no EL0 SVC maps to it. It walks `current_pdir()` under
`VM_LOCK`, while the demand pager installs pages against `RECORDED_PDIR` under
`PDIR_WALK_LOCK` (`rust/crates/house-hal-aarch64/src/userspace.rs`). Those are
distinct locks over the same tables.

Precondition that makes this safe today: no EL0 process can reach `munmap`,
so the diagnostic path never races a live shared mapping. Any future caller
that exposes unmap to EL0 must consult `cowRefs` first or replace this note
with a joint ownership protocol.

Related: `docs/design/tlb-shootdown-protocol.md` for how unmaps become
visible to peers; `rust/c-abi.md` `mm/vm.rs` section for the diagnostic
surface.
