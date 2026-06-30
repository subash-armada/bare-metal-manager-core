# Cisco UCS C845A — Bridge Lab Provisioning Issues Log

Chronological record of issues encountered while bringing up a **Cisco UCS C845A M8
zero-DPU** host on the bridge lab cluster (`labadmin@198.18.199.101`) with
`june25` / `june25-cisco-fix` NICo images.

For the local MAT simulation guide see
[`dev/mac-local-dev/CISCO-UCS-LOCAL-LAB.md`](mac-local-dev/CISCO-UCS-LOCAL-LAB.md).

---

## Lab identity

| Item | Value |
|------|-------|
| Bridge / K8s node | `198.18.199.101` (`labadmin`) |
| BMC | `https://198.18.199.103` — `admin` / `Passw0rd123!` |
| Chassis | `CAI-845A-M8`, serial **`WVT301001H9`** |
| BMC MAC | `10:57:25:2c:41:2c` |
| Host PXE / boot NIC MAC | `30:3e:a7:4d:2b:4c` |
| Host in-band segment | `HOST_INBAND` — `10.20.50.0/24` |
| Host IP (DHCP) | `10.20.50.21/24`, gateway `10.20.50.13` |
| DHCP relay | `10.20.50.12` (`nico-hostinband` netns) |
| Machine ID | `fm100ps7rutprai1d4qlq1cclj7paitilgbdd280pnvgkej5sog8p778leg` |
| Deployed API image | `subashaarna/nvmetal-carbide:june25-cisco-fix` (Cisco libredfish fixes) |

---

## Phase 1 — Platform support (code, pre-lab)

NICo did not support Cisco UCS at the start of this work. The C845A uses an
**AMI MegaRAC BMC with Cisco OEM extensions** (DC-SCM). Redfish probe at
`198.18.199.103` showed good baseline coverage but diverged from Dell/Lenovo AMI
paths in several places.

### 1.1 Vendor not recognized

| Symptom | Site explorer stops; BMC classified as `RedfishVendor::Unknown` |
|---------|------------------------------------------------------------------|
| Cause | No `Cisco` entry in NICo vendor enum / HCL |
| Fix | Added `BMCVendor::Cisco`, `HwType::Cisco`, `RedfishVendor::Cisco`, Cisco hardware module in bmc-explorer |

### 1.2 BIOS profile mismatch (`PollingBiosSetup` stall)

| Symptom | Host stuck polling BIOS setup; diffs never clear |
|---------|--------------------------------------------------|
| Cause | `ami.rs` hardcodes Lenovo-era attrs (`EndlessBoot`, `VMXEN`, `FBO001`, `KCSACP`, …) that **do not exist** on Cisco C845A. Cisco uses `NWSK*` network-stack attrs and different serial-console defaults (`COM0` vs `COM1`) |
| Fix | Cisco branches in `vendor/libredfish/src/ami.rs` and `cisco.rs`: BIOS path `/Systems/system/Bios/Settings` (not AMI `/Bios/SD`), skip missing attrs, map `AutomaticRetryConfig` for infinite boot |

### 1.3 Lockdown not supported on Cisco

| Symptom | Would stall at `WaitingForLockdown` |
|---------|-------------------------------------|
| Cause | Cisco BMC missing `KCSACP`; `HostInterfaces` returns 404 — AMI lockdown path unusable |
| Fix (lab) | `disable_lockdown: true` on expected machine + `lockdown_status()` returns `NotSupported` for Cisco |
| Production follow-up | Implement Cisco-specific lockdown when requirements are defined |

### 1.4 Boot order / Redfish response quirks

| Issue | Detail | Fix |
|-------|--------|-----|
| Boot order PATCH body | Cisco expects empty body on success, not `{}` | Handle 200/204 correctly in libredfish |
| Automatic retry | C845A rejects `AutomaticRetryAttempts`; uses `AutomaticRetryConfig: RetryAttempts` only | `vendor/libredfish/src/cisco.rs` |
| Network interface PATCH | Cisco returns 200 where other vendors return 204 | `vendor/libredfish/src/network.rs` |

### 1.5 Zero-DPU site config

