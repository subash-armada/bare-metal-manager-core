# Cisco UCS Zero-DPU Local Lab

End-to-end local simulation of a **Cisco UCS C845A M8** (zero-DPU) host using
`carbide-api`, `machine-a-tron` (MAT), and `bmc-mock`. This guide covers the
code changes that enable Cisco UCS support, how to reset and run the lab from
scratch, and common troubleshooting.

---

## Architecture

```
┌─────────────────────┐     mTLS/gRPC      ┌──────────────────────┐
│  machine-a-tron     │ ─────────────────► │  carbide-api         │
│  (MAT TUI + DHCP    │                    │  (Postgres + Vault)  │
│   relay sim)        │                    │                      │
└─────────┬───────────┘                    └──────────┬───────────┘
          │                                           │
          │ Redfish :2000                             │ site_explorer
          ▼                                           │ bmc_proxy → :2000
┌─────────────────────┐                               │
│  bmc-mock           │ ◄─────────────────────────────┘
│  (CiscoUcs profile) │
└─────────────────────┘
```

MAT simulates:

- **OOB DHCP** for the BMC (`02:01:00:00:00:01` → `192.168.2.x`)
- **Host-inband DHCP** for the host PXE NIC (`02:01:00:00:00:02` → `192.168.253.x`)
- **Redfish BMC** responses (Cisco UCS / AMI MegaRAC layout)
- **PXE boot** via the API (`use_pxe_api = true` — no separate `nico-pxe` process)

---

## Code Changes Summary

### 1. BMC mock — parameterized Cisco UCS hardware

| File | Change |
|------|--------|
| `crates/bmc-mock/src/hw/cisco_ucs.rs` | New parameterized mock: product string (`CAI-845A-M8`, `CAI-885A-M8`), GPU profile (`mgx_pcie`, `hgx_sxm`), boot options, discovery info |
| `crates/bmc-mock/src/machine_info.rs` | `HostHardwareType::CiscoUcs` wired to `CiscoUcs` mock; vendor `BmcVendor::Cisco` |
| `crates/bmc-mock/src/redfish/oem/mod.rs` | AMI uses `/Bios/SD`; Cisco UCS uses `/Bios/Settings` for BIOS and `/Systems/{id}/SD` for boot order |
| `crates/bmc-mock/src/redfish/computer_system.rs` | `PATCH Systems/{id}` boot-order returns **204 No Content** (libredfish expects empty body, not `{}`) |

Replaces the old hard-coded `cisco_ucs_c845a_m8` profile with a single
parameterized implementation usable for multiple SKUs.

### 2. libredfish — Cisco UCS Redfish behavior

| File | Change |
|------|--------|
| `vendor/libredfish/src/cisco.rs` | Cisco-specific BIOS attrs, serial-console attrs, automatic-retry boot detection |
| `vendor/libredfish/src/ami.rs` | `is_cisco()` uses **manufacturer only** (`RedfishVendor::Cisco`); Cisco branches for BIOS `/Settings` (not AMI `/SD`), infinite boot via `Boot.AutomaticRetryConfig` only (C845A rejects `AutomaticRetryAttempts`) |
| `vendor/libredfish/src/cisco.rs` | `is_automatic_retry_boot_enabled()` checks `RetryAttempts` only — C845A does not expose or accept `AutomaticRetryAttempts` |

### 3. BMC explorer tests

| File | Change |
|------|--------|
| `crates/bmc-explorer/tests/cisco_ucs_explore.rs` | Explore tests for `CAI-845A-M8` (MGX PCIe) and `CAI-885A-M8` (HGX SXM) |
| `crates/bmc-mock/src/test_support/mod.rs` | `cisco_ucs_bmc(product, gpu_profile)` test helper |

### 4. machine-a-tron — Cisco config + expected-machine registration

| File | Change |
|------|--------|
| `crates/machine-a-tron/src/config.rs` | `hw_type = "cisco_ucs"`, `cisco_product`, `cisco_gpu_profile` on machine config |
| `crates/machine-a-tron/src/host_machine.rs` | Passes Cisco product/profile into `HostMachineInfo` |
| `crates/machine-a-tron/src/api_client.rs` | **`register_expected_machine()`** — auto-registers expected machine on startup with zero-DPU metadata |
| `crates/machine-a-tron/src/machine_a_tron.rs` | Calls registration when `register_expected_machines = true` |

