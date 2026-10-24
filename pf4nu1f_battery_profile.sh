#!/usr/bin/env bash
# One-time, manually operated Healthy <-> High switch for MECHREVO S2 Air PF4NU1F.
# This writes EC state through the already-present ACPI debugger. It is not a
# daily-use service and must NOT be installed for autostart.
#
# Usage (on the target laptop):
#   sudo bash pf4nu1f_battery_profile.sh healthy
#   sudo bash pf4nu1f_battery_profile.sh high
#
# `healthy` deliberately leaves AP-present=1 while Healthy is active. Run `high`
# before unplugging DC-in, suspending, rebooting, or ending the manual test.
# The state marker permits only one Healthy -> High cycle. Do not delete/reset it.

set -u
set -o pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly EXPECTED_KERNEL='7.0.0-38-generic'
readonly EXPECTED_DSDT_SHA256='fd494f161f47e4bc6919bcd933b2e4bbc97edcb8e00399d10cbf926fecc07e24'
readonly STATE_DIR='/var/lib/pf4nu1f-battery-profile-test'
readonly STATE_FILE="$STATE_DIR/state"
readonly LOCK_FILE='/run/lock/pf4nu1f-battery-profile-test.lock'
readonly ACPI_DBG='/usr/bin/acpidbg'
readonly MAX_WRITES=5

MODE="${1:-}"
ACPI_OUT=''
EC_VALUE=''
STATE_STAGE=''
STATE_WRITES=0

fail() { printf 'Refusing/stopping: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
One-time manual battery profile switch for MECHREVO S2 Air PF4NU1F (writes to the EC)

  sudo bash $SCRIPT_NAME healthy   Select OEM Healthy and keep AP-present=1
  sudo bash $SCRIPT_NAME high      Restore OEM High Capacity and clear AP-present

Supported only on PF4NU1F / BIOS N.1.07MRO05 / EC 1.4 / kernel $EXPECTED_KERNEL.
Only the original DC-in adapter was observed. AC0 cannot distinguish DC-in from USB-C PD; do not use with PD.
This tool does not load modules, run in the background, or start at boot.
EOF
}

[[ "$MODE" == '-h' || "$MODE" == '--help' || -z "$MODE" ]] && { usage; exit 0; }
[[ "$MODE" == 'healthy' || "$MODE" == 'high' ]] || { usage >&2; exit 2; }

[[ "$EUID" -eq 0 ]] || fail 'Run with sudo.'
command -v timeout >/dev/null 2>&1 || fail 'The timeout command is missing.'
command -v flock >/dev/null 2>&1 || fail 'The flock command is missing.'
[[ -x "$ACPI_DBG" ]] || fail "Cannot execute $ACPI_DBG."
[[ -r /sys/kernel/debug/acpi/acpidbg ]] || fail 'The existing ACPI debugger is not readable; no module will be loaded.'
[[ "$(uname -r)" == "$EXPECTED_KERNEL" ]] || fail 'Kernel version does not match the reviewed snapshot.'

for pair in \
  'sys_vendor|MECHREVO' \
  'product_name|S2 Air Series PF4NU1F' \
  'board_name|PF4NU1F' \
  'bios_version|N.1.07MRO05' \
  'ec_firmware_release|1.4'; do
  key=${pair%%|*}; expected=${pair#*|}
  file="/sys/class/dmi/id/$key"
  [[ -r "$file" ]] || fail "Missing DMI field: $key."
  actual=$(<"$file")
  [[ "$actual" == "$expected" ]] || fail "DMI mismatch: $key=$actual."
done

actual_dsdt=$(sha256sum /sys/firmware/acpi/tables/DSDT 2>/dev/null | awk '{print $1}')
[[ "$actual_dsdt" == "$EXPECTED_DSDT_SHA256" ]] || fail 'DSDT hash does not match the reviewed snapshot.'

for module in pf4nu1f_balanced_test uniwill_laptop uniwill_acpi uniwill_wmi \
              tuxedo_keyboard tuxedo_io acpi_call ec_sys; do
  [[ ! -e "/sys/module/$module" ]] || fail "Conflicting kernel module found: $module."
done
for comm in /proc/[0-9]*/comm; do
  [[ -r "$comm" ]] || continue
  name=$(<"$comm")
  case "${name,,}" in
    gcuservice.exe|controlcenteru|tuxedo-control-c|uucc-helper)
      fail "A possibly conflicting OEM control process is running: $name." ;;
  esac
