{-# LANGUAGE GHC2024 #-}

{-|
Module      : Kernel.Userspace.Syscall
Description : SVC -> IPC shims docs.
Stability   : experimental

Syscalls 0x10..0x14 delegate to Kernel.IPC.Endpoint via SVC dispatch in C.
Haskell IPC remains QSem+MVar EL1; EL0 svc path would use trySend queue.
For slice, syscalls are handled in C (uart/exit) and IPC stays ENOSYS until wired.
This module documents the contract and re-exports minimal helpers.
-}
module Kernel.Userspace.Syscall
  ( syscallWrite,
    syscallExit,
    syscallBrk,
  )
where

-- | Syscall numbers (svc #imm)
syscallWrite, syscallExit, syscallBrk :: Int
syscallWrite = 0x01
syscallExit = 0x02
syscallBrk = 0x03
