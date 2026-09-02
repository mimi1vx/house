# AGENTS.md — house/hOp aarch64 OS

GHC RTS microkernel (Haskell + tinylibc), aarch64-only, QEMU `virt` on Apple silicon. Stock threaded RTS (`-N=SMP_N`), unsafe FFI only.

## Layout
- `kernel/` — Haskell closure rooted at `HouseA64.hs` (`H/`, `Kernel/`, `Monad/`, `Util/`). `kernel/Makefile` is `ghc --make -no-link` only.
- `platform/aarch64/` — freestanding C/asm, `tinylibc/`, `spinlock.h`, `aarch64.ld`, entry Haskell `Spike.hs`/`IrqCheck.hs`. `build/` gitignored.
- `scripts/` — `expect` harnesses `qemu-*.exp` (ELF path is argv).
- `Makefile` — host orchestration; `Containerfile` — build image.

## Container — build only
- **All compilation runs inside `house-port:latest`** (Debian 12, GHC 9.14.1 aarch64). QEMU never runs inside the container; host needs `brew install qemu expect`.
- **Every `container` invocation must pin `--platform linux/arm64`.** Never set `CONTAINER_DEFAULT_PLATFORM` globally. `Containerfile:5` fails if `uname -m != aarch64`; `Makefile:9` asserts `image inspect` arch is `arm64` (no Rosetta/amd64 fallback).
- Host entrypoints wrap this for you — `make spike-build` / `irq-build` / `house-build` run `container run --platform linux/arm64 --rm -v $PWD:/work -w /work house-port:latest make -C platform/aarch64 ...` with `SMP_N` only (RAM auto-detected).
- One-time setup: `make container-image`
- Interactive shell: `make container-shell` → `container run --platform linux/arm64 --rm -it -v $PWD:/work -w /work house-port:latest bash`
- Inside container directly: `make -C kernel` and `make -C platform/aarch64 house SMP_N=2`

## Commands (repo root, macOS host)
```sh
make spike-check                         # ticks-ok, hvf
make irq-check                           # vm-ok, hvf+tcg
make house-check                         # "Welcome to the House shell", hvf+tcg
make house-shell-check house-posix-check # shell + POSIX (help/echo/uname/uptime/shutdown)
make house-fs-check house-ipc-check house-driver-check
make house-virtio-transport-check house-virtio-blk-check house-virtio-net-check
make house-userspace-check               # run /bin/hello -> Hello from EL0, TTBR0/ASID/pager
make smp-check                           # default SMP_N=2; SMP_N=4 for >2 gate (needs 4G)
make vm-check                            # vm: demand 100 pages + mprotect RO + munmap + isolate + asid + smp shootdown (512M/2+4G/4 hvf+tcg vm-ok)
make check                               # CI gate: spike + irq + house + shell + posix
SPIKE_MEM=512M make spike-check          # 512M/1G/2G/4G valid, default 4G
SMP_N=4 make smp-check
```

## Gotchas
- **RAM is auto-detected.** No `HOUSE_RAM_BYTES` limit — DTB `reg` → fault-trapped probe (`128M→16G`) → `128M` fallback; `SPIKE_MEM` (default `4G`, now `HOUSE_RAM_LIMIT`) only drives QEMU `-m` and same ELF boots at `256M`/`512M`/`1G`/`2G`/`4G`/`8G`/`16G` without rebuild; `HOUSE_RAM_LIMIT_BYTES` caps auto-detect. `SMP_N` (default `2`, max `16`, tested to `8`, now `HOUSE_SMP_LIMIT`) sets `HOUSE_SMP_N`/`HOUSE_SMP_LIMIT` and per-core 16K stacks.
- **MMU is split TTBR0=user 0x01000000–0xFFFFFFFF / TTBR1=kernel.** `mmu.c` builds `ttbr1_l0`/`ttbr0_l0` with `TCR EPD1=0 T1SZ=16 TG1=4K`, `house_mmu_set_ttbr0(pdir,asid)` loads `TTBR0_EL1` per `H.VirtualMemory PageMap` with 8-bit ASID (0 reserved) and `VMALLE1IS` on wrap. `c_start.c` handles EL1 `DFSC 0x04..0x07` translation faults via `userspace.c:house_handle_user_fault` (buddy 4K + `VAE1IS` no shootdown) and `DFSC 0x0C..0x0F` permission RO faults via `house_is_ro_page` (`perm fault RO`, skip `ELR+4`); `munmap`/`mprotect` use `VAE1IS`+SGI 1 `VMALLE1IS` shootdown. `mm/vm.c` provides real `mmap/mprotect/munmap` (4 K demand-lazy, `PROT_READ|WRITE|NONE`→`AP_RW/AP_RO`, `HOUSE_DEBUG_MMAP` gated, `__builtin_*overflow` bounds). `make vm-check` (`scripts/qemu-vm.exp` 512M/2+4G/4 hvf+tcg `vm-ok`) gates demand 100 pages, `mprotect RO perm`, `munmap unmap`, `isolate ok`, `smp shootdown ok`, ASID 10.
- **Buddy allocator over whole RAM.** `buddy.c` manages `__heap_base+64M .. house_boot_stack_top-16*16K` as intrusive free-list+bump; `H.Pages` falls through to `buddy_alloc_page` and `sysconf(_SC_PHYS_PAGES)` = `house_ram_bytes>>12`, `_SC_AVPHYS_PAGES` = `buddy_free+512`; `free`/`mem`/`detect`/`vm` shell commands show `buddy`/`ram`/`stack_top`/`TTBRs`/`TCR`.
- **Userspace EL0.** `svc.c` dispatches `svc #imm` `WRITE 0x01`→uart, `EXIT 0x02`, `BRK 0x03` ENOSYS, `IPC_* 0x10..0x14` via `Endpoint`; `start.S:house_enter_el0` `eret` to EL0 (`spsr 0`, `sp_el0`, `TTBR0`+ASID, `TLBI VMALLE1IS`); `c_start.c` `EC 0x15` handles `svc` after probe+pager. `Kernel.Userspace.Loader` caps `bytes≤1M`, `phnum≤8`, `memsz≤256K`, `pages≤64`, `validVAddr 0x01000000–0xFFFFFFFF`. `run /bin/hello` boots embedded `hello.elf` (0x01000000) → `Hello from EL0` via trapped write.
- `*-check` targets run `clean` themselves. If running `*-build` manually, `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) first.
- Expect signature: `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem] [smp]` — markers: `ticks-ok`, `vm-ok`, `Welcome to the House shell`, `smp: N cores online`.
- No `npm`/`cargo`/`pytest` — only `make` + `expect`.

## Conventions
- Keep aarch64-only; no x86 paths.
- `plans/` is untracked local notes (intentional, not gitignored); `.gitignore` only covers `kernel/build/` + `platform/aarch64/build/`.