done

mkdir -p /run/lock 2>/dev/null || fail 'Cannot access /run/lock.'
exec 9>"$LOCK_FILE" || fail 'Cannot create the operation lock.'
flock -n 9 || fail 'Another profile operation is running.'

check_power_healthy() {
  local ac status capacity current voltage temp
  ac=$(</sys/class/power_supply/AC0/online) || fail 'Cannot read AC0 status.'
  [[ "$ac" == 1 ]] || fail 'AC0 is offline; the test requires external power.'
  status=$(</sys/class/power_supply/BAT0/status) || fail 'Cannot read battery status.'
  [[ "$status" == 'Charging' ]] || fail "An active charging baseline is required; current status=$status."
  capacity=$(</sys/class/power_supply/BAT0/capacity) || fail 'Cannot read battery capacity.'
  current=$(</sys/class/power_supply/BAT0/current_now) || fail 'Cannot read battery current.'
  voltage=$(</sys/class/power_supply/BAT0/voltage_now) || fail 'Cannot read battery voltage.'
  [[ "$capacity" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ && "$voltage" =~ ^[0-9]+$ ]] || fail 'Invalid power-supply data.'
  (( 10#$capacity >= 70 && 10#$capacity <= 100 )) || fail 'SOC is outside the reviewed 70-100% range.'
  (( 10#$current >= 100000 && 10#$current <= 2500000 )) || fail 'No valid positive charging baseline (required: 100 mA-2.5 A).'
  (( 10#$voltage >= 11500000 && 10#$voltage <= 13050000 )) || fail 'Battery voltage is outside the reviewed range.'
  if [[ -r /sys/class/power_supply/BAT0/temp ]]; then
    temp=$(</sys/class/power_supply/BAT0/temp)
    [[ "$temp" =~ ^[0-9]+$ ]] || fail 'Invalid battery temperature reading.'
    (( 10#$temp >= 0 && 10#$temp <= 450 )) || fail 'Battery temperature is outside the reviewed range.'
  fi
  info "Charging baseline: SOC=${capacity}%, current=${current} uA, voltage=${voltage} uV."
}

check_power_restore() {
  local ac status voltage
  ac=$(</sys/class/power_supply/AC0/online) || fail 'Cannot read AC0 status.'
  [[ "$ac" == 1 ]] || fail 'AC0 is offline; reconnect the original DC-in adapter before restoring High Capacity.'
  status=$(</sys/class/power_supply/BAT0/status) || fail 'Cannot read battery status.'
  case "$status" in Charging|Full|'Not charging') ;; *) fail "Battery status is not suitable for restoration: $status." ;; esac
  voltage=$(</sys/class/power_supply/BAT0/voltage_now) || fail 'Cannot read battery voltage.'
  [[ "$voltage" =~ ^[0-9]+$ ]] || fail 'Invalid battery voltage.'
  (( 10#$voltage >= 11500000 && 10#$voltage <= 13050000 )) || fail 'Battery voltage is outside the reviewed range.'
}

run_acpi() {
  local command=$1 rc
  ACPI_OUT=$(timeout --signal=TERM --kill-after=2s 20s "$ACPI_DBG" -b "$command" 2>&1)
  rc=$?
  if (( rc != 0 )) || grep -Eiq 'failed|\bAE_[A-Z_]+' <<<"$ACPI_OUT"; then
    printf 'ACPI call was not confirmed (rc=%s); no retry or further writes. Output:\n%s\n' "$rc" "$ACPI_OUT" >&2
    return 1
  fi
  return 0
}

read_ec() {
  local address=$1 command match hex
  command="evaluate \\_SB.INOU.ECRR $address"
  run_acpi "$command" || return 1
  mapfile -t matches < <(grep -Eo '\[Integer\][[:space:]]*=[[:space:]]*[[:xdigit:]]+' <<<"$ACPI_OUT" || true)
  (( ${#matches[@]} == 1 )) || { printf 'Could not parse one unique ECRR value; no retry. Output:\n%s\n' "$ACPI_OUT" >&2; return 1; }
  hex=${matches[0]##*=}
  hex=${hex//[[:space:]]/}
  hex=${hex#0x}; hex=${hex#0X}
  [[ "$hex" =~ ^[[:xdigit:]]{1,16}$ ]] || {
    printf 'Invalid ECRR output format; no retry. Raw output:\n%s\n' "$ACPI_OUT" >&2
    return 1
  }
  EC_VALUE=$((16#$hex))
  (( EC_VALUE >= 0 && EC_VALUE <= 255 )) || {
    printf 'ECRR value is outside the byte range (value=%s); no retry. Raw output:\n%s\n' "$EC_VALUE" "$ACPI_OUT" >&2
    return 1
  }
}

write_ec() {
  local address=$1 value=$2 command
  command="evaluate \\_SB.INOU.ECRW $address $value"
  run_acpi "$command" || return 1
  grep -Eiq 'No object was returned|returned object' <<<"$ACPI_OUT" || {
    printf 'Could not parse ECRW completion; no retry or further ACPI calls. Output:\n%s\n' "$ACPI_OUT" >&2
    return 1
  }
}

ensure_state_dir() {
  if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
    install -d -o root -g root -m 0700 -- "$STATE_DIR" || fail 'Could not create the root-only state directory.'
  fi
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || fail 'State path is not a safe directory.'
  [[ "$(stat -c '%u:%a' "$STATE_DIR")" == '0:700' ]] || fail 'State directory owner or mode is incorrect.'
}

save_state() {
  local stage=$1 writes=$2 tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || fail 'Could not create a temporary state file.'
  {
    printf 'schema=1\n'
    printf 'stage=%s\n' "$stage"
    printf 'writes=%s\n' "$writes"
    printf 'updated=%s\n' "$(date --iso-8601=seconds)"
  } >"$tmp" || { rm -f -- "$tmp"; fail 'Could not write the state file.'; }
  chmod 0600 "$tmp" && chown root:root "$tmp" || { rm -f -- "$tmp"; fail 'Could not set state-file permissions.'; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; fail 'Could not save the state file.'; }
}

load_state() {
  local key
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail 'State file not found; refusing to take control of an unknown AP/profile state.'
  [[ "$(stat -c '%u:%a' "$STATE_FILE")" == '0:600' ]] || fail 'State-file owner or mode is incorrect.'
  [[ $(grep -c '^schema=1$' "$STATE_FILE") == 1 ]] || fail 'Invalid state-file schema.'
  [[ $(grep -c '^stage=' "$STATE_FILE") == 1 && $(grep -c '^writes=' "$STATE_FILE") == 1 ]] || fail 'State-file fields are missing or duplicated.'
  STATE_STAGE=$(awk -F= '$1=="stage" {print $2}' "$STATE_FILE")
  STATE_WRITES=$(awk -F= '$1=="writes" {print $2}' "$STATE_FILE")
  [[ "$STATE_WRITES" =~ ^[0-5]$ ]] || fail 'Invalid write count in the state file.'
}

write_checked() {
  local address=$1 value=$2 inflight=$3 completed=$4 expected=$5 next_writes
  (( STATE_WRITES < MAX_WRITES )) || fail 'The five-write limit for this cycle has been reached.'
  next_writes=$((STATE_WRITES + 1))
  # Persist in-flight before ECRW. If completion becomes uncertain, future
  # invocations refuse rather than blindly retrying or restoring.
  save_state "$inflight" "$next_writes"
  STATE_STAGE=$inflight
  STATE_WRITES=$next_writes
  write_ec "$address" "$value" || fail 'Write completion is uncertain; state remains in-flight and no further ACPI calls will be made.'
  read_ec "$address" || fail 'Readback is uncertain; no further ACPI calls will be made.'
  [[ "$EC_VALUE" == "$expected" ]] || fail "Unexpected readback at $address: $EC_VALUE. Stopping without blind restoration."
  save_state "$completed" "$STATE_WRITES"
  STATE_STAGE=$completed
}

read_baseline() {
  local cap pid ap profile
  read_ec 0x078e || fail 'Could not read capability.'; cap=$EC_VALUE
  read_ec 0x0740 || fail 'Could not read Project ID.'; pid=$EC_VALUE
  read_ec 0x0741 || fail 'Could not read AP state.'; ap=$EC_VALUE
  read_ec 0x07a6 || fail 'Could not read the profile.'; profile=$EC_VALUE
  [[ "$cap" == 8 && "$pid" == 9 && "$ap" == 0 && "$profile" == 0 ]] || \
    fail "Pre-enable state mismatch (cap=$cap, ProjectID=$pid, AP=$ap, profile=$profile); no writes made."
}

start_healthy() {
  ensure_state_dir
  [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail 'This one-time cycle already has a state file; do not rerun or reset it.'
  check_power_healthy
  read_baseline
  info 'Setting AP=1, High Capacity, then Healthy. AP-present will remain enabled while Healthy is active.'

  save_state 'starting' 0
  STATE_STAGE='starting'; STATE_WRITES=0
  write_checked 0x0741 0x01 ap_inflight ap_enabled 1
  write_checked 0x07a6 0x00 high_inflight high_prepared 0
  write_checked 0x07a6 0x20 healthy_inflight healthy 32
  info 'Healthy is set and AP-present remains 1. Keep the original DC-in connected; run high when finished.'
}

stop_high() {
  local ap profile
  check_power_restore
  ensure_state_dir

  if [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
    read_ec 0x0741 || fail 'Could not read AP state.'; ap=$EC_VALUE
    read_ec 0x07a6 || fail 'Could not read the profile.'; profile=$EC_VALUE
    if [[ "$ap" == 0 && "$profile" == 0 ]]; then
      info 'AP=0 and profile=High Capacity (0) already match the initial state; no writes made.'
      return 0
    fi
    fail 'No Healthy state from this tool; refusing to take control of an unknown setting.'
  fi

  load_state
  case "$STATE_STAGE" in
    starting|ap_enabled|high_prepared|healthy) ;;
    done)
      read_ec 0x0741 || fail 'Could not read AP state.'; ap=$EC_VALUE
      read_ec 0x07a6 || fail 'Could not read the profile.'; profile=$EC_VALUE
      [[ "$ap" == 0 && "$profile" == 0 ]] || fail 'State is marked complete, but live readback differs; no writes made.'
      info 'This one-time cycle is already restored to High/AP0; no further writes made.'
      return 0 ;;
    *) fail "State is $STATE_STAGE (possibly interrupted or native completion is uncertain); refusing to retry or restore. Review the state and ACPI output first." ;;
  esac

  read_ec 0x0741 || fail 'Could not read AP state.'; ap=$EC_VALUE
  read_ec 0x07a6 || fail 'Could not read the profile.'; profile=$EC_VALUE
  if [[ "$ap" == 0 && "$profile" == 0 && "$STATE_STAGE" == starting ]]; then
    save_state done "$STATE_WRITES"
    info 'No writes were made, and live state is already High/AP0; cycle marked complete.'
    return 0
  fi
  [[ "$ap" == 1 && ( "$profile" == 0 || "$profile" == 32 ) ]] || \
    fail "AP/profile is outside the reviewed state (AP=$ap, profile=$profile); refusing a blind write."

  write_checked 0x07a6 0x00 high_restore_inflight high_applied 0
  write_checked 0x0741 0x00 ap_clear_inflight done 0
  info 'High Capacity requested; readback is profile=0 and AP=0. This does not certify restoration of every internal firmware effect.'
}

case "$MODE" in
  healthy) start_healthy ;;
  high) stop_high ;;
esac
