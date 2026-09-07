{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Syscall
Description : SVC -> IPC/fd/brk shims docs.
Stability   : experimental

 Syscalls 0x03..0x07/0x0A + 0x10..0x13 delegate through the park/resume
 ring: Rust ('svc.rs' 'house_brk_should_park' / 'house_fd_should_park',
 'ipc.rs' 'house_ipc_should_park') validates trap-side and parks; Haskell
 ('Kernel.Userspace.Process.parkLoop') completes the op and resumes with
 the result in x0. GRANT_MAP 0x14 and fork/wait 0x08/0x09 stay inline
 ENOSYS until their slices land.
 Haskell IPC remains QSem+MVar EL1; EL0 svc path uses
 non-blocking try semantics at the trap boundary.
 For slice, syscalls are handled in Rust (uart/exit) with IPC args validated.
+Errno mapping once the delegation ring lands: unknown/freed endpoint id ->
+`NoSuchEndpoint` (~ENOENT -2, also the `nsLookupChecked` miss path, logged to
+dmesg); capability mismatch -> `NotOwner` (~EPERM -1, log-only in this slice:
+allowed + dmesg via `checkCap`); full queue -> `QueueFull` (~EAGAIN);
+`callTimeout` expiry -> `WouldBlock`.
+EL0 return convention (resume x0): SEND/CALL 0 with reply words in the user
+buffer (truncated to the sender nwords); RECV the sender tag with received
+words in the buffer (truncated to the receiver nwords); REPLY 0. Negative
+x0 is the errno above plus -14 EFAULT (user copy fault) and -22 EINVAL
+(no pending RECV for REPLY). REPLY consumes the pid's pending RECV slot;
+a reaped pid's slot wakes its sender with NoSuchEndpoint.
 This module documents the contract and re-exports minimal helpers.
-}
module Kernel.Userspace.Syscall (
  syscallYield,
  syscallWrite,
  syscallExit,
  syscallBrk,
  syscallOpen,
  syscallRead,
  syscallWriteFd,
  syscallClose,
  syscallFork,
  syscallWait,
  syscallSeek,
  syscallIpcSend,
  syscallIpcRecv,
  syscallIpcCall,
  syscallIpcReply,
  syscallIpcGrantMap,
)
where

-- | Syscall numbers (svc #imm)
syscallYield, syscallWrite, syscallExit, syscallBrk :: Int
syscallYield = 0x00
syscallWrite = 0x01
syscallExit = 0x02
syscallBrk = 0x03

{- | Track O fd/fork numbers (svc #imm). The fd slice (0x04..0x07 + 0x0A)
backs per-pid 'Kernel.Userspace.Fd' over ramfs; fork/wait (0x08/0x09) backs
'Kernel.Userspace.Process.forkProc'. Numbering resolves the plan's
overlap (fd 0x04-0x07 vs fork 0x05/0x06): fd takes 0x04-0x07,
fork/wait move to 0x08/0x09, lseek takes 0x0A. Fd/brk ride the delegation
ring; fork/wait return ENOSYS (-38) until the fork slice lands.
Arg convention (x0..x2): BRK(newBrk), OPEN(pathVa, flags),
READ/WRITE(fd, buf, len), CLOSE(fd), SEEK(fd, off, whence).
-}
syscallOpen, syscallRead, syscallWriteFd, syscallClose :: Int
syscallOpen = 0x04
syscallRead = 0x05
syscallWriteFd = 0x06
syscallClose = 0x07

syscallFork, syscallWait, syscallSeek :: Int
syscallFork = 0x08
syscallWait = 0x09
syscallSeek = 0x0A

-- | IPC ops (svc #imm), validated by `ipc.rs` before any queue touch.
syscallIpcSend, syscallIpcRecv, syscallIpcCall, syscallIpcReply, syscallIpcGrantMap :: Int
syscallIpcSend = 0x10
syscallIpcRecv = 0x11
syscallIpcCall = 0x12
syscallIpcReply = 0x13
syscallIpcGrantMap = 0x14

{- | brk contract: EL0 svc 0x03 parks and Haskell 'procBrkGrow' extends the
caller's page map with zero pages inside 0x01000000-0x1000000000;
over-window yields EINVAL, OOM yields ENOMEM; resume x0 carries the new
break (old break when shrinking, including brk(0) as a query).
Fd contract: OPEN resumes the fd number; READ/WRITE resume the byte
count; CLOSE resumes 0; SEEK resumes the new offset. Errors resume
negative errnos: -2 ENOENT, -9 EBADF, -14 EFAULT (trap-side buffer/path
fault, never parked), -22 EINVAL, -28 ENOSPC. Per-pid tables make
cross-pid fd use fail EBADF.
Stack contract (runElf): sp is 16-byte aligned; [sp]=argc,
[sp+8]=argv[argc+1] NULL-terminated, then envp[envc+1] NULL-terminated,
then NUL-terminated strings. Bounds: 64 entries and 1024 bytes per string.
Register contract (house_enter_el0/svc_exit_trampoline): the kernel
preserves x19-x28 across the EL0 session; guests must not rely on any
other register surviving svc roundtrips (x0 carries the return value).
-}
