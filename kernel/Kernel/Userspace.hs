{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace
Description : EL0 ELF loader facade.
Stability   : experimental

Re-exports Loader, Types, Process, Syscall with explicit list.
Strictness: all H actions bracket resources; no lazy I/O.
-}
module Kernel.Userspace (
  -- * Loader
  Kernel.Userspace.Loader.LoadError (..),
  Kernel.Userspace.Loader.Segment (..),
  Kernel.Userspace.Loader.Elf (..),
  Kernel.Userspace.Loader.loadElf,
  Kernel.Userspace.Loader.loadErrorToString,

  -- * Types
  Kernel.Userspace.Types.Pid (..),
  Kernel.Userspace.Types.Process (..),

  -- * Process
  Kernel.Userspace.Process.runElf,
  Kernel.Userspace.Process.forkProc,
  Kernel.Userspace.Process.procInfo,
  Kernel.Userspace.Process.waitPid,
  Kernel.Userspace.Process.killPid,
  Kernel.Userspace.Process.procBrkGrow,

  -- * Fd table (Track O FS slice, EL1; EL0 trap wiring pending ring)
  Kernel.Userspace.Fd.Fd (..),
  Kernel.Userspace.Fd.FdError (..),
  Kernel.Userspace.Fd.fdErrorToString,
  Kernel.Userspace.Fd.fdOpen,
  Kernel.Userspace.Fd.fdRead,
  Kernel.Userspace.Fd.fdWrite,
  Kernel.Userspace.Fd.fdClose,
  Kernel.Userspace.Fd.fdSeek,

  -- * Syscall numbers
  Kernel.Userspace.Syscall.syscallWrite,
  Kernel.Userspace.Syscall.syscallExit,
  Kernel.Userspace.Syscall.syscallBrk,
  Kernel.Userspace.Syscall.syscallOpen,
  Kernel.Userspace.Syscall.syscallRead,
  Kernel.Userspace.Syscall.syscallWriteFd,
  Kernel.Userspace.Syscall.syscallClose,
  Kernel.Userspace.Syscall.syscallFork,
  Kernel.Userspace.Syscall.syscallWait,
  Kernel.Userspace.Syscall.syscallSeek,
  Kernel.Userspace.Syscall.syscallIpcSend,
  Kernel.Userspace.Syscall.syscallIpcRecv,
  Kernel.Userspace.Syscall.syscallIpcCall,
  Kernel.Userspace.Syscall.syscallIpcReply,
  Kernel.Userspace.Syscall.syscallIpcGrantMap,
)
where

import Kernel.Userspace.Fd
import Kernel.Userspace.Loader
import Kernel.Userspace.Process
import Kernel.Userspace.Syscall
import Kernel.Userspace.Types
