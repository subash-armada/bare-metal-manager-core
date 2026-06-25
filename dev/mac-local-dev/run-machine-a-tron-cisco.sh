#!/usr/bin/env bash
#
# Start machine-a-tron with the Cisco UCS local-dev config.
# Requires carbide-api from ./dev/mac-local-dev/run-carbide-api.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

export REPO_ROOT
export FORGE_ROOT_CA_PATH="${FORGE_ROOT_CA_PATH:-$REPO_ROOT/dev/certs/localhost/ca.crt}"
export CLIENT_CERT_PATH="${CLIENT_CERT_PATH:-$REPO_ROOT/dev/certs/localhost/client.crt}"
export CLIENT_KEY_PATH="${CLIENT_KEY_PATH:-$REPO_ROOT/dev/certs/localhost/client.key}"
export MACHINE_A_TRON_CONFIG_PATH="${MACHINE_A_TRON_CONFIG_PATH:-$REPO_ROOT/dev/deployment/devspace/mat-cisco-local.toml}"

exec cargo run -p carbide-machine-a-tron
