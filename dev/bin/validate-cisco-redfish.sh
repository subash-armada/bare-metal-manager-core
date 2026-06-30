#!/usr/bin/env bash
# Validate Cisco UCS C845A Redfish against NICo libredfish expectations.
set -euo pipefail

BMC="${BMC_URL:-https://198.18.199.103}"
AUTH="${BMC_USER:-admin}:${BMC_PASS:-Passw0rd123!@}"
HOST_MAC="${HOST_MAC:-30:3e:a7:4d:2b:4c}"

rf_get() { curl -sk -u "$AUTH" "$BMC/$1" -w '\n%{http_code}'; }
rf_patch() { curl -sk -u "$AUTH" -X PATCH -H 'If-Match: *' -H 'Content-Type: application/json' -d "$2" "$BMC/$1" -w '\n%{http_code}'; }

pass=0; warn=0; fail=0
ok()   { echo "  OK   $*"; pass=$((pass+1)); }
w()    { echo "  WARN $*"; warn=$((warn+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }

check_get() {
  local path="$1" expect="${2:-200}"
  local out code
  out=$(rf_get "$path")
  code=$(echo "$out" | tail -1)
  if [[ "$code" == "$expect" ]]; then ok "GET $path -> $code"; else bad "GET $path -> $code (expected $expect)"; fi
}

echo "Validating Cisco Redfish at $BMC"
echo

echo "=== GET endpoints ==="
check_get redfish/v1/
check_get redfish/v1/Systems/system
check_get redfish/v1/Systems/system/Bios
check_get redfish/v1/Systems/system/Bios/Settings
check_get redfish/v1/Systems/system/Bios/SD 404
check_get redfish/v1/Systems/system/SD
check_get redfish/v1/Systems/system/BootOptions
check_get redfish/v1/Systems/system/EthernetInterfaces 404
check_get redfish/v1/Managers/bmc
check_get redfish/v1/Chassis
check_get redfish/v1/AccountService
check_get redfish/v1/UpdateService

echo
echo "=== BIOS attributes ==="
curl -sk -u "$AUTH" "$BMC/redfish/v1/Systems/system/Bios" | python3 - <<'PY' "$HOST_MAC"
import json,sys
host_mac=sys.argv[1].upper()
d=json.load(sys.stdin)
so=d.get("@Redfish.Settings",{}).get("SettingsObject",{}).get("@odata.id","")
expected={
  "NWSK000":"Enabled","NWSK001":"Enabled","NWSK006":"Enabled",
  "NWSK002":"Disabled","NWSK007":"Disabled",
  "TER001":"Enabled","TER010":"Enabled","TER06B":"COM0",
  "TER0021":"115200","TER0020":"115200","TER012":"ANSI",
  "TER011":"VT-UTF8","TER05D":"None","TCG006":None,
}
attrs=d.get("Attributes",{})
print(f"SettingsObject: {so}")
if "/Bios/Settings" in so: print("OK   Bios uses /Settings")
else: print(f"FAIL Bios SettingsObject unexpected: {so}")
for k in expected:
    if k not in attrs: print(f"FAIL missing BIOS attr {k}")
    elif expected[k] and attrs[k]!=expected[k]: print(f"WARN {k}={attrs[k]!r} want {expected[k]!r}")
    else: print(f"OK   {k}={attrs[k]!r}")
PY

echo
echo "=== Boot options for host MAC ==="
curl -sk -u "$AUTH" "$BMC/redfish/v1/Systems/system/BootOptions" | python3 - <<'PY' "$AUTH" "$BMC" "$HOST_MAC"
import json,sys,subprocess
auth,bmc,mac=sys.argv[1],sys.argv[2],sys.argv[3].upper().replace(":","")
d=json.load(sys.stdin)
found=[]
for m in d.get("Members",[]):
    path=m["@odata.id"].split("/redfish/v1/")[-1]
    out=subprocess.check_output(["curl","-sk","-u",auth,f"{bmc}/{path}"])
    opt=json.loads(out)
    name=(opt.get("DisplayName") or "").upper()
    if mac in name.replace(":",""):
        found.append(f"{opt.get('BootOptionReference')}: {opt.get('DisplayName')}")
if found:
    for f in found: print(f"OK   host boot option {f}")
else:
    print(f"FAIL no boot option for MAC {sys.argv[3]}")
PY

echo
echo "=== PATCH probes ==="
code=$(rf_patch redfish/v1/Systems/system/Bios/Settings '{"Attributes":{"NWSK000":"Enabled","NWSK001":"Enabled","NWSK006":"Enabled","NWSK002":"Disabled","NWSK007":"Disabled"}}' | tail -1)
[[ "$code" == "200" || "$code" == "204" ]] && ok "PATCH Bios/Settings machine attrs -> $code" || bad "PATCH Bios/Settings machine attrs -> $code"

code=$(rf_patch redfish/v1/Systems/system '{"Boot":{"AutomaticRetryConfig":"RetryAttempts"}}' | tail -1)
[[ "$code" == "200" || "$code" == "204" ]] && ok "PATCH Systems/system AutomaticRetryConfig -> $code" || bad "PATCH Systems/system AutomaticRetryConfig -> $code"

code=$(rf_patch redfish/v1/Systems/system '{"Boot":{"AutomaticRetryConfig":"RetryAttempts","AutomaticRetryAttempts":999}}' | tail -1)
[[ "$code" == "500" ]] && ok "PATCH with AutomaticRetryAttempts rejected -> $code (C845A quirk)" || w "PATCH with AutomaticRetryAttempts -> $code (expected 500)"

code=$(rf_patch redfish/v1/AccountService '{"AccountLockoutThreshold":0,"AccountLockoutDuration":0}' | tail -1)
[[ "$code" == "200" || "$code" == "204" ]] && ok "PATCH AccountService -> $code" || bad "PATCH AccountService -> $code"

code=$(rf_patch redfish/v1/AccountService '{"AccountLockoutCounterResetAfter":0}' | tail -1)
[[ "$code" == "400" ]] && ok "PATCH AccountService CounterResetAfter rejected -> $code" || w "PATCH CounterResetAfter -> $code"

code=$(rf_patch redfish/v1/Systems/system/SD '{"Boot":{"BootOrder":["Boot0001"]}}' | tail -1)
[[ "$code" == "200" || "$code" == "204" ]] && ok "PATCH Systems/system/SD BootOrder -> $code" || bad "PATCH Systems/system/SD -> $code"

echo
echo "Summary: $pass ok, $warn warn, $fail fail"
[[ "$fail" -eq 0 ]]
