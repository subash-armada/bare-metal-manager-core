#!/usr/bin/env python3
"""Validate Cisco UCS C845A Redfish endpoints against NICo libredfish expectations."""
from __future__ import annotations

import json
import os
import sys
import urllib.request
import ssl
from dataclasses import dataclass, field
from typing import Any

BMC = os.environ.get("BMC_URL", "https://198.18.199.103")
USER = os.environ.get("BMC_USER", "admin")
PASS = os.environ.get("BMC_PASS", "Passw0rd123!@")
HOST_MAC = os.environ.get("HOST_MAC", "30:3e:a7:4d:2b:4c").upper()
DRY_PATCH = os.environ.get("DRY_PATCH", "1") == "1"

MACHINE_SETUP_ATTRS = {
    "NWSK000": "Enabled",
    "NWSK001": "Enabled",
    "NWSK006": "Enabled",
    "NWSK002": "Disabled",
    "NWSK007": "Disabled",
}

SERIAL_CONSOLE_ATTRS = {
    "TER001": "Enabled",
    "TER010": "Enabled",
    "TER06B": "COM0",
    "TER0021": "115200",
    "TER0020": "115200",
    "TER012": "ANSI",
    "TER011": "VT-UTF8",
    "TER05D": "None",
}

GET_PATHS = [
    "redfish/v1/",
    "redfish/v1/Systems",
    "redfish/v1/Systems/system",
    "redfish/v1/Systems/system/Bios",
    "redfish/v1/Systems/system/Bios/Settings",
    "redfish/v1/Systems/system/Bios/SD",
    "redfish/v1/Systems/system/SD",
    "redfish/v1/Systems/system/BootOptions",
    "redfish/v1/Systems/system/EthernetInterfaces",
    "redfish/v1/Managers",
    "redfish/v1/Managers/bmc",
    "redfish/v1/Managers/Self",
    "redfish/v1/Chassis",
    "redfish/v1/AccountService",
    "redfish/v1/UpdateService",
]

@dataclass
class Result:
    ok: list[str] = field(default_factory=list)
    warn: list[str] = field(default_factory=list)
    fail: list[str] = field(default_factory=list)


def req(method: str, path: str, body: dict | None = None, headers: dict | None = None) -> tuple[int, dict | str, dict]:
    url = f"{BMC.rstrip('/')}/{path.lstrip('/')}"
    data = None
    hdrs = {"Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    pw_mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    pw_mgr.add_password(None, BMC, USER, PASS)
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPBasicAuthHandler(pw_mgr))
    try:
        with opener.open(request, timeout=60) as resp:
            raw = resp.read().decode()
            rh = dict(resp.headers)
            try:
                return resp.status, json.loads(raw), rh
            except json.JSONDecodeError:
                return resp.status, raw, rh
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw), dict(e.headers)
        except json.JSONDecodeError:
            return e.code, raw, dict(e.headers)


def etag(headers: dict) -> str | None:
    for k, v in headers.items():
        if k.lower() == "etag":
            return v.strip('"')
    return None


