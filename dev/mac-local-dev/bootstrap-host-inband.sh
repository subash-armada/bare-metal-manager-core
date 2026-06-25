#!/usr/bin/env bash
#
# Create a Flat VPC + host_inband network segment for the Cisco zero-DPU local lab.
#
# Run after carbide-api is up and before (or while) machine-a-tron starts:
#   ./dev/mac-local-dev/run-carbide-api.sh          # terminal 1
#   ./dev/mac-local-dev/bootstrap-host-inband.sh    # once API is listening
#   ./dev/mac-local-dev/run-machine-a-tron-cisco.sh # terminal 2
#
# Idempotent: skips creation if segment "host-inband" already exists.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

API="${CARBIDE_API_URL:-localhost:1079}"
TENANT_ORG_ID="${FORGE_TENANT_ORG_ID:-Forge-simulation-tenant}"
DOMAIN_NAME="${HOST_INBAND_DOMAIN_NAME:-local.forge}"
VPC_NAME="${HOST_INBAND_VPC_NAME:-cisco-zero-dpu-flat}"
SEGMENT_NAME="${HOST_INBAND_SEGMENT_NAME:-host-inband}"
PREFIX="${HOST_INBAND_PREFIX:-192.168.253.0/24}"
GATEWAY="${HOST_INBAND_GATEWAY:-192.168.253.1}"
RESERVE_FIRST="${HOST_INBAND_RESERVE_FIRST:-5}"
DATABASE_URL="${DATABASE_URL:-postgresql://postgres:admin@localhost}"

die() {
  echo "❌ $*" >&2
  exit 1
}

info() {
  echo "ℹ️  $*"
}

ok() {
  echo "✓ $*"
}

command -v grpcurl >/dev/null 2>&1 || die "grpcurl not found (install grpcurl)"
command -v jq >/dev/null 2>&1 || die "jq not found"

grpc() {
  grpcurl -insecure "$@"
}

if ! grpc "$API" list forge.Forge >/dev/null 2>&1; then
  die "carbide-api not reachable at $API — start ./dev/mac-local-dev/run-carbide-api.sh first"
fi

existing_ids="$(grpc -d "$(jq -nc --arg name "$SEGMENT_NAME" --arg tenant "$TENANT_ORG_ID" \
  '{name: $name, tenantOrgId: $tenant}')" \
  "$API" forge.Forge/FindNetworkSegmentIds 2>/dev/null || echo '{}')"

existing_count="$(echo "$existing_ids" | jq '.networkSegmentsIds | length // 0')"

lookup_domain_id() {
  grpc -d "$(jq -nc --arg name "$DOMAIN_NAME" '{name: $name}')" \
    "$API" forge.Forge/FindDomain 2>/dev/null \
    | jq -r '.domains[0].id.value // empty'
}

ensure_segment_subdomain() {
  local seg_id="$1"
  local domain_id="$2"
  [[ -n "$domain_id" ]] || return 0

  if command -v psql >/dev/null 2>&1; then
    psql "$DATABASE_URL" -Atqc \
      "UPDATE network_segments SET subdomain_id = '$domain_id'::uuid
       WHERE id = '$seg_id'::uuid AND subdomain_id IS NULL;" \
      >/dev/null 2>&1 || true
    psql "$DATABASE_URL" -Atqc \
      "UPDATE machine_interfaces SET domain_id = '$domain_id'::uuid
       WHERE segment_id = '$seg_id'::uuid AND domain_id IS NULL;" \
      >/dev/null 2>&1 || true
  fi
}

domain_id="$(lookup_domain_id)"
[[ -n "$domain_id" ]] || die "Could not find DNS domain '$DOMAIN_NAME' (set HOST_INBAND_DOMAIN_NAME if needed)"

if [[ "$existing_count" -gt 0 ]]; then
  seg_id="$(echo "$existing_ids" | jq -r '.networkSegmentsIds[0].value')"
  ensure_segment_subdomain "$seg_id" "$domain_id"
  ok "host_inband segment already exists: $seg_id ($SEGMENT_NAME)"
  echo ""
  echo "Ensure mat-cisco-local.toml uses:"
  echo "  admin_dhcp_relay_address = \"$GATEWAY\""
  exit 0
fi

info "Creating Flat VPC '$VPC_NAME' for tenant $TENANT_ORG_ID ..."
vpc_resp="$(grpc -d "$(jq -nc \
  --arg tenant "$TENANT_ORG_ID" \
  --arg name "$VPC_NAME" \
  '{
    tenantOrganizationId: $tenant,
    networkVirtualizationType: 6,
    metadata: { name: $name, description: "Cisco zero-DPU local lab", labels: [] }
  }')" \
  "$API" forge.Forge/CreateVpc)"

vpc_id="$(echo "$vpc_resp" | jq -r '.id.value // empty')"
[[ -n "$vpc_id" ]] || die "CreateVpc did not return an id: $vpc_resp"
ok "Flat VPC created: $vpc_id"

info "Creating host_inband segment '$SEGMENT_NAME' ($PREFIX gateway $GATEWAY) ..."
seg_resp="$(grpc -d "$(jq -nc \
  --arg vpc "$vpc_id" \
  --arg name "$SEGMENT_NAME" \
  --arg domain "$domain_id" \
  --arg prefix "$PREFIX" \
  --arg gateway "$GATEWAY" \
  --argjson reserve "$RESERVE_FIRST" \
  '{
    vpcId: { value: $vpc },
    name: $name,
    subdomainId: { value: $domain },
    mtu: 9000,
    segmentType: 3,
    prefixes: [{
      prefix: $prefix,
      gateway: $gateway,
      reserveFirst: $reserve,
      freeIpCount: 0
    }]
  }')" \
  "$API" forge.Forge/CreateNetworkSegment)"

seg_id="$(echo "$seg_resp" | jq -r '.id.value // empty')"
[[ -n "$seg_id" ]] || die "CreateNetworkSegment did not return an id: $seg_resp"
ok "host_inband segment created: $seg_id"

echo ""
ok "Bootstrap complete."
echo "  VPC:     $vpc_id ($VPC_NAME, Flat)"
echo "  Segment: $seg_id ($SEGMENT_NAME, host_inband)"
echo "  Prefix:  $PREFIX (gateway $GATEWAY)"
echo ""
echo "mat-cisco-local.toml should use:"
echo "  admin_dhcp_relay_address = \"$GATEWAY\""
echo ""
echo "Verify:"
echo "  ./dev/mac-local-dev/run-carbide-admin-cli.sh network-segment show"
