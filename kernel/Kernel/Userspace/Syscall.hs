{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Syscall
Description : SVC -> IPC/fd/brk shims docs.
Stability   : experimental

 Syscalls 0x03..0x07/0x0A + fork 0x08/wait 0x09/exec 0x0B + 0x10..0x13
 delegate through the park/resume ring: Rust ('svc.rs'
 'house_brk_should_park' / 'house_fd_should_park' / 'house_fork_should_park'
 / 'house_wait_should_park' / 'house_exec_should_park', 'ipc.rs'
 'house_ipc_should_park') validates trap-side and parks; Haskell
 ('Kernel.Userspace.Process.parkLoop') completes the op and resumes with
 the result in x0. GRANT_MAP 0x14 stays inline ENOSYS until its slice lands.
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
  syscallExec,
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
'Kernel.Userspace.Process.forkChildEl0' (deep copy + trap-frame clone,
child x0 = 0, parent resumes the child pid; wait blocks in 'waitPid' and
resumes the reaped exit code); exec (0x0B) backs
'Kernel.Userspace.Process.execReplace' (same pid, fds stay open).
Numbering resolves the plan's overlap (fd 0x04-0x07 vs fork 0x05/0x06):
fd takes 0x04-0x07, fork/wait move to 0x08/0x09, lseek takes 0x0A,
exec takes 0x0B. Fd/brk/fork/wait/exec ride the delegation ring.
Arg convention (x0..x2): BRK(newBrk), OPEN(pathVa, flags),
READ/WRITE(fd, buf, len), CLOSE(fd), SEEK(fd, off, whence), FORK(),
WAIT(childPid), EXEC(pathVa).
-}
syscallOpen, syscallRead, syscallWriteFd, syscallClose :: Int
syscallOpen = 0x04
syscallRead = 0x05
syscallWriteFd = 0x06
syscallClose = 0x07

syscallFork, syscallWait, syscallSeek, syscallExec :: Int
syscallFork = 0x08
syscallWait = 0x09
syscallSeek = 0x0A
syscallExec = 0x0B

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
Fork contract: svc 0x08 parks; Haskell deep-copies the address space
(no COW yet), clones the trap frame (child resumes at the post-svc pc
with x0 = 0), and resumes the parent with the child pid; ENOMEM when the
copy fails. Wait contract: svc 0x09 parks with x0 = child pid; Haskell
blocks until the child exits, reaps, and resumes the exit code (low 8
bits, like EXIT); unknown pid resumes ENOENT, self/zero pid resumes
EINVAL. Exec contract: svc 0x0B parks with x0 = NUL-terminated path
(≤256, EFAULT trap-side when unfaultable); Haskell replaces the image
under the same pid (fds stay open, argv = [path]) and resumes 0 in the
new image; missing/unparseable path resumes ENOENT/EINVAL, OOM resumes
ENOMEM.
Stack contract (runElf): sp is 16-byte aligned; [sp]=argc,
[sp+8]=argv[argc+1] NULL-terminated, then envp[envc+1] NULL-terminated,
then NUL-terminated strings. Bounds: 64 entries and 1024 bytes per string.
Register contract (house_enter_el0/svc_exit_trampoline): the kernel
preserves x19-x28 across the EL0 session; guests must not rely on any
other register surviving svc roundtrips (x0 carries the return value).
-}
