# Phase 1 — Build environment scaffold (aarch64 Linux container)

Executes step 1 of `plans/ghc-9.14-aarch64-port.md` with decisions made
2026-08-25:

- **QEMU runs on the macOS host** (Homebrew qemu, HVF accel); the container is
  build-only. Smoke-test scripts (phase 5–6) therefore live host-side and
  consume the ELF built inside the container.
- **GHC installed via ghcup** (minimal profile — no cabal, no stack; the port
  uses `ghc --make`, not cabal).
- **Base distro: Debian 12 (bookworm), glibc.** Forced by upstream: the only
  official GHC 9.14.1 aarch64-Linux bindist is
  `ghc-9.14.1-aarch64-deb10-linux.tar.xz`; the Alpine/musl aarch64 slot ships
  no files. ghcup resolves to exactly this bindist on linux/aarch64.

## Steps

1. **[trivial] Host prerequisites (macOS)** — one-time:
   - `brew install qemu` (needed from phase 2 onward; verify now while cheap).
   - `export CONTAINER_DEFAULT_PLATFORM=linux/arm64` in `~/.zshrc`
     (apple-container skill: global arm64 pin).
   - `container system start`.
   — verify: `uname -m` on host → `arm64`; `qemu-system-aarch64 --version`
   prints ≥ 8.x; `container system status` reports running.

2. **[trivial] `Containerfile`** at repo root:
   ```dockerfile
   FROM debian:12-slim

   # Loud failure if the base resolved to x86_64 (apple-container skill guard)
   RUN case "$(uname -m)" in aarch64) ;; *) \
         echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; esac

   RUN apt-get update && apt-get install -y --no-install-recommends \
         build-essential curl xz-utils git ca-certificates libgmp10 \
      && rm -rf /var/lib/apt/lists/*

   ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
       BOOTSTRAP_HASKELL_MINIMAL=1 \
       BOOTSTRAP_HASKELL_GHC_VERSION=9.14.1 \
       BOOTSTRAP_HASKELL_ADJUST_BASHRC=no \
       PATH=/root/.ghcup/bin:/root/.ghcup/ghc/9.14.1/bin:$PATH

   RUN curl -sSf https://get-ghcup.haskell.org | sh \
      && ghcup install ghc 9.14.1 && ghcup set ghc 9.14.1
   ```
   Notes: `libgmp10` satisfies the deb10 bindist's GMP 6 runtime dep;
   `MINIMAL=1` installs only the ghcup binary (no cabal/stack). Build tools
   (`gcc`, `make`, `ld`) come from `build-essential` and are needed by ghcup's
   bindist configure *and* by our freestanding link later.
   — verify: covered by steps 3–5.

3. **[trivial] Image build + arch assertion** — add two targets to the
   top-level `Makefile` (legacy targets untouched):
   ```make
   IMAGE := house-port:latest

   container-image:
   	container builder start -c 4 -m 4G || true
   	CONTAINER_DEFAULT_PLATFORM=linux/arm64 container build \
   	  --platform linux/arm64 -f Containerfile -t $(IMAGE) .
   	@archs=$$(container image inspect $(IMAGE) | \
   	  jq -r '.[0].variants[].config.architecture' | sort -u); \
   	[ "$$archs" = "arm64" ] || { echo "FAIL: variants: $$archs" >&2; exit 1; }

   container-shell:
   	container run --platform linux/arm64 --rm -it \
   	  -v "$(CURDIR)":/work -w /work $(IMAGE) bash
   ```
   Bind mount puts sources and built ELF on the host filesystem so host-side
   qemu can consume them directly.
   — verify: `make container-image` ends green (jq assert printed nothing but
   passed); `container run --rm house-port uname -m` → `aarch64`.

4. **[trivial] Toolchain verification inside container**
   ```
   container run --rm house-port ghc --version        # expect 9.14.1
   container run --rm house-port ghc-pkg --version    # expect 9.14.1
   ```
   Then a compile-and-run sanity check through mount (catches missing GMP /
   ncurses runtime deps now instead of in phase 2):
   ```
   container run --rm -v "$PWD":/work -w /work house-port bash -c \
     'echo "main :: IO (); main = putStrLn \"toolchain-ok\"" > /tmp/h.hs \
      && ghc -v0 -o /tmp/h /tmp/h.hs && /tmp/h'
   ```
   — verify: prints `toolchain-ok`.

5. **[trivial] Record results** — append outcome (versions, any deviations)
   to `plans/porting-log.md` (create the file; it is the log required by
   master-plan step 4).

## Files

- Create: `Containerfile`
- Modify: `Makefile` (append `container-image` / `container-shell`; legacy
  flow untouched)
- Create: `plans/porting-log.md` (started in this phase)
- Host-only (not repo): `~/.zshrc` env var, `brew install qemu`

## Risks

- **ghcup bootstrap hangs without `NONINTERACTIVE=1`** — set explicitly in
  the ENV block above; never pipe-to-sh interactively in a build.
- **deb10 bindist on Debian 12** — forward-glibc compatible by design;
  residual risk is a missing shared lib, which step 4's compile-and-run
  flushes out immediately.
- **Apple-container quirks**: builder DNS failure → restart builder with
  `--dns 1.1.1.1`; bind-mount perf is weaker than Docker Desktop (acceptable
  here; if `ghc --make` over ~167 modules gets painful in phase 4, switch to
  copying the tree into the image/volume and copying the ELF back out).

## Alternatives considered

- Alpine + third-party musl GHC (benz0li images) — rejected: no official
  aarch64 musl bindist; third-party supply chain contradicts the pinned-
  toolchain goal.
- Direct bindist download with SHA256 pin — rejected this round (user chose
  ghcup); ghcup still resolves deterministically to the official deb10
  bindist for 9.14.1 on this platform.
- QEMU in-container (TCG) — rejected by user: host qemu gives HVF speed and
  simpler interactive serial sessions.

## Success criteria

- [ ] `make container-image` succeeds; jq arch assert passes (`arm64` only)
- [ ] `container run --rm house-port uname -m` → `aarch64`
- [ ] `container run --rm house-port ghc --version` → `The Glorious Glasgow Haskell Compilation System, version 9.14.1`
- [ ] Mounted-workspace compile-and-run prints `toolchain-ok`
- [ ] Host: `qemu-system-aarch64 --version` works (machine boot tested in phase 2)
- [ ] Legacy i386 flow untouched (`git diff` shows only new targets in `Makefile`)
