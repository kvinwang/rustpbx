#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-restsend/rustpbx}"
TAG="${TAG:-latest}"
PLATFORM="${PLATFORM:-linux/amd64}"

# pinned 2026-03-06; update digest when upgrading builder image
RUST_BUILDER="rust:1.92.0-bookworm@sha256:e90e846de4124376164ddfbaab4b0774c7bdeef5e738866295e5a90a34a307a2"

# Reproducibility: clamp all timestamps to the git commit time
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"

echo "=== Reproducible Build ==="
echo "  commit:            $(git rev-parse --short HEAD)"
echo "  SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH} ($(date -d @"${SOURCE_DATE_EPOCH}" -u '+%Y-%m-%d %H:%M:%S UTC'))"
echo "  platform:          ${PLATFORM}"
echo "  builder:           ${RUST_BUILDER%%@*}"
echo "  image:             ${REGISTRY}/${IMAGE_NAME}:${TAG}"
echo ""

# Build binaries inside a pinned container if bin/ doesn't exist yet
if [ ! -d bin ]; then
    echo "--- bin/ not found, building binaries in container ---"

    # Map docker platform to arch dir
    case "${PLATFORM}" in
        linux/amd64) ARCH_DIR=amd64 ;;
        linux/arm64) ARCH_DIR=arm64 ;;
        *)           echo "ERROR: unsupported platform ${PLATFORM}" >&2; exit 1 ;;
    esac

    # Use named volumes for cargo cache to speed up rebuilds
    docker run --rm \
        -v "$(pwd)":/build \
        -w /build \
        -v rustpbx-cargo-registry:/usr/local/cargo/registry \
        -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
        "${RUST_BUILDER}" \
        bash -c "apt-get update -qq && apt-get install -y -qq cmake libopus-dev > /dev/null 2>&1 && cargo build --release"

    mkdir -p "bin/${ARCH_DIR}"
    cp target/release/rustpbx "bin/${ARCH_DIR}/"
    cp target/release/sipflow  "bin/${ARCH_DIR}/"
    echo ""
fi

# Build image with buildx, capture manifest digest via metadata-file
METAFILE="$(mktemp)"
trap 'rm -f "${METAFILE}"' EXIT

docker buildx build \
    --platform "${PLATFORM}" \
    --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
    --provenance=false \
    --sbom=false \
    --tag "${REGISTRY}/${IMAGE_NAME}:${TAG}" \
    --metadata-file "${METAFILE}" \
    --load \
    .

# Extract the manifest digest (same hash registries return on push)
DIGEST="$(jq -r '.["containerimage.digest"]' "${METAFILE}")"
if [ -z "${DIGEST}" ] || [ "${DIGEST}" = "null" ]; then
    # fallback: older buildkit may only have config digest
    DIGEST="$(jq -r '.["containerimage.config.digest"]' "${METAFILE}")"
fi

echo "Image digest: ${DIGEST}"