**Expected machine fields set for zero-DPU Cisco hosts:**

```json
{
  "dpu_mode": "no_dpu",
  "host_nics": [{ "mac_address": "<host-pxe-mac>", "nic_type": "onboard", "primary": true }],
  "host_lifecycle_profile": { "disable_lockdown": true }
}
```

If the BMC MAC already exists (prior MAT run), missing `host_nics` / `dpu_mode` /
`host_lifecycle_profile` are merged via upsert.

### 5. Site / HCL configuration (DevSpace + tests)

| File | Change |
|------|--------|
| `dev/deployment/devspace/values.base.yaml` | BIOS profiles + `host_models` for `CAI-845A-M8`, `CAI-885A-M8`, generic `cisco_ucs_ami` |
| `dev/deployment/devspace/machine-a-tron.yaml` | K8s MAT config: `hw_type = "cisco_ucs"`, zero DPU |
| `docs/provisioning/examples/cisco_c845a_expected_machines.json` | Example expected-machine manifest (C845A) |
| `docs/provisioning/examples/cisco_c885a_expected_machines.json` | Example expected-machine manifest (C885A) |

### 6. Local dev scripts and config

| File | Purpose |
|------|---------|
| `dev/mac-local-dev/carbide-api-config.toml` | `allow_zero_dpu_hosts = true`, `site_explorer.bmc_proxy = ":2000"` |
| `dev/deployment/devspace/mat-cisco-local.toml` | MAT config for WSL/Linux local lab |
| `dev/mac-local-dev/bootstrap-host-inband.sh` | Create Flat VPC + `host_inband` segment for zero-DPU lab |
| `dev/mac-local-dev/run-machine-a-tron-cisco.sh` | Wrapper to start MAT with Cisco config |

---

## Simulated Machine Identity

Each MAT Cisco host gets deterministic addresses derived from its index:

| Role | MAC | Typical IP |
|------|-----|------------|
| BMC (OOB) | `02:01:00:00:00:01` | `192.168.2.2` |
| Host PXE NIC (host_inband) | `02:01:00:00:00:02` | `192.168.253.5` |
| Chassis serial | `020100000001` | — |

Factory BMC credentials used by MAT/expected-machine registration:
username `admin`, password `admin` (rotated to site vault password during ingestion).

---

## Fresh Start (Reset Everything)

### 1. Stop running processes

Stop `carbide-api` and `machine-a-tron` (`Ctrl-C` in their terminals).

### 2. Reset database and Vault

```bash
# From infra-controller repo root
docker rm -f pgdev carbide-vault
rm -f /tmp/carbide-localdev-vault-root-token
```

Postgres and Vault data are inside the containers — removing them gives a clean DB.
Migrations re-run automatically on the next `run-carbide-api.sh` start.

### 3. Wipe MAT persistence

```bash
rm -rf /tmp/machine-a-tron-cisco /tmp/mat-cisco.log
```

### 4. (Optional) Regenerate TLS certs

Only if you see certificate expiry errors:

```bash
rm -f dev/certs/localhost/*.crt dev/certs/localhost/*.key
(cd dev/certs/localhost && ./gen-certs.sh)
```

---

## Simulation Steps (From Scratch)

### Terminal 1 — Start carbide-api

```bash
cd infra-controller
./dev/mac-local-dev/run-carbide-api.sh
```

Wait until migrations finish and the API listens on `https://localhost:1079`.

Verify:

```bash
grpcurl -insecure localhost:1079 list
```

### Bootstrap host_inband (zero-DPU — once per fresh DB)

Zero-DPU hosts need a **`host_inband`** network segment (not just `admin`). Create it
after API start:

```bash
./dev/mac-local-dev/bootstrap-host-inband.sh
```

This creates a Flat VPC (`cisco-zero-dpu-flat`) and segment `host-inband`
(`192.168.253.0/24`, gateway `192.168.253.1`). Safe to re-run — skips if the segment
already exists.

`mat-cisco-local.toml` uses `admin_dhcp_relay_address = "192.168.253.1"` so MAT host
PXE DHCP matches that segment.

### Terminal 2 — Start machine-a-tron (Cisco)

```bash
cd infra-controller
./dev/mac-local-dev/run-machine-a-tron-cisco.sh
```

MAT will:

