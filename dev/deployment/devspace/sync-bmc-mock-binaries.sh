#!/usr/bin/env bash
# Fast-sync locally built machine-a-tron and bmc-mock binaries into Skaffold staging
# so `skaffold dev` / `devspace dev` can push them into running pods without a full
# Docker image rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

echo "Building machine-a-tron and bmc-mock..."
cargo build -p carbide-machine-a-tron -p bmc-mock

MAT_STAGE="$ROOT/.skaffold/target/carbide-machine-a-tron/debug"
MOCK_STAGE="$ROOT/.skaffold/target/carbide-bmc-mock/debug"
mkdir -p "$MAT_STAGE" "$MOCK_STAGE"

cp "$ROOT/target/debug/machine-a-tron" "$MAT_STAGE/"
cp "$ROOT/target/debug/bmc-mock" "$MOCK_STAGE/"

echo "Staged binaries:"
echo "  $MAT_STAGE/machine-a-tron"
echo "  $MOCK_STAGE/bmc-mock"
echo "Run skaffold dev or devspace dev to sync into running pods."
