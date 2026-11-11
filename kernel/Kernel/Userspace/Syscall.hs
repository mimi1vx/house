{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Syscall
Description : SVC -> IPC/fd/brk shims docs.
Stability   : experimental

  Syscalls 0x03..0x07/0x0A + fork 0x08/wait 0x09/exec 0x0B + dir
  0x0C..0x0F + 0x10..0x13 + sock 0x15..0x18 + pipe 0x19/0x1A
  delegate through the park/resume ring: Rust ('svc.rs'
  'house_brk_should_park' / 'house_fd_should_park' / 'house_dir_should_park'
  / 'house_fork_should_park' / 'house_wait_should_park'
 / 'house_wait_should_park' / 'house_exec_should_park', 'ipc.rs'
 'house_ipc_should_park') validates trap-side and parks; Haskell
 ('Kernel.Userspace.Process.parkLoop') completes the op and resumes with
 the result in x0. GRANT_MAP 0x14 stays inline ENOSYS until its slice lands.
 Haskell IPC remains QSem+MVar EL1; EL0 svc path uses
 non-blocking try semantics at the trap boundary.
 For slice, syscalls are handled in Rust (uart/exit) with IPC args validated.
+Errno mapping once the delegation ring lands: unknown/freed endpoint id ->
+`NoSuchEndpoint` (~ENOENT -2, also the `nsLookupChecked` miss path, logged to
+dmesg); ungranted endpoint id -> `NotOwner` (~EPERM -1, denied without
+touching the queue, logged via `checkCap`); full queue -> `QueueFull` (~EAGAIN);
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
  syscallMkdir,
  syscallUnlink,
  syscallStat,
  syscallGetdents,
  syscallIpcSend,
  syscallIpcRecv,
  syscallIpcCall,
  syscallIpcReply,
  syscallIpcGrantMap,
  syscallSockOpen,
  syscallSockSend,
  syscallSockRecv,
  syscallSockClose,
  syscallPipe,
  syscallDup2,
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
'Kernel.Userspace.Process.forkChildEl0' (COW share + trap-frame clone,
child x0 = 0, parent resumes the child pid; a write to a shared page parks
FAULT and copies/remaps RW; wait blocks in 'waitPid' for an own child and
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

{- | VFS dir numbers (svc #imm, pid1 slice). MKDIR/UNLINK take a path VA;
STAT/GETDENTS take (path VA, buf VA, len) and render newline text into the
buffer (STAT one `dir|file size N blocks M` line, GETDENTS one name per
line), resuming the byte count. Same bounds as the fd slice: paths
NUL-terminated ≤256, buffers ≤64K; over-cap fails EINVAL trap-side.
-}
syscallMkdir, syscallUnlink, syscallStat, syscallGetdents :: Int
syscallMkdir = 0x0C
syscallUnlink = 0x0D
syscallStat = 0x0E
syscallGetdents = 0x0F

-- | IPC ops (svc #imm), validated by `ipc.rs` before any queue touch.
syscallIpcSend, syscallIpcRecv, syscallIpcCall, syscallIpcReply, syscallIpcGrantMap :: Int
syscallIpcSend = 0x10
syscallIpcRecv = 0x11
syscallIpcCall = 0x12
syscallIpcReply = 0x13
syscallIpcGrantMap = 0x14

{- | S2 socket verbs (svc #imm) over the single in-flight S1 TCP transport
(no socket table, no listen/accept). OPEN takes (packed IPv4 u32 network
order, port); SEND/RECV take (buf VA, len); CLOSE takes nothing.
Validated trap-side by `svc.rs` `house_sock_should_park` (buffer bounds
only) and completed in Haskell `parkLoop` against `Net.Server`
`netSockOpen/Send/Recv/Close`, which split the S1 active-open handshake
across OPEN (SYN + wait SYN-ACK, stash seq/ack) and CLOSE (FIN).
-}
syscallSockOpen, syscallSockSend, syscallSockRecv, syscallSockClose :: Int
syscallSockOpen = 0x15
syscallSockSend = 0x16
syscallSockRecv = 0x17
syscallSockClose = 0x18

{- | Pipe/dup2 numbers (svc #imm, pipe slice). PIPE takes (ignored, wfd VA,
ignored): Haskell allocates a read+write pair in the caller's pid (fds
from 3..34; 'FdNoSpace' when fewer than two slots are free), stores the
write-end number as a 4-byte LE word at the x1 VA ('EFAULT' plus both
ends closed when the store faults), and resumes the read-end number in
x0. This one-resume-plus-one-out-param shape mirrors STAT/GETDENTS: an
svc returns a single x0, and a two-call convention would race under fork.
DUP2 takes (old, new, ignored): @new@ must be 0..34 ('EINVAL' otherwise,
checked trap-side and re-checked here), @old@ must be live ('EBADF'
otherwise); the prior occupant of @new@ is closed first (POSIX-like;
@old == new@ is a no-op), and a duped pipe end keeps sharing the buffer.
Fd 0/1 become real table entries only via DUP2; without it @WRITE fd 1@
stays 'EBADF' as today. Pipes hold 64 KiB: reads drain up to the request,
poll bounded (~5s yield-poll, then idle-empty like console) while writers
live, and see EOF once all writers close; writes to a readerless pipe
resume 'EINVAL' (broken pipe); a full pipe polls bounded then short-writes
the stored count (never silent truncation). 'SEEK' on pipes is 'EINVAL'.
Fork inherits both ends (shared buffer, counts bumped); fds stay open
across 'EXEC' (already true per the exec contract, restated because
pipelines depend on it).
-}
syscallPipe, syscallDup2 :: Int
syscallPipe = 0x19
syscallDup2 = 0x1A

{- | brk contract: EL0 svc 0x03 parks and Haskell 'procBrkGrow' extends the
caller's page map with zero pages inside 0x01000000-0x1000000000;
over-window yields EINVAL, OOM yields ENOMEM; resume x0 carries the new
break (old break when shrinking, including brk(0) as a query).
Fd contract: OPEN resumes the fd number; READ/WRITE resume the byte
count; CLOSE resumes 0; SEEK resumes the new offset. Errors resume
negative errnos: -2 ENOENT, -9 EBADF, -14 EFAULT (trap-side buffer/path
fault, never parked), -22 EINVAL, -28 ENOSPC. Per-pid tables make
cross-pid fd use fail EBADF.
Fork contract: svc 0x08 parks; Haskell shares the address space
(copy-on-write: both sides RO with the SW cow mark, refcounted; a write
fault parks FAULT, copies the page, and remaps RW), clones the trap frame
(child resumes at the post-svc pc with x0 = 0), and resumes the parent with
the child pid; ENOMEM when the share fails. Wait contract: svc 0x09 parks with x0 = child pid; Haskell
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
