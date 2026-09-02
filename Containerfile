FROM debian:13-slim

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

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal \
    && /root/.cargo/bin/rustup target add aarch64-unknown-none \
    && /root/.cargo/bin/rustup component add rustfmt clippy
ENV PATH=/root/.cargo/bin:$PATH
COPY rust-toolchain.toml /work/rust-toolchain.toml
