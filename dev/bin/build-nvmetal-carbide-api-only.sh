#!/usr/bin/env bash
# Rebuild only carbide-api and layer onto an existing nvmetal-carbide image.
set -euo pipefail

REGISTRY="${REGISTRY:-subashaarna}"
TAG="${TAG:-june25-cisco-fix}"
BASE_TAG="${BASE_TAG:-june25}"
PUSH="${PUSH:-0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--push] [--tag TAG] [--base-tag BASE_TAG]

Fast API-only nvmetal-carbide build (~5–15 min):
  Recompiles carbide-api + carbide-admin-cli, copies onto
  \${REGISTRY}/nvmetal-carbide:\${BASE_TAG}, tags \${REGISTRY}/nvmetal-carbide:\${TAG}.

Environment:
  REGISTRY   Docker registry/user (default: subashaarna)
  TAG        Output image tag (default: june25-cisco-fix)
  BASE_TAG   Existing full image to reuse runtime layers (default: june25)
  PUSH=1     Push after build

Examples:
  $(basename "$0")
  $(basename "$0") --push --tag june25-cisco-fix
  BASE_TAG=june25 TAG=june25-cisco-fix $(basename "$0") --push
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --base-tag) BASE_TAG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

BASE_IMAGE="${REGISTRY}/nvmetal-carbide:${BASE_TAG}"
OUTPUT_IMAGE="${REGISTRY}/nvmetal-carbide:${TAG}"

cd "$REPO_ROOT"

if ! docker image inspect nico-buildcontainer-x86_64:latest >/dev/null 2>&1; then
  echo "==> Building nico-buildcontainer-x86_64 (one-time prerequisite)"
  docker build -f dev/docker/Dockerfile.build-container-x86_64 -t nico-buildcontainer-x86_64 .
fi

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "==> Pulling base image ${BASE_IMAGE}"
  docker pull "${BASE_IMAGE}"
fi

echo "==> API-only build: base=${BASE_IMAGE} -> ${OUTPUT_IMAGE}"
docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "VERSION=${TAG}" \
  -f dev/docker/Dockerfile.release-api-only-x86_64 \
  -t "${OUTPUT_IMAGE}" \
  .

echo "==> Smoke test"
docker run --rm "${OUTPUT_IMAGE}" /opt/carbide/carbide-api --version

if [[ "$PUSH" == "1" ]]; then
  echo "==> Pushing ${OUTPUT_IMAGE}"
  docker push "${OUTPUT_IMAGE}"
  echo "==> Done: ${OUTPUT_IMAGE}"
else
  echo "==> Done (local): ${OUTPUT_IMAGE}  (use --push to publish)"
fi