| Requirement | Setting |
|-------------|---------|
| Allow hosts without DPU | `allow_zero_dpu_hosts = true` in site config |
| Expected machine | `dpu_mode: "no_dpu"`, chassis serial, BMC credentials |
| Boot NIC declaration | `host_nics[]` with `primary: true` (see Phase 2) |

---

## Phase 2 — Local MAT lab (mac-local-dev)

Before touching the bridge cluster, Cisco behavior was exercised with
`carbide-api` + `machine-a-tron` + `bmc-mock` (Cisco UCS profile).

### 2.1 `Missing boot interface MAC` at `SetBootOrder`

| Symptom | `State handler error: Missing boot interface MAC for host: fm100…` |
|---------|---------------------------------------------------------------------|
| Cause | Zero-DPU hosts have no DPU to supply a primary interface. Expected machine had BMC MAC but **empty `host_nics`**. Host PXE NIC existed in DB but was **orphaned** (no `machine_id`) |
| Fix | Expected machine must include: |

```json
"host_nics": [
  {
    "mac_address": "30:3e:a7:4d:2b:4c",
    "nic_type": "onboard",
    "primary": true
  }
]
```

| Workaround (one-off) | Manually `UPDATE machine_interfaces SET machine_id=…, primary_interface=true` in Postgres |
| Code improvement | MAT `register_expected_machine()` upserts `host_nics` for zero-DPU mocks |

### 2.2 Site explorer `avoid_lockout`

| Symptom | `Site explorer will not explore this endpoint to avoid lockout: it could not login previously` |
|---------|-----------------------------------------------------------------------------------------------|
| Cause | Prior BMC auth failures (401 / wrong password) set lockout state |
| Impact | Blocks periodic re-exploration; **state controller still runs** |
| Fix | Clear site-explorer error state; ensure site-wide BMC password matches |

### 2.3 MAT TUI shows `MachineUp/Unknown`

| Symptom | TUI column `api_state=Unknown` after successful PXE in mock |
|---------|-------------------------------------------------------------|
| Cause | MAT sim completes PXE locally; does not poll real API scout/measured-boot states |
| Note | **Not a failure** — use `carbide-admin-cli machine show` for authoritative API state |

---

## Phase 3 — Bridge lab deployment (`198.18.199.101`)

### 3.1 Image rollout

| Item | Notes |
|------|-------|
| Built / pushed | `subashaarna/nvmetal-carbide:june25`, `boot-artifacts-x86_64:june25`, `machine-validation-config:june25` |
| API with Cisco fixes | `june25-cisco-fix` branch — fast rebuild via `dev/bin/build-nvmetal-carbide-api-only.sh` |
| Constraint | Avoid full `helm upgrade` on lab — can reset image tags to older values |

Helm values on lab still referenced some `june18` boot-artifact tags while API
was updated separately.

### 3.2 Expected machine JSON (real hardware)

```json
{
  "bmc_mac_address": "10:57:25:2c:41:2c",
  "bmc_username": "admin",
  "bmc_password": "Passw0rd123!",
  "chassis_serial_number": "WVT301001H9",
  "dpu_mode": "no_dpu",
  "host_nics": [
    {
      "mac_address": "30:3e:a7:4d:2b:4c",
      "nic_type": "onboard",
      "primary": true
    }
  ],
  "host_lifecycle_profile": {
    "disable_lockdown": true
  }
}
```

Host boot NIC MAC confirmed from BMC Redfish (`OCP_NIC` adapter).

### 3.3 `SetBootOrder` — Cisco compact MAC format

| Symptom | Boot order configuration could not match HTTP boot option to host NIC |
|---------|-----------------------------------------------------------------------|
| Cause | Cisco BootOptions use compact alias form `MAC:303EA74D2B4C` (no separators), not `30:3e:a7:4d:2b:4c` |
| Fix | MAC matching in `vendor/libredfish/src/ami.rs` accepts compact Cisco form; ensure host interface is linked to machine with `primary_interface=true` |

### 3.4 BMC discovery → machine creation

| Step | Status |
|------|--------|
| BMC discovery via site explorer | Done |
| Expected machine match | Done |
| BIOS setup / infinite boot | Done |
| Boot order → HTTP boot option | Done (after MAC fix) |

---

## Phase 4 — PXE / Scout boot (current focus)

### 4.1 PXE path working

