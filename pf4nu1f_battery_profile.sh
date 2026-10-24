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

fail() { printf '拒絕／停止：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
一次性手動切換 MECHREVO S2 Air PF4NU1F 電池 profile（會寫入 EC）

  sudo bash $SCRIPT_NAME healthy   設定原廠 Healthy，並保持 AP-present=1
  sudo bash $SCRIPT_NAME high      恢復原廠 High，然後清除 AP-present

只支援已驗證的 PF4NU1F / BIOS N.1.07MRO05 / EC 1.4 / kernel $EXPECTED_KERNEL。
實測僅涵蓋原配 DC-in；AC0 無法分辨 DC-in 與 USB-C PD，請勿在 PD 下使用。
本工具不會自動載入、常駐或開機啟動。
EOF
}

[[ "$MODE" == '-h' || "$MODE" == '--help' || -z "$MODE" ]] && { usage; exit 0; }
[[ "$MODE" == 'healthy' || "$MODE" == 'high' ]] || { usage >&2; exit 2; }

[[ "$EUID" -eq 0 ]] || fail '請以 sudo 執行。'
command -v timeout >/dev/null 2>&1 || fail '缺少 timeout。'
command -v flock >/dev/null 2>&1 || fail '缺少 flock。'
[[ -x "$ACPI_DBG" ]] || fail "找不到可執行的 $ACPI_DBG。"
[[ -r /sys/kernel/debug/acpi/acpidbg ]] || fail '既有 ACPI debugger 不可讀；不載入新模組。'
[[ "$(uname -r)" == "$EXPECTED_KERNEL" ]] || fail 'kernel 與已審查快照不符。'

for pair in \
  'sys_vendor|MECHREVO' \
  'product_name|S2 Air Series PF4NU1F' \
  'board_name|PF4NU1F' \
  'bios_version|N.1.07MRO05' \
  'ec_firmware_release|1.4'; do
  key=${pair%%|*}; expected=${pair#*|}
  file="/sys/class/dmi/id/$key"
  [[ -r "$file" ]] || fail "缺少 DMI 欄位 $key。"
  actual=$(<"$file")
  [[ "$actual" == "$expected" ]] || fail "DMI 不符：$key=$actual。"
done

actual_dsdt=$(sha256sum /sys/firmware/acpi/tables/DSDT 2>/dev/null | awk '{print $1}')
[[ "$actual_dsdt" == "$EXPECTED_DSDT_SHA256" ]] || fail 'DSDT hash 與已審查快照不符。'

for module in pf4nu1f_balanced_test uniwill_laptop uniwill_acpi uniwill_wmi \
              tuxedo_keyboard tuxedo_io acpi_call ec_sys; do
  [[ ! -e "/sys/module/$module" ]] || fail "發現可能衝突的 kernel module：$module。"
done
for comm in /proc/[0-9]*/comm; do
  [[ -r "$comm" ]] || continue
  name=$(<"$comm")
  case "${name,,}" in
    gcuservice.exe|controlcenteru|tuxedo-control-c|uucc-helper)
      fail "發現可能衝突的 OEM 控制程式：$name。" ;;
  esac
done

mkdir -p /run/lock 2>/dev/null || fail '無法使用 /run/lock。'
exec 9>"$LOCK_FILE" || fail '無法建立操作鎖。'
flock -n 9 || fail '另一個 profile 操作正在執行。'

