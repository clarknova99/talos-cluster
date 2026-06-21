#!/usr/bin/env bash
# Build a temps container image from source and push it to GHCR.
#
# Why this script exists:
#   gotempsh/temps does not publish a public Docker image. The upstream
#   Dockerfile (https://github.com/gotempsh/temps/blob/main/Dockerfile)
#   expects a *prebuilt* musl Rust binary — the Rust compile step has to
#   happen outside it. This script:
#     1. Clones gotempsh/temps at the requested tag (inside a docker volume).
#     2. (Optional) Downloads GeoLite2-City.mmdb when MAXMIND_LICENSE_KEY
#        is set so it gets embedded into the final image.
#     3. Builds the Rust binary + WASM + Web UI inside a rust:1.90-alpine
#        container so callers don't need a local Rust/bun/npm toolchain.
#     4. Runs the upstream Dockerfile with --build-arg PREBUILT_BINARY
#        from inside a tiny docker-cli container that reuses the host's
#        docker socket — this keeps the build context off macOS' bind
#        mount entirely (bun + VirtioFS = corrupted tarballs).
#     5. Pushes the resulting image to GHCR with both the version tag and
#        :latest.
#
# Why everything runs in named volumes instead of a host workdir:
#   Docker Desktop on macOS shares host folders via VirtioFS. Bun does
#   massively-parallel tarball extracts during `bun install` which
#   regularly truncate files over VirtioFS, producing
#   "Fail/InstallFailed/FileNotFound extracting tarball" errors mid-install.
#   Keeping the source + node_modules + target/ on docker-native volumes
#   sidesteps the issue entirely.
#
# Usage:
#   ./build-image.sh                       # builds VERSION=v0.1.0-beta.34
#   ./build-image.sh v0.1.0-beta.34
#   IMAGE=ghcr.io/myorg/temps ./build-image.sh v0.1.0-beta.34
#
# Required:
#   - docker (with buildx) and a logged-in GHCR session
#       echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
#
# Optional env:
#   MAXMIND_LICENSE_KEY   Embed GeoLite2-City.mmdb into the image at build
#                         time. Without it, geolocation features stay
#                         disabled until the binary downloads the db at
#                         runtime (it uses MAXMIND_LICENSE_KEY then too).
#   PLATFORM              Default linux/amd64 (matches all cluster nodes).
#   IMAGE                 Default ghcr.io/clarknova99/temps.
#   CLEAN                 Set to 1 to wipe all build volumes first
#                         (forces a from-scratch rebuild).

set -euo pipefail

VERSION="${1:-v0.1.0-beta.34}"
IMAGE="${IMAGE:-ghcr.io/clarknova99/temps}"
PLATFORM="${PLATFORM:-linux/amd64}"
TAG="${VERSION#v}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi
if ! docker buildx version >/dev/null 2>&1; then
  echo "error: docker buildx is required" >&2
  exit 1
fi

# Named volumes that survive between runs. The src volume is wiped/recloned
# every run to track the requested VERSION, but cargo/rustup/target caches
# stay so retries are fast.
SRC_VOL=temps-build-src
CARGO_VOL=temps-build-cargo
RUSTUP_VOL=temps-build-rustup
TARGET_VOL=temps-build-target

if [[ "${CLEAN:-0}" == "1" ]]; then
  echo ">> CLEAN=1 — wiping build volumes"
  docker volume rm -f "$SRC_VOL" "$CARGO_VOL" "$RUSTUP_VOL" "$TARGET_VOL" >/dev/null 2>&1 || true
fi

docker volume create "$SRC_VOL"    >/dev/null
docker volume create "$CARGO_VOL"  >/dev/null
docker volume create "$RUSTUP_VOL" >/dev/null
docker volume create "$TARGET_VOL" >/dev/null

echo ">> Ensuring gotempsh/temps@${VERSION} is checked out in volume ${SRC_VOL}"
# Reuse an existing checkout when it already points at the requested ref —
# this preserves file mtimes so cargo's incremental cache is valid across
# re-runs. A fresh clone would touch every file and force a full workspace
# recompile (multi-hour rebuild).
docker run --rm \
  -v "$SRC_VOL":/src \
  -e VERSION="${VERSION}" \
  alpine:3.20 sh -lc '
    set -euo pipefail
    apk add --no-cache git >/dev/null

    repo_url="https://github.com/gotempsh/temps.git"
    # Ask git for both the tag object and the peeled commit; prefer the
    # peeled (^{}) line because annotated tags otherwise resolve to the
    # tag object SHA, not the commit SHA we would see in HEAD.
    refs="$(git ls-remote "$repo_url" \
              "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}")"
    want_sha="$(echo "$refs" | awk "/\\^\\{\\}\$/ {print \$1; exit}")"
    [ -n "$want_sha" ] || \
      want_sha="$(echo "$refs" | awk "{print \$1; exit}")"
    [ -n "$want_sha" ] || { echo "could not resolve ${VERSION}"; exit 1; }

    if [ -d /src/temps/.git ]; then
      have_sha="$(git -C /src/temps rev-parse HEAD 2>/dev/null || echo none)"
      if [ "$have_sha" = "$want_sha" ]; then
        echo "already at ${VERSION} ($have_sha) — skipping clone"
        exit 0
      fi
      echo "have $have_sha, want $want_sha — re-cloning"
    fi

    rm -rf /src/temps
    git clone --depth 1 --branch "${VERSION}" "$repo_url" /src/temps
  '