Confirmed sequence on host (`10.20.50.21`):

1. UEFI loads `ipxe.efi` from `http://10.20.50.3:8080/...` — **200 OK**
2. iPXE chains to `/api/v0/pxe/boot` — needs `remote_ip=10.20.50.21` (host in-band), not bridge SNAT `10.0.0.236`
3. API returns scout kernel script → host downloads `scout.efi` — **200 OK**
4. Machine state → **`WaitingForMeasurements`** (waiting for Scout measured boot)

`autoexec.ipxe` 404 is **harmless** — boot script is embedded in `ipxe.efi`.

### 4.2 Scout `scout.squashfs` download failure — DNS

| Symptom | Scout console: `curl: (6) Could not resolve host: carbide-static-pxe.forge` |
|---------|-------------------------------------------------------------------------------|
| Cause | Scout loader hardcodes `http://carbide-static-pxe.forge/public/blobs/internal/${arch}/scout.squashfs` (port **80**) in `pxe/common_files/scout-loader-rclocal`. DHCP nameservers pointed at **nico-dns** (`10.20.50.1`, `10.20.50.2`) which is authoritative only — does **not** resolve `.forge` names. **Unbound** (recursive resolver with static forge records) was **disabled** (`unbound.enabled: false`) |
| Why not “fix nico-dns”? | nico-dns is API-driven authoritative DNS for site/VPC zones — not a recursive resolver with static boot hostnames. By design |
| Fix applied | **`forge-dns`** — lightweight CoreDNS at `10.20.50.5` with static forge A-records; DHCP nameservers patched to `10.20.50.5` (kubectl only, no helm upgrade) |
| Long-term fix | Enable unbound subchart; add missing `carbide-static-pxe.forge` to `local-data.conf.j2`; point DHCP at unbound |

### 4.3 Scout `scout.squashfs` download failure — port 80

| Symptom | Even with DNS fixed, URL uses port 80; `nico-pxe-external-80` was `<pending>` |
|---------|--------------------------------------------------------------------------------|
| Cause | Service annotated for `10.20.40.3` which is **outside** MetalLB pool (`10.20.50.0/24` only) |
| Fix applied | Annotate `nico-pxe-external-80` with shared IP `10.20.50.3` + `allow-shared-ip: nico-pxe` |
| Verified | `curl -sI http://10.20.50.3/public/blobs/internal/x86_64/scout.squashfs` → **200 OK** on port 80 |

### 4.4 PXE env overrides (workaround, optional to revert)

ConfigMap `nico-pxe-env-config` was patched with direct IPs:

```
CARBIDE_PXE_URL=http://10.20.50.3:8080
CARBIDE_STATIC_PXE_URL=http://10.20.50.3:8080
CARBIDE_API_URL=https://10.20.50.4:443
```

These bypass forge DNS for PXE service URLs but **do not** help Scout loader
(built into boot image, not runtime env). Can revert once DNS is stable.

---

## Phase 5 — Operational incidents during debugging

### 5.1 API site config corruption

| Symptom | `nico-api` CrashLoop: `No resource pools defined` |
|---------|---------------------------------------------------|
| Cause | Bad patch wiped `carbide-api-site-config.toml` (pools/networks removed) |
| Fix | Restored from backup / `nico-api-site-config.toml` ConfigMap |

**Lesson:** Avoid ad-hoc ConfigMap patches on site config; always backup first.

### 5.2 `fnn.admin_vpc` enabled without admin segments

| Symptom | API CrashLoop after restart: missing `network_segment_type = 'admin'` rows in DB |
|---------|-----------------------------------------------------------------------------------|
| Fix | Set `[fnn.admin_vpc] enabled = false` in site config until admin network exists |
| Note | Do **not** re-enable until admin network segments are provisioned in DB |

### 5.3 MetalLB VIP pool mismatches

Several external services target **`10.20.40.x`** while the lab pool is only
**`10.20.50.0/24`**:

| Service | Configured IP | Status |
|---------|---------------|--------|
| `nico-api-external` | `10.20.40.1` | `<pending>` |
| `nico-dhcp-external` | `10.20.40.2` | Assigned (legacy /32 in pool?) |
| `nico-pxe-external-80` | `10.20.40.3` | Was `<pending>` — **fixed** to `10.20.50.3` |
| `nico-ssh-console-rs-external` | `10.20.40.4` | `<pending>` |