check_power_healthy() {
  local ac status capacity current voltage temp
  ac=$(</sys/class/power_supply/AC0/online) || fail '讀取 AC0 失敗。'
  [[ "$ac" == 1 ]] || fail 'AC0 未在線；只在原配 DC-in 條件下測試。'
  status=$(</sys/class/power_supply/BAT0/status) || fail '讀取電池狀態失敗。'
  [[ "$status" == 'Charging' ]] || fail "需要先有真實充電基線，目前 status=$status。"
  capacity=$(</sys/class/power_supply/BAT0/capacity) || fail '讀取電量失敗。'
  current=$(</sys/class/power_supply/BAT0/current_now) || fail '讀取電流失敗。'
  voltage=$(</sys/class/power_supply/BAT0/voltage_now) || fail '讀取電壓失敗。'
  [[ "$capacity" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ && "$voltage" =~ ^[0-9]+$ ]] || fail '電源數值格式無效。'
  (( 10#$capacity >= 70 && 10#$capacity <= 100 )) || fail 'SOC 不在已審查的 70–100% 範圍。'
  (( 10#$current >= 100000 && 10#$current <= 2500000 )) || fail '沒有可用的正充電電流基線（需 100 mA–2.5 A）。'
  (( 10#$voltage >= 11500000 && 10#$voltage <= 13050000 )) || fail '電池電壓超出已審查的觀察範圍。'
  if [[ -r /sys/class/power_supply/BAT0/temp ]]; then
    temp=$(</sys/class/power_supply/BAT0/temp)
    [[ "$temp" =~ ^[0-9]+$ ]] || fail '電池溫度讀值格式無效。'
    (( 10#$temp >= 0 && 10#$temp <= 450 )) || fail '電池溫度超出已審查範圍。'
  fi
  info "充電基線：SOC=${capacity}%、電流=${current}uA、電壓=${voltage}uV。"
}

check_power_restore() {
  local ac status voltage
  ac=$(</sys/class/power_supply/AC0/online) || fail '讀取 AC0 失敗。'
  [[ "$ac" == 1 ]] || fail 'AC0 未在線；請先接回原配 DC-in，再恢復 High。'
  status=$(</sys/class/power_supply/BAT0/status) || fail '讀取電池狀態失敗。'
  case "$status" in Charging|Full|'Not charging') ;; *) fail "電池狀態不適合安全恢復：$status。" ;; esac
  voltage=$(</sys/class/power_supply/BAT0/voltage_now) || fail '讀取電壓失敗。'
  [[ "$voltage" =~ ^[0-9]+$ ]] || fail '電池電壓格式無效。'
  (( 10#$voltage >= 11500000 && 10#$voltage <= 13050000 )) || fail '電池電壓超出已審查範圍。'
}

run_acpi() {
  local command=$1 rc
  ACPI_OUT=$(timeout --signal=TERM --kill-after=2s 20s "$ACPI_DBG" -b "$command" 2>&1)
  rc=$?
  if (( rc != 0 )) || grep -Eiq 'failed|\bAE_[A-Z_]+' <<<"$ACPI_OUT"; then
    printf 'ACPI 呼叫未能確認（rc=%s）；不自動重試或繼續寫入。輸出：\n%s\n' "$rc" "$ACPI_OUT" >&2
    return 1
  fi
  return 0
}

read_ec() {
  local address=$1 command match hex
  command="evaluate \\_SB.INOU.ECRR $address"
  run_acpi "$command" || return 1
  mapfile -t matches < <(grep -Eo '\[Integer\][[:space:]]*=[[:space:]]*[[:xdigit:]]+' <<<"$ACPI_OUT" || true)
  (( ${#matches[@]} == 1 )) || { printf 'ECRR 輸出無法唯一解析；不重試。\n' >&2; return 1; }
  hex=${matches[0]##*=}
  hex=${hex//[[:space:]]/}
  hex=${hex#0x}; hex=${hex#0X}
  [[ "$hex" =~ ^[[:xdigit:]]{1,16}$ ]] || {
    printf 'ECRR 輸出格式無效；不重試。原始輸出：\n%s\n' "$ACPI_OUT" >&2
    return 1
  }
  EC_VALUE=$((16#$hex))
  (( EC_VALUE >= 0 && EC_VALUE <= 255 )) || {
    printf 'ECRR 整數超出 byte 範圍（value=%s）；不重試。原始輸出：\n%s\n' "$EC_VALUE" "$ACPI_OUT" >&2
    return 1
  }
}

write_ec() {
  local address=$1 value=$2 command
  command="evaluate \\_SB.INOU.ECRW $address $value"
  run_acpi "$command" || return 1
  grep -Eiq 'No object was returned|returned object' <<<"$ACPI_OUT" || {
    printf 'ECRW completion 無法解析；不重試、不再呼叫 ACPI。輸出：\n%s\n' "$ACPI_OUT" >&2
    return 1
  }
}

ensure_state_dir() {
  if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
    install -d -o root -g root -m 0700 -- "$STATE_DIR" || fail '建立 root-only 狀態目錄失敗。'
  fi
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || fail '狀態目錄不是安全的實體目錄。'
  [[ "$(stat -c '%u:%a' "$STATE_DIR")" == '0:700' ]] || fail '狀態目錄 owner/mode 不符。'
}

save_state() {
  local stage=$1 writes=$2 tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || fail '建立狀態暫存檔失敗。'
  {
    printf 'schema=1\n'
    printf 'stage=%s\n' "$stage"
    printf 'writes=%s\n' "$writes"
    printf 'updated=%s\n' "$(date --iso-8601=seconds)"
  } >"$tmp" || { rm -f -- "$tmp"; fail '寫狀態檔失敗。'; }
  chmod 0600 "$tmp" && chown root:root "$tmp" || { rm -f -- "$tmp"; fail '設定狀態檔權限失敗。'; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; fail '提交狀態檔失敗。'; }
}

load_state() {
  local key
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail '找不到本工具建立的狀態；不接管未知 AP/profile。'
  [[ "$(stat -c '%u:%a' "$STATE_FILE")" == '0:600' ]] || fail '狀態檔 owner/mode 不符。'
  [[ $(grep -c '^schema=1$' "$STATE_FILE") == 1 ]] || fail '狀態檔格式不符。'
  [[ $(grep -c '^stage=' "$STATE_FILE") == 1 && $(grep -c '^writes=' "$STATE_FILE") == 1 ]] || fail '狀態檔欄位不唯一。'
  STATE_STAGE=$(awk -F= '$1=="stage" {print $2}' "$STATE_FILE")
  STATE_WRITES=$(awk -F= '$1=="writes" {print $2}' "$STATE_FILE")
  [[ "$STATE_WRITES" =~ ^[0-5]$ ]] || fail '狀態檔寫入計數無效。'
}

write_checked() {
  local address=$1 value=$2 inflight=$3 completed=$4 expected=$5 next_writes
  (( STATE_WRITES < MAX_WRITES )) || fail '本次最多 5 次 ECRW 已用完。'
  next_writes=$((STATE_WRITES + 1))
  # Persist in-flight before ECRW. If completion becomes uncertain, future
  # invocations refuse rather than blindly retrying or restoring.
  save_state "$inflight" "$next_writes"
  STATE_STAGE=$inflight
  STATE_WRITES=$next_writes
  write_ec "$address" "$value" || fail '寫入結果不確定；狀態保留為 in-flight，停止後續 ACPI 呼叫。'
  read_ec "$address" || fail '讀回結果不確定；停止後續 ACPI 呼叫。'
  [[ "$EC_VALUE" == "$expected" ]] || fail "讀回值不符（地址 $address，讀到 $EC_VALUE）；停止，不盲目恢復。"
  save_state "$completed" "$STATE_WRITES"
  STATE_STAGE=$completed
}

read_baseline() {
  local cap pid ap profile
  read_ec 0x078e || fail '讀取 capability 失敗。'; cap=$EC_VALUE
  read_ec 0x0740 || fail '讀取 Project ID 失敗。'; pid=$EC_VALUE
  read_ec 0x0741 || fail '讀取 AP 狀態失敗。'; ap=$EC_VALUE
  read_ec 0x07a6 || fail '讀取 profile 失敗。'; profile=$EC_VALUE
  [[ "$cap" == 8 && "$pid" == 9 && "$ap" == 0 && "$profile" == 0 ]] || \
    fail "啟用前狀態不符（cap=$cap, ProjectID=$pid, AP=$ap, profile=$profile）；不寫入。"
}

start_healthy() {
  ensure_state_dir
  [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail '本工具已有一次性狀態檔；不重跑或重置。'
  check_power_healthy
  read_baseline
  info '寫入 AP=1、High、Healthy；Healthy 期間 AP 會保持啟用。'

  save_state 'starting' 0
  STATE_STAGE='starting'; STATE_WRITES=0
  write_checked 0x0741 0x01 ap_inflight ap_enabled 1
  write_checked 0x07a6 0x00 high_inflight high_prepared 0
  write_checked 0x07a6 0x20 healthy_inflight healthy 32
  info 'Healthy 已設定；AP-present 仍為 1。保持原配 DC-in，測試結束請執行 high。'
}

stop_high() {
  local ap profile
  check_power_restore
  ensure_state_dir

  if [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
    read_ec 0x0741 || fail '讀取 AP 失敗。'; ap=$EC_VALUE
    read_ec 0x07a6 || fail '讀取 profile 失敗。'; profile=$EC_VALUE
    if [[ "$ap" == 0 && "$profile" == 0 ]]; then
      info '目前 AP=0、profile=High(0)；已是測試前讀值，沒有寫入。'
      return 0
    fi
    fail '沒有本工具的 Healthy 狀態；不接管或清除未知設定。'
  fi

  load_state
  case "$STATE_STAGE" in
    starting|ap_enabled|high_prepared|healthy) ;;
    done)
      read_ec 0x0741 || fail '讀取 AP 失敗。'; ap=$EC_VALUE
      read_ec 0x07a6 || fail '讀取 profile 失敗。'; profile=$EC_VALUE
      [[ "$ap" == 0 && "$profile" == 0 ]] || fail '狀態標記已完成但 live readback 不同；不寫入。'
      info '此一次性測試已恢復 High/AP0；不再寫入。'
      return 0 ;;
    *) fail "狀態為 $STATE_STAGE（可能中斷或 native completion 不確定）；拒絕重試／恢復寫入。請先檢視狀態與原始 ACPI 結果。" ;;
  esac

  read_ec 0x0741 || fail '讀取 AP 失敗。'; ap=$EC_VALUE
  read_ec 0x07a6 || fail '讀取 profile 失敗。'; profile=$EC_VALUE
  if [[ "$ap" == 0 && "$profile" == 0 && "$STATE_STAGE" == starting ]]; then
    save_state done "$STATE_WRITES"
    info '測試尚未寫入，live 狀態已是 High/AP0；標記結束，沒有寫入。'
    return 0
  fi
  [[ "$ap" == 1 && ( "$profile" == 0 || "$profile" == 32 ) ]] || \
    fail "目前 AP/profile 不在已審查狀態（AP=$ap, profile=$profile）；不盲寫。"

  write_checked 0x07a6 0x00 high_restore_inflight high_applied 0
  write_checked 0x0741 0x00 ap_clear_inflight done 0
  info '已請求 High，並讀回 profile=0、AP=0。這不等同對所有內部策略副作用的安全認證。'
}

case "$MODE" in
  healthy) start_healthy ;;
  high) stop_high ;;
esac
