FROM debian:12-slim

# Loud failure if the base resolved to x86_64 (apple-container skill guard)
RUN case "$(uname -m)" in aarch64) ;; *) \
      echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; esac

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl xz-utils git ca-certificates libgmp-dev \
   && rm -rf /var/lib/apt/lists/*

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_MINIMAL=1 \
    BOOTSTRAP_HASKELL_GHC_VERSION=9.14.1 \
    BOOTSTRAP_HASKELL_ADJUST_BASHRC=no \
    PATH=/root/.ghcup/bin:/root/.ghcup/ghc/9.14.1/bin:$PATH

RUN curl -sSf https://get-ghcup.haskell.org | sh \
   && ghcup install ghc 9.14.1 && ghcup set ghc 9.14.1
