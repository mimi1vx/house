{-# LANGUAGE GHC2024 #-}

{-|
Module      : Kernel.Userspace.Syscall
Description : SVC -> IPC shims docs.
Stability   : experimental

Syscalls 0x10..0x14 delegate to Kernel.IPC.Endpoint bounds via SVC
dispatch in Rust (`ipc.rs` validates op, word count ≤ 8, user-VA window,
grant alignment/perm with precise errno; the rendezvous queue itself stays
EL1 Haskell and validated calls return ENOSYS until a trap-safe delegation
ring lands). Haskell IPC remains QSem+MVar EL1; EL0 svc path uses
non-blocking try semantics at the trap boundary.
For slice, syscalls are handled in Rust (uart/exit) with IPC args validated.
This module documents the contract and re-exports minimal helpers.
-}
module Kernel.Userspace.Syscall
  ( syscallWrite,
    syscallExit,
    syscallBrk,
    syscallIpcSend,
    syscallIpcRecv,
    syscallIpcCall,
    syscallIpcReply,
    syscallIpcGrantMap,
  )
where

-- | Syscall numbers (svc #imm)
syscallWrite, syscallExit, syscallBrk :: Int
syscallWrite = 0x01
syscallExit = 0x02
syscallBrk = 0x03

-- | IPC ops (svc #imm), validated by `ipc.rs` before any queue touch.
syscallIpcSend, syscallIpcRecv, syscallIpcCall, syscallIpcReply, syscallIpcGrantMap :: Int
syscallIpcSend = 0x10
syscallIpcRecv = 0x11
syscallIpcCall = 0x12
syscallIpcReply = 0x13
syscallIpcGrantMap = 0x14

-- | brk contract: EL0 svc 0x03 traps to C dispatch, which owns trap-time
-- behavior. Haskell 'procBrkGrow' extends the caller's page map with zero
-- pages inside 0x01000000-0xFFFFFFFF; over-window yields OutOfWindow.
-- Stack contract (runElf): sp is 16-byte aligned; [sp]=argc,
-- [sp+8]=argv[argc+1] NULL-terminated, then envp[envc+1] NULL-terminated,
-- then NUL-terminated strings. Bounds: 64 entries and 1024 bytes per string.
-- Register contract (house_enter_el0/svc_exit_trampoline): the kernel
-- preserves x19-x28 across the EL0 session; guests must not rely on any
-- other register surviving svc roundtrips (x0 carries the return value).