1. Point `site_explorer.bmc_proxy` at `127.0.0.1:2000`
2. Register the expected machine (zero-DPU + host NIC)
3. Start the BMC mock on port **2000**
4. Simulate BMC + host DHCP and open the **TUI**

### Terminal 3 — Monitor (admin CLI)

```bash
cd infra-controller

# Expected machine registered by MAT
./dev/mac-local-dev/run-carbide-admin-cli.sh expected-machine show

# Machine state (wait for Ready)
./dev/mac-local-dev/run-carbide-admin-cli.sh machine show

# Interfaces
./dev/mac-local-dev/run-carbide-admin-cli.sh machine-interfaces show

# Detailed managed-host state + errors
./dev/mac-local-dev/run-carbide-admin-cli.sh managed-host show --all
```

### Ingestion flow (automatic)

Once site-explorer runs, the state machine progresses roughly:

```
Created → DpuDiscoveringState (empty) → HostInit → … → Ready
```

For zero-DPU Cisco, `HostInit` includes:

- `WaitingForPlatformConfiguration`
- `PollingBiosSetup`
- `SetBootOrder` ← requires boot-interface MAC on the host snapshot
- `SpdmMeasuring` / attestation (may be no-op locally)
- `Discovered` → `BomValidating` → `Validation` → **`Ready`**

MAT TUI shows `MachineUp/Unknown` after PXE during ingestion — that is **normal**.
The TUI `api_state=Unknown` column does not reflect the real API state. Use
`machine show` for the authoritative state.

---

## Configuration Reference

### `mat-cisco-local.toml` (key fields)

```toml
carbide_api_url = "https://127.0.0.1:1079"
use_pxe_api = true              # PXE via API, no nico-pxe
bmc_mock_port = 2000
register_expected_machines = true
configure_carbide_bmc_proxy_host = "127.0.0.1"
host_bmc_password = "vault-password"   # site vault BMC password after rotation
persist_dir = "/tmp/machine-a-tron-cisco"

[machines.cisco_ucs]
host_count = 1
dpu_per_host_count = 0          # zero-DPU
hw_type = "cisco_ucs"
cisco_product = "CAI-845A-M8"
cisco_gpu_profile = "mgx_pcie"  # or "hgx_sxm" for C885A
oob_dhcp_relay_address = "192.168.2.1"
# Host PXE relay — gateway of bootstrap-host-inband.sh segment (host_inband, not admin).
admin_dhcp_relay_address = "192.168.253.1"
```

### `carbide-api-config.toml` (key fields)

```toml
[site_explorer]
enabled = true
create_machines = true
allow_zero_dpu_hosts = true
bmc_proxy = ":2000"
allow_changing_bmc_proxy = true
run_interval = "10s"

[networks.admin]
prefix = "192.168.252.0/24"
gateway = "192.168.252.1"
```

Host **`host_inband`** is **not** in this file — run `bootstrap-host-inband.sh` after API
start to create it via the API (Flat VPC + segment).

---

## Known Issues and Workarounds

### `discover_dhcp` / `not of the expected type host_inband`

**Symptom:** MAT TUI stuck at `Init/Unknown` with `not of the expected type host_inband`.

**Fix:** Run `./dev/mac-local-dev/bootstrap-host-inband.sh` after API start, ensure
`admin_dhcp_relay_address = "192.168.253.1"` in `mat-cisco-local.toml`, restart MAT.
For a stuck machine, delete the predicted row and re-DHCP:

```bash
docker exec pgdev psql -U postgres -c \
  "DELETE FROM predicted_machine_interfaces WHERE mac_address = '02:01:00:00:00:02';"
```

Then restart MAT so host PXE DHCP hits the `host_inband` relay.

### Missing boot interface MAC at `SetBootOrder`

**Symptom:** API stuck at `HOSTINITIALIZING/SETBOOTORDER` with
`Missing boot interface MAC for host: <id>`.

**Cause:** Host PXE NIC DHCP'd before it was linked to the machine
(`machine_interfaces.machine_id` empty — orphan interface).

**Fix:** Link the host NIC manually (until DHCP association is re-enabled):

```bash
docker exec pgdev psql -U postgres -c "
UPDATE machine_interfaces
SET machine_id = '<machine-id>',
    association_type = 'Machine',
    primary_interface = true
WHERE mac_address = '02:01:00:00:00:02';

UPDATE machine_interfaces SET primary_interface = false
WHERE mac_address = '02:01:00:00:00:01';
"
```

