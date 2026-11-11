# Console shell & getty

EL0 `/bin/sh` over the virtio-console, supervised by EL0 `/sbin/init`.
Harness: `scripts/qemu-sh.exp` via `make house-sh-check` (first-class gate
in `make check` and `make check-tcg`). For boot/entry see
[Boot & runtime](boot-runtime.md); for host setup see
[Host QEMU](host-qemu.md).

## Topology: PL011 primary, virtio-console optional

Kernel console output flows through the `Kernel.Console` channel
(`kernel/Kernel/Console.hs`: `putString`/`putStr` enqueue `PutStr`,
`putChar` enqueues one cell) drained to the PL011 UART by
`Kernel.Driver.PL011`. The virtio-console is opt-in per slot:
`virtio scan` finds the device (`device_id=3`,
`rust/crates/house-hal-aarch64/src/virtio_con.rs`; multipoint serial is
ID 11), then `con init <slot>` starts the server (`Kernel.Shell.Loop`
hands to `Con.conServerInit`, answering
`ok qsize0=… qsize1=… slot=…`). A `con mirror` switch duplicates UART
output to the serial side; default off. EL0 reaches the console only
through the reserved `/dev/console` path (`userspace/sh.s` `conpath`;
`kernel/Kernel/Userspace/Fd.hs`: reserved path bound to the
virtio-console endpoint via the IPC nameservice — no VFS node, no new
svc). The harness discovers the slot with `virtio scan` instead of
assuming one (`scripts/qemu-sh.exp`), then bridges the socket with
`socat TCP-LISTEN:4446 … UNIX-CONNECT:/tmp/house-sh.sock` because host
Tcl cannot speak `AF_UNIX`.

## stdout: legacy-UART 0x01 vs pipeable fd 1 (0x06)

`svc #0x01` (`HOUSE_SVC_WRITE`, `rust/.../svc.rs`; `syscallWrite`,
`kernel/Kernel/Userspace/Syscall.hs`) writes to the legacy UART console.
`svc #0x06` (`HOUSE_SVC_WRITE_FD`; `syscallWriteFd`) writes through the
per-pid fd table — and fd 1 exists only after `DUP2`: without it
`WRITE fd 1` stays `EBADF` (`kernel/Kernel/Userspace/Syscall.hs`; fds
3..34 per pid, stdio 0–2 reserved, `kernel/Kernel/Userspace/Fd.hs`).
`/sbin/init` (`userspace/init.s`) stays on the legacy path (`svc #0x01`
for `init up` / `init done` / `init fail`). `/bin/sh` instead binds fd 1
at startup (`userspace/sh.s`): a zero-length `WRITE_FD(1, buf, 0)` probe
— silent when bound, `EBADF` when not — then `OPEN /dev/console
O_WRONLY` + `DUP2(c, 1)` on the miss. So with the console up, ALL EL0
output (prompt, echo, command results) arrives on the socket;
kernel-side markers stay on UART. The harness asserts on the socket
(`sock_expect`) and on UART (`expect`) separately for this reason.

## Pipes: PIPE 0x19 / DUP2 0x1A

`PIPE` takes `(ignored, wfd VA, ignored)`: the read end resumes in `x0`
and the write end is stored as a 4-byte LE word at the `x1` VA
(`EFAULT` plus both ends closed when the store faults). `DUP2` takes
`(old, new, ignored)`: `new` must be 0..34 (`EINVAL` otherwise), `old`
must be live (`EBADF`); the prior occupant of `new` is closed first
(`old == new` is a no-op); a duped pipe end shares the buffer. Pipes
hold 64 KiB: reads drain up to the request, poll bounded (~5 s
yield-poll, console-style) while writers live, and see EOF once all
writers close; writes to a readerless pipe fail `EINVAL` (broken pipe);
a full pipe short-writes after a bounded poll; `SEEK` on pipes is
`EINVAL`. Fork inherits both ends (shared buffer, bumped counts); fds
stay open across `EXEC`. (`kernel/Kernel/Userspace/Syscall.hs`;
`kernel/Kernel/Userspace/Fd.hs`: one shared `PipeState` `Ref` plus
reader/writer counts — last-writer close surfaces EOF, last-reader close
surfaces broken-pipe.) The shell builds N−1 pipes for N stages (at most
8 stages), forks each stage with `DUP2` wiring (stdin: console, `<` file,
or pipe; stdout: probe-bound default, `>`/`>>` file, or pipe), has each
child close ALL pipe fds, then the parent closes its copies at once
(else EOF never arrives) and `WAIT`s left-to-right, reporting
`ok exit <last>` (`userspace/sh.s`). The canonical harness proof is
`echo hi | cat` with exactly one `hi` (`scripts/qemu-sh.exp`): a parent
that keeps its pipe ends open hangs at EOF instead; a double-mapped fd
would duplicate.

## Getty: respawn, YIELD pacing, up | done | fail

`/sbin/init` (`userspace/init.s`) prints `init up` once, then loops
FOREVER: `FORK`, child `EXEC /bin/sh`, parent `WAIT` + `init done`,
re-loop paced by a small bounded run of `YIELD`s so an instantly-exiting
child cannot hot-spin. Exec miss fails closed per iteration (`init fail`
+ child `EXIT 1`); the exit code stays visible only via the kernel
reaper thread's `init exit CODE` (`kernel/Kernel/Init.hs`, which also
owns the fail-closed `initramfs: init fail E` when `/sbin/init` is
missing/unparseable). Without a console device the respawned `sh` fails
closed (`sh: ENOENT`, exit 1) and init reaps that instead — so
`scripts/qemu-pid1.exp` collects `init pid` / `init up` / `sh: ENOENT` /
prompt order-free, then requires a first `init done` plus a second
`ENOENT`/`done` pair to prove init re-forked, and fails on any
`house login:`. With the console up (`scripts/qemu-sh.exp`), the first
live `sh` prints `house login: ` on the socket (kernel prompt is `> `,
EL0 prompt is `sh$ ` — the harness matches only the latter, after the
login line), answers `tester` with `login tester`, and idle EOF (socket
close) drains the console read to empty so `sh` CLOSEs + `EXIT`s 0 and
init reaps `init done`.

## Deferred: quoting, vars, glob, job control, wakeup queue

Not implemented: quoting, variable expansion, globbing, background `&` /
job control (`|`, `>`, `>>`, `<` are standalone fields only —
`echo a|b` stays one word; at most 16 args of 256 B per stage, 8
stages). Pipe and console reads use bounded yield-poll (~5 s; the shell
tolerates a few empty reads so a fragmented line still completes, and 6
consecutive empties mean EOF), not a wakeup queue. Replacing the poll
with wakeup discipline is deferred hardening.