PXE at `10.20.50.3:8080` and `:80` works. API external VIP still pending —
may affect `carbide-api.forge` resolution later.

### 5.4 Bridge curl tests vs host traffic

| Pattern | Meaning |
|---------|---------|
| `remote_ip=10.20.50.21 … /api/v0/pxe/boot … 200` | **Good** — real host PXE |
| `remote_ip=10.0.0.236 … Client not found` | **Ignore** — bridge node SNAT, not the host |

---

## Current status (as of last session)

| Phase | Status |
|-------|--------|
| BMC discovery, machine creation | Done |
| BIOS setup, boot order | Done |
| PXE / iPXE / scout.efi download | Done |
| Port 80 on PXE VIP | **Fixed** |
| DNS for `carbide-static-pxe.forge` | **Fixed** (`forge-dns` at `10.20.50.5`) |
| DHCP nameservers → forge-dns | **Patched** |
| Host DHCP renew / reboot | **Pending** — host must pick up new nameserver |
| Scout `scout.squashfs` download | **Expected to work after host reboot** |
| `WaitingForMeasurements` → next states | **Blocked until Scout completes** |
| `nico-api-external` VIP | Still `<pending>` at `10.20.40.1` |
| Boot artifact image tags in helm | Still mix of `june18` / `june25` |

---

## Open / follow-up items

1. **Reboot Cisco host** and confirm Scout downloads `scout.squashfs` and submits measurements.
2. **Attestation** — if `attestation_enabled = true`, approve TPM measurements via admin-cli; for lab can set `attestation_enabled = false` to skip `WaitingForMeasurements`.
3. **Replace `forge-dns` with unbound** when a proper helm/unbound deploy is acceptable (add `carbide-static-pxe.forge` to local-data template).
4. **Fix MetalLB VIP assignments** — align all external services to `10.20.50.0/24` pool or expand pool to include `10.20.40.0/24`.
5. **Persist helm values** for `nico-pxe-external-80` → `10.20.50.3` (currently kubectl annotation only).
6. **Auto-link preallocated host NIC** to machine during DHCP discover (optional code fix — avoids manual DB link for zero-DPU).
7. **Cisco lockdown** — production path still TBD.
8. **Revert `nico-pxe-env-config` IP overrides** once forge DNS is stable.

---

## Key log patterns

```bash
# Good — host PXE on bridge
kubectl logs -n nico-system deploy/nico-pxe -f | grep '10.20.50.21'

# Expected after reboot
remote_ip=10.20.50.21 ... /api/v0/pxe/boot ... 200
remote_ip=10.20.50.21 ... /scout.efi ... 200
# then scout.squashfs via carbide-static-pxe.forge:80

# DNS verify
host carbide-static-pxe.forge 10.20.50.5

# HTTP verify
curl -sI http://10.20.50.3/public/blobs/internal/x86_64/scout.squashfs
curl -sI http://carbide-static-pxe.forge/public/blobs/internal/x86_64/scout.squashfs
```

---

## Code changes reference (branch `june25-cisco-fix`)

| File | Change |
|------|--------|
| `vendor/libredfish/src/ami.rs` | Cisco BIOS `/Settings`, compact MAC boot-option matching |
| `vendor/libredfish/src/cisco.rs` | `AutomaticRetryConfig` / lockdown `NotSupported` |
| `vendor/libredfish/src/network.rs` | PATCH 200 success on Cisco |
| `dev/bin/build-nvmetal-carbide-api-only.sh` | Fast API-only image rebuild |
| `crates/machine-a-tron/...` | Expected machine `host_nics` registration (MAT lab) |

---

## Related docs

- [`dev/mac-local-dev/CISCO-UCS-LOCAL-LAB.md`](mac-local-dev/CISCO-UCS-LOCAL-LAB.md) — MAT simulation guide
- [`deploy/DNS.md`](../deploy/DNS.md) — `.nico` DNS zone reference (modern naming; lab still uses legacy `.forge` in scout boot scripts)
- [`docs/development/new_hardware_support.md`](../docs/development/new_hardware_support.md) — adding new BMC vendors