**Prevention on fresh start:** Start MAT (expected machine with `host_nics`)
*before* the host PXE NIC DHCPs, or delete orphan interfaces when force-deleting
machines.

### Duplicate machine records

If an orphan host NIC gets associated to a *new* machine while the expected
machine keeps the BMC, you end up with two machine IDs. Force-delete the stray
one:

```bash
./dev/mac-local-dev/run-carbide-admin-cli.sh machine force-delete <stray-id> \
  --delete-interfaces --cloud-unsafe-op=$USER
```

### `AvoidLockout` / BMC credential errors

```bash
./dev/mac-local-dev/run-carbide-admin-cli.sh site-explorer clear-error 192.168.2.2
./dev/mac-local-dev/run-carbide-admin-cli.sh credential delete-bmc-root <machine-id>
./dev/mac-local-dev/run-carbide-admin-cli.sh site-explorer refresh-endpoint 192.168.2.2
```

Ensure `host_bmc_password = "vault-password"` in `mat-cisco-local.toml` matches
the site vault BMC password.

### HTTP 200 vs 204 on boot-order PATCH

If you see `HTTP 200 OK at Systems/system: {}` during ingestion, the bmc-mock
fix (`patch_system` → 204) may be missing. Rebuild MAT/bmc-mock from current
sources.

### OS provisioning (tenant instance)

Zero-DPU hosts use a **different** instance allocation path than DPU hosts:

- MAT TUI **`i` key** uses tenant subnet + `auto: false` → **not valid** for zero-DPU
- Use `grpcurl` with `network.auto = true` and empty `interfaces` (see prior
  conversation) once the machine is **`Ready`**
- Full OS install uses the bootstrapped `host-inband` segment in the Flat VPC
  (`bootstrap-host-inband.sh`); tenant overlay is `subnet_*` from MAT if needed

---

## Force-Delete a Machine (Clean Re-ingest)

```bash
MID=<machine-id>

./dev/mac-local-dev/run-carbide-admin-cli.sh machine force-delete "$MID" \
  --delete-interfaces \
  --delete-bmc-interfaces \
  --delete-bmc-credentials \
  --cloud-unsafe-op=$USER

# Clear site-explorer error state for the BMC IP
./dev/mac-local-dev/run-carbide-admin-cli.sh site-explorer clear-error 192.168.2.2

# Wipe MAT persist and restart MAT
rm -rf /tmp/machine-a-tron-cisco
./dev/mac-local-dev/run-machine-a-tron-cisco.sh
```

---

## DevSpace / Kubernetes Path

For in-cluster simulation (not mac-local-dev):

- `dev/deployment/devspace/machine-a-tron.yaml` — MAT deployment with Cisco UCS
- `dev/deployment/devspace/values.base.yaml` — API site config + HCL profiles
- `devspace deploy` — builds and deploys API, BMC proxy, MAT

See `dev/deployment/devspace/README.md` for bootstrap and deploy steps.

---

## Quick Command Reference

| Task | Command |
|------|---------|
| Reset DB | `docker rm -f pgdev carbide-vault` |
| Start API | `./dev/mac-local-dev/run-carbide-api.sh` |
| Start MAT (Cisco) | `./dev/mac-local-dev/run-machine-a-tron-cisco.sh` |
| Bootstrap host_inband | `./dev/mac-local-dev/bootstrap-host-inband.sh` |
| Machine state | `./dev/mac-local-dev/run-carbide-admin-cli.sh machine show <id>` |
| Expected machines | `./dev/mac-local-dev/run-carbide-admin-cli.sh expected-machine show` |
| Interfaces | `./dev/mac-local-dev/run-carbide-admin-cli.sh machine-interfaces show` |
| Managed-host debug | `./dev/mac-local-dev/run-carbide-admin-cli.sh managed-host show <id>` |
| Web UI | `https://localhost:1079/admin` |

---

## Related Files

- Example expected machines: `docs/provisioning/examples/cisco_c845a_expected_machines.json`
- Ingestion overview: `docs/provisioning/ingesting-hosts.md`
- DevSpace Cisco lab: `dev/deployment/devspace/README.md`
- Mac local dev (API): `dev/mac-local-dev/README.md`
