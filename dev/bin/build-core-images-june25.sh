#!/usr/bin/env bash
# Build and optionally push NICo Core x86 production images.
# See docs/manuals/building_nico_containers.md for prerequisites.
set -euo pipefail

REGISTRY="${REGISTRY:-subashaarna}"
TAG="${TAG:-june25}"
PUSH="${PUSH:-0}"
SA_ENABLEMENT="${SA_ENABLEMENT:-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--push] [--tag TAG] [--registry REGISTRY]

Build NICo Core x86 images:
  \${REGISTRY}/boot-artifacts-x86_64:\${TAG}
  \${REGISTRY}/machine-validation-config:\${TAG}
  \${REGISTRY}/nvmetal-carbide:\${TAG}

Environment:
  REGISTRY       Docker registry/user (default: subashaarna)
  TAG            Image tag (default: june25)
  PUSH=1         Push images after build
  SA_ENABLEMENT  Passed to cargo-make boot-artifact tasks (default: 1)
  SKIP_BASE=1    Skip build-container/runtime rebuild (reuse existing images)

Examples:
  $(basename "$0")
  $(basename "$0") --push --tag june25
  SKIP_BASE=1 $(basename "$0") --push --tag june25
  REGISTRY=my.registry/nico TAG=v1 $(basename "$0") --push
EOF
}

SKIP_BASE="${SKIP_BASE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --skip-base) SKIP_BASE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$REPO_ROOT"

# PKG_VERSION must match the .deb names cargo-make produces. Prefer git describe;
# fall back to 0.0.0-${TAG} only when .git is broken (empty describe → invalid "0.0.0-").
resolve_pkg_version() {
  local v
  v="$(git describe --tags --first-parent --always --long 2>/dev/null | sed 's/^v//')"
  if [[ -z "$v" ]]; then
    echo "0.0.0-${TAG}"
  elif [[ "$v" =~ ^[0-9] ]]; then
    echo "$v"
  else
    echo "0.0.0-$v"
  fi
}
PKG_VERSION="${PKG_VERSION:-$(resolve_pkg_version)}"
export VERSION="${VERSION:-${TAG}}"
export PKG_VERSION

if [[ "$SKIP_BASE" == "1" ]] || docker image inspect nico-buildcontainer-x86_64:latest >/dev/null 2>&1 \
  && docker image inspect nico-runtime-container-x86_64:latest >/dev/null 2>&1; then
  echo "==> Skipping base containers (reusing nico-buildcontainer-x86_64 + nico-runtime-container-x86_64)"
else
  echo "==> Building base containers"
  docker build -f dev/docker/Dockerfile.build-container-x86_64 -t nico-buildcontainer-x86_64 .
  docker build -f dev/docker/Dockerfile.runtime-container-x86_64 -t nico-runtime-container-x86_64 .
fi

echo "==> Building boot artifacts (scout.efi, qcow-imager, iPXE) [PKG_VERSION=${PKG_VERSION}]"
cargo make --cwd pxe \
  --env "SA_ENABLEMENT=${SA_ENABLEMENT}" \
  --env "PKG_VERSION=${PKG_VERSION}" \
  --env "VERSION=${VERSION}" \
  build-boot-artifacts-x86-host-sa
docker build \
  --build-arg "CONTAINER_RUNTIME_X86_64=alpine:latest" \
  -t "${REGISTRY}/boot-artifacts-x86_64:${TAG}" \
  -f dev/docker/Dockerfile.release-artifacts-x86_64 .

echo "==> Building machine-validation images"
docker build \
  --build-arg CONTAINER_RUNTIME_X86_64=nico-runtime-container-x86_64 \
  -t machine-validation-runner \
  -f dev/docker/Dockerfile.machine-validation-runner .

mkdir -p crates/machine-validation/images
docker save -o crates/machine-validation/images/machine-validation-runner.tar machine-validation-runner:latest

docker build \
  --build-arg CONTAINER_RUNTIME_X86_64=nico-runtime-container-x86_64 \
  -t "${REGISTRY}/machine-validation-config:${TAG}" \
  -f dev/docker/Dockerfile.machine-validation-config .

echo "==> Building nvmetal-carbide release (SA variant)"
VERSION="${TAG}"
CI_COMMIT_SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
docker build \
  --build-arg CONTAINER_RUNTIME_X86_64=nico-runtime-container-x86_64 \
  --build-arg CONTAINER_BUILD_X86_64=nico-buildcontainer-x86_64 \
  --build-arg "VERSION=${VERSION}" \
  --build-arg "CI_COMMIT_SHORT_SHA=${CI_COMMIT_SHORT_SHA}" \
  -f dev/docker/Dockerfile.release-container-sa-x86_64 \
  -t "${REGISTRY}/nvmetal-carbide:${TAG}" .

echo "==> Smoke tests"
docker run --rm "${REGISTRY}/nvmetal-carbide:${TAG}" /opt/carbide/carbide-api --version
docker run --rm "${REGISTRY}/boot-artifacts-x86_64:${TAG}" ls /x86_64
docker run --rm "${REGISTRY}/machine-validation-config:${TAG}" ls /machine-validation

if [[ "$PUSH" == "1" ]]; then
  echo "==> Pushing images to ${REGISTRY}"
  docker push "${REGISTRY}/boot-artifacts-x86_64:${TAG}"
  docker push "${REGISTRY}/machine-validation-config:${TAG}"
  docker push "${REGISTRY}/nvmetal-carbide:${TAG}"
  echo "==> Done. Images pushed:"
  echo "    ${REGISTRY}/boot-artifacts-x86_64:${TAG}"
  echo "    ${REGISTRY}/machine-validation-config:${TAG}"
  echo "    ${REGISTRY}/nvmetal-carbide:${TAG}"
else
  echo "==> Done (local only; use --push or PUSH=1 to publish)"
fi
