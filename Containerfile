FROM debian:13-slim

# Loud failure if the base resolved to x86_64 (apple-container skill guard)
RUN case "$(uname -m)" in aarch64) ;; *) \
      echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; esac

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl xz-utils git ca-certificates libgmp-dev \
      libffi-dev libncurses-dev zlib1g-dev pkg-config \
      llvm lld \
   && rm -rf /var/lib/apt/lists/*

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_MINIMAL=1 \
    BOOTSTRAP_HASKELL_ADJUST_BASHRC=no \
    PATH=/root/.ghcup/bin:/root/.cabal/bin:/root/.cargo/bin:/usr/local/bin:$PATH

# GHC floats to newest stable at build time via GHCup (house-ng pattern).
# Resolved version must be pinned into docs/TOOLCHAIN.md on every bump.
RUN curl -sSf https://get-ghcup.haskell.org | sh \
    && ghcup install ghc latest --set \
    && ghcup install cabal --set \
    && ghc --version \
    && cabal --version

# Rust toolchain: nightly minimal + bare-metal target + Miri.
# Nightly is the default: Miri only ships for nightly.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain nightly \
    && /root/.cargo/bin/rustup default nightly \
    && /root/.cargo/bin/rustup target add aarch64-unknown-none \
    && /root/.cargo/bin/rustup component add clippy rustfmt miri \
    && rustc --version \
    && cargo --version \
    && cargo clippy --version \
    && cargo fmt --version \
    && cargo miri --version
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:/root/.cargo/bin:/usr/local/bin:$PATH
COPY rust-toolchain.toml /work/rust-toolchain.toml

# Haskell formatter + linter, pinned to match host tooling.
RUN ghcup config add-release-channel 3rdparty \
    && ghcup install fourmolu 0.20.1.0 --set \
    && apt-get update \
    && apt-get install -y --no-install-recommends hlint \
    && rm -rf /var/lib/apt/lists/* \
    && fourmolu --version \
    && hlint --version \
    && ld.lld --version

# Dependency auditor, pinned release binary with checksum.
ARG CARGO_DENY_VERSION=0.20.2
RUN curl -sSfL "https://github.com/EmbarkStudios/cargo-deny/releases/download/${CARGO_DENY_VERSION}/cargo-deny-${CARGO_DENY_VERSION}-aarch64-unknown-linux-musl.tar.gz" -o /tmp/cargo-deny.tgz \
    && curl -sSfL "https://github.com/EmbarkStudios/cargo-deny/releases/download/${CARGO_DENY_VERSION}/cargo-deny-${CARGO_DENY_VERSION}-aarch64-unknown-linux-musl.tar.gz.sha256" -o /tmp/cargo-deny.tgz.sha256 \
    && EXPECTED="$(cut -d' ' -f1 /tmp/cargo-deny.tgz.sha256)" \
    && ACTUAL="$(sha256sum /tmp/cargo-deny.tgz | cut -d' ' -f1)" \
    && [ "$EXPECTED" = "$ACTUAL" ] \
    && tar -xzf /tmp/cargo-deny.tgz -C /tmp \
    && mv "/tmp/cargo-deny-${CARGO_DENY_VERSION}-aarch64-unknown-linux-musl/cargo-deny" /usr/local/bin/cargo-deny \
    && rm -rf /tmp/cargo-deny.tgz* "/tmp/cargo-deny-${CARGO_DENY_VERSION}-aarch64-unknown-linux-musl" \
    && cargo deny --version

# Link toolchain entry points onto the default PATH: login shells rebuild
# PATH from scratch and drop the image ENV additions.
RUN for d in /root/.ghcup/bin /root/.cabal/bin /root/.cargo/bin; do \
      for f in "$d"/*; do \
        [ -e "$f" ] || continue; \
        ln -sf "$f" /usr/local/bin/; \
      done; \
    done

WORKDIR /work

CMD ["bash"]