if [[ -n "${MAXMIND_LICENSE_KEY:-}" ]]; then
  echo ">> MAXMIND_LICENSE_KEY set — downloading GeoLite2-City.mmdb into volume"
  docker run --rm \
    -v "$SRC_VOL":/src \
    -e MAXMIND_LICENSE_KEY="${MAXMIND_LICENSE_KEY}" \
    alpine:3.20 sh -lc '
      set -euo pipefail
      apk add --no-cache curl tar >/dev/null
      cd /tmp
      curl -fsSL \
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz" \
        -o geolite2.tar.gz
      tar -xzf geolite2.tar.gz
      cp GeoLite2-City_*/GeoLite2-City.mmdb /src/temps/GeoLite2-City.mmdb
      echo "GeoLite2-City.mmdb staged at repo root"
    '
fi

echo ">> Building Rust binary + WASM + Web UI in rust:1.90-alpine (${PLATFORM})"
# Mirrors the manual steps documented in the upstream Dockerfile:
#   1) build temps-captcha-wasm  2) build web UI  3) cargo build --release
#
# The rust:*-alpine image ships rustc/cargo via apk and lacks rustup; we
# install rustup ourselves so we can add the wasm32 target. The script is
# idempotent — re-runs reuse the existing rustup install in the volume.
#
# Memory: the mongodb + aws-sdk-* crates each peak at 5-8 GB of RAM per
# rustc invocation. Without a cap, parallel cargo workers OOM-kill each
# other on a Docker Desktop default (8 GB). CARGO_BUILD_JOBS=2 plus
# CODEGEN_UNITS=256 keep peak memory bounded. If you still see SIGKILL on
# a single crate, drop CARGO_BUILD_JOBS to 1.
docker run --rm \
  --platform "${PLATFORM}" \
  -v "$SRC_VOL":/src \
  -v "$CARGO_VOL":/usr/local/cargo \
  -v "$RUSTUP_VOL":/usr/local/rustup \
  -v "$TARGET_VOL":/src/temps/target \
  -w /src/temps \
  -e RUSTUP_HOME=/usr/local/rustup \
  -e CARGO_HOME=/usr/local/cargo \
  -e CARGO_BUILD_JOBS=2 \
  -e CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256 \
  rust:1.90-alpine sh -lc '
    set -euo pipefail
    apk add --no-cache \
      bash build-base cmake perl musl-dev pkgconfig \
      openssl-dev postgresql-dev git curl tar gzip nodejs npm \
      protoc protobuf-dev

    if ! command -v rustup >/dev/null 2>&1; then
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal \
          --target wasm32-unknown-unknown
    fi
    export PATH="/usr/local/cargo/bin:$PATH"
    rustup target add wasm32-unknown-unknown

    if ! command -v bun >/dev/null 2>&1; then
      curl -fsSL https://bun.sh/install | bash
      ln -sf /root/.bun/bin/bun /usr/local/bin/bun
    fi
    if ! command -v wasm-pack >/dev/null 2>&1; then
      npm install -g wasm-pack
    fi

    cd /src/temps/crates/temps-captcha-wasm
    bun install
    npm run build

    cd /src/temps/web
    bun install
    RSBUILD_OUTPUT_PATH=/src/temps/crates/temps-cli/dist bun run build

    cd /src/temps
    cargo build --release --bin temps

    # Stage the prebuilt binary at the repo root where upstream Dockerfile
    # expects it (matches `--build-arg PREBUILT_BINARY=temps`).
    cp target/release/temps temps
  '

echo ">> Building and pushing ${IMAGE}:${TAG} (and :latest) from volume"
# We don't use the upstream multi-stage Dockerfile because:
#   1) Even with PREBUILT_BINARY it still tries to re-run wasm-pack
#      and the web build, which doubles the work we already did.
#   2) The repo's build context is ~1.3 GB after a build; uploading
#      that to the daemon on every push is wasteful.
# Instead we assemble a tiny context with just the binary (+ optional
# MaxMind mmdb) and a small Alpine-based runtime Dockerfile.
docker run --rm \
  -v "$SRC_VOL":/src \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${HOME}/.docker":/root/.docker \
  -e IMAGE="${IMAGE}" \
  -e TAG="${TAG}" \
  -e PLATFORM="${PLATFORM}" \
  docker:27-cli sh -lc '
    set -euo pipefail
    ctx=$(mktemp -d)
    cp /src/temps/temps "$ctx/temps"
    if [ -f /src/temps/GeoLite2-City.mmdb ]; then
      cp /src/temps/GeoLite2-City.mmdb "$ctx/GeoLite2-City.mmdb"
    fi
    cat > "$ctx/Dockerfile" <<DOCKERFILE
FROM alpine:3.20
RUN apk add --no-cache ca-certificates libssl3 postgresql-client tzdata \
 && addgroup -g 1001 -S appgroup \
 && adduser -u 1001 -S appuser -G appgroup \
 && mkdir -p /app/data \
 && chown -R appuser:appgroup /app
WORKDIR /app
COPY --chown=appuser:appgroup --chmod=0755 temps /app/temps
COPY --chown=appuser:appgroup GeoLite2-City.mmd[b] /app/GeoLite2-City.mmdb
USER appuser
EXPOSE 3000 3443 9000
ENTRYPOINT ["/app/temps"]
DOCKERFILE
    cd "$ctx"
    docker buildx build \
      --platform "$PLATFORM" \
      -t "$IMAGE:$TAG" \
      -t "$IMAGE:latest" \
      --push \
      .
  '

echo ">> Done. Pushed ${IMAGE}:${TAG}"