def main() -> int:
    r = Result()
    print(f"Validating Cisco Redfish at {BMC} (DRY_PATCH={DRY_PATCH})\n")

    # --- GET probes ---
    bodies: dict[str, Any] = {}
    for path in GET_PATHS:
        code, body, _ = req("GET", path)
        if code == 200:
            r.ok.append(f"GET {path} -> 200")
            bodies[path] = body
        elif code == 404:
            r.fail.append(f"GET {path} -> 404")
        else:
            r.warn.append(f"GET {path} -> {code}")

    bios = bodies.get("redfish/v1/Systems/system/Bios", {})
    attrs = bios.get("Attributes", {}) if isinstance(bios, dict) else {}
    settings_obj = bios.get("@Redfish.Settings", {}).get("SettingsObject", {}).get("@odata.id", "")

    if "/Bios/Settings" in settings_obj:
        r.ok.append(f"Bios SettingsObject -> {settings_obj}")
    elif "/Bios/SD" in settings_obj:
        r.warn.append(f"Bios SettingsObject uses /SD: {settings_obj}")
    else:
        r.fail.append(f"Unexpected Bios SettingsObject: {settings_obj!r}")

    system = bodies.get("redfish/v1/Systems/system", {})
    sys_settings = system.get("@Redfish.Settings", {}).get("SettingsObject", {}).get("@odata.id", "")
    boot = system.get("Boot", {})
    print(f"System Boot: AutomaticRetryConfig={boot.get('AutomaticRetryConfig')} "
          f"Attempts={boot.get('AutomaticRetryAttempts')} Settings={sys_settings}")

    # --- BIOS attribute keys ---
    all_expected = {**MACHINE_SETUP_ATTRS, **SERIAL_CONSOLE_ATTRS, "TCG006": "TPM Clear"}
    for key, expected in all_expected.items():
        if key not in attrs:
            r.fail.append(f"BIOS attr missing: {key}")
        else:
            actual = attrs[key]
            if key == "TCG006":
                r.ok.append(f"BIOS attr {key} present (current={actual!r})")
            elif actual == expected:
                r.ok.append(f"BIOS attr {key}={actual!r} (already expected)")
            else:
                r.warn.append(f"BIOS attr {key}: current={actual!r}, expected={expected!r}")

    # --- Boot options ---
    code, boot_coll, _ = req("GET", "redfish/v1/Systems/system/BootOptions")
    if code == 200 and isinstance(boot_coll, dict):
        members = boot_coll.get("Members", [])
        r.ok.append(f"BootOptions collection: {len(members)} entries")
        pxe_matches = []
        for m in members:
            odata = m.get("@odata.id", "")
            if not odata:
                continue
            seg = odata.split("/redfish/v1/")[-1]
            c, opt, _ = req("GET", seg)
            if c != 200 or not isinstance(opt, dict):
                continue
            name = opt.get("DisplayName", opt.get("Name", ""))
            ref = opt.get("BootOptionReference", "")
            if HOST_MAC.replace(":", "") in name.upper().replace(":", "") or HOST_MAC in name.upper():
                pxe_matches.append(f"{ref}: {name}")
            if any(x in name.upper() for x in ("PXE", "HTTP", "NETWORK")) and "IPV4" in name.upper():
                r.ok.append(f"  boot option {ref}: {name}")
        if pxe_matches:
            r.ok.append(f"Boot options matching host MAC {HOST_MAC}: {pxe_matches}")
        else:
            r.warn.append(f"No boot option name contains host MAC {HOST_MAC} (may use alias matching)")

    # --- PATCH probes (dry-run: PATCH current values or minimal safe changes) ---
    if DRY_PATCH:
        print("\n--- PATCH validation (non-destructive: re-apply current/safe values) ---")

        # Bios/Settings path
        bios_path = "redfish/v1/Systems/system/Bios/Settings"
        code, _, hdrs = req("GET", bios_path)
        if code != 200:
            r.fail.append(f"Cannot GET {bios_path} for If-Match")
        else:
            et = etag(hdrs)
            if not et:
                r.warn.append(f"No ETag on {bios_path} (If-Match may fail)")
            # serial console - patch current values only
            patch_attrs = {k: attrs[k] for k in SERIAL_CONSOLE_ATTRS if k in attrs}
            if patch_attrs:
                code, body, _ = req(
                    "PATCH",
                    bios_path,
                    {"Attributes": patch_attrs},
                    {"If-Match": et or "*"},
                )
                if code in (200, 204):
                    r.ok.append(f"PATCH {bios_path} serial-console attrs -> {code}")
                else:
                    r.fail.append(f"PATCH {bios_path} serial-console -> {code}: {body}")

            # machine setup attrs
            patch_attrs = {k: v for k, v in MACHINE_SETUP_ATTRS.items() if k in attrs}
            if patch_attrs:
                code, body, _ = req(
                    "PATCH",
                    bios_path,
                    {"Attributes": patch_attrs},
                    {"If-Match": et or "*"},
                )
                if code in (200, 204):
                    r.ok.append(f"PATCH {bios_path} machine-setup attrs -> {code}")
                else:
                    r.fail.append(f"PATCH {bios_path} machine-setup -> {code}: {body}")

            # TPM clear - only if not already clearing; skip actual clear in dry run
            if "TCG006" in attrs and attrs["TCG006"] != "TPM Clear":
                r.warn.append("TCG006 would need PATCH to 'TPM Clear' during machine_setup")

        # AutomaticRetryConfig on Systems/system (not SD)
        code, _, hdrs = req("GET", "redfish/v1/Systems/system")
        et = etag(hdrs)
        code, body, _ = req(
            "PATCH",
            "redfish/v1/Systems/system",
            {"Boot": {"AutomaticRetryConfig": "RetryAttempts", "AutomaticRetryAttempts": 999}},
            {"If-Match": et or "*"},
        )
        if code in (200, 204):
            r.ok.append(f"PATCH Systems/system AutomaticRetryConfig -> {code}")
        else:
            r.fail.append(f"PATCH Systems/system AutomaticRetryConfig -> {code}: {body}")

        # AccountService password policy (Cisco: no AccountLockoutCounterResetAfter)
        code, _, hdrs = req("GET", "redfish/v1/AccountService")
        et = etag(hdrs)
        code, body, _ = req(
            "PATCH",
            "redfish/v1/AccountService",
            {"AccountLockoutThreshold": 0, "AccountLockoutDuration": 0},
            {"If-Match": et or "*"},
        )
        if code in (200, 204):
            r.ok.append(f"PATCH AccountService (no CounterResetAfter) -> {code}")
        else:
            r.fail.append(f"PATCH AccountService -> {code}: {body}")

        # With CounterResetAfter (should fail on Cisco)
        code2, body2, _ = req(
            "PATCH",
            "redfish/v1/AccountService",
            {
                "AccountLockoutThreshold": 0,
                "AccountLockoutDuration": 0,
                "AccountLockoutCounterResetAfter": 0,
            },
            {"If-Match": et or "*"},
        )
        if code2 >= 400:
            r.ok.append(f"PATCH AccountService WITH CounterResetAfter rejected -> {code2} (expected)")
        else:
            r.warn.append(f"PATCH AccountService WITH CounterResetAfter -> {code2} (unexpected success)")

        # Boot order via Systems/system/SD
        code, sd_body, hdrs = req("GET", "redfish/v1/Systems/system/SD")
        if code == 200 and isinstance(sd_body, dict):
            et = etag(hdrs)
            order = system.get("Boot", {}).get("BootOrder", [])
            if order:
                code, body, _ = req(
                    "PATCH",
                    "redfish/v1/Systems/system/SD",
                    {"Boot": {"BootOrder": order}},
                    {"If-Match": et or "*"},
                )
                if code in (200, 204):
                    r.ok.append(f"PATCH Systems/system/SD BootOrder (no-op) -> {code}")
                else:
                    r.fail.append(f"PATCH Systems/system/SD -> {code}: {body}")
            else:
                r.warn.append("No BootOrder to test Systems/system/SD PATCH")
        else:
            r.fail.append(f"GET Systems/system/SD -> {code}")

        # Bios/SD should 404 on Cisco
        code, _, _ = req("GET", "redfish/v1/Systems/system/Bios/SD")
        if code == 404:
            r.ok.append("GET Bios/SD -> 404 (confirms Settings path required)")
        else:
            r.warn.append(f"GET Bios/SD -> {code} (expected 404 on C845A)")

    # --- Report ---
    print("\n=== PASS ===")
    for line in r.ok:
        print(f"  OK  {line}")
    print("\n=== WARN ===")
    for line in r.warn:
        print(f"  WARN {line}")
    print("\n=== FAIL ===")
    for line in r.fail:
        print(f"  FAIL {line}")

    print(f"\nSummary: {len(r.ok)} ok, {len(r.warn)} warn, {len(r.fail)} fail")
    return 1 if r.fail else 0


if __name__ == "__main__":
    sys.exit(main())
