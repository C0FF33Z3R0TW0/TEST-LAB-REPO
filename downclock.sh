#!/bin/bash
# Cap an i5-10210U mini PC (19V brick) so it stays stable on a 12V PSU.
set -euo pipefail

# ===== CONFIG =====
MAX_FREQ_KHZ="1200000" # 1.2GHz cap
MIN_FREQ_KHZ="400000"  # 400MHz floor
PL1_UW="10000000"      # 10W package long-term
PL2_UW="12000000"      # 12W package short-term
PSYS_UW="15000000"     # 15W platform budget
IGPU_MAX_MHZ="400"     # iGPU limit
MAX_PERF_PCT="75"      # 1.2 / 1.6 GHz
STATIC_IP="192.168.69.147/24"
INTERFACE="eno2"
# ==================

APPLY_PATH="/usr/local/sbin/downclock-apply"
UNIT_PATH="/etc/systemd/system/downclock.service"
OLD_UNIT="psu-limit.service"

if [[ "${1:-}" != "--status" && "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

sysfs_write() {
  local path="$1" value="$2"
  if [[ -e "$path" ]]; then
    # The "|| true" prevents set -e from crashing the script if a write is blocked
    printf '%s\n' "$value" >"$path" 2>/dev/null || true
  fi
}

apply() {
  echo "[1/6] CPU: powersave, 1.2GHz cap, turbo off, EPP=power"

  sysfs_write /sys/devices/system/cpu/intel_pstate/no_turbo 1
  sysfs_write /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 0
  sysfs_write /sys/devices/system/cpu/intel_pstate/max_perf_pct "$MAX_PERF_PCT"

  # Write directly to sysfs instead of using cpupower
  local f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    sysfs_write "$f" powersave
  done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    sysfs_write "$f" "$MAX_FREQ_KHZ"
  done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
    sysfs_write "$f" "$MIN_FREQ_KHZ"
  done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    sysfs_write "$f" power
  done

  echo "[2/6] Park SMT siblings (cpu4-7)"
  local cpu
  for cpu in /sys/devices/system/cpu/cpu{4,5,6,7}/online; do
    sysfs_write "$cpu" 0
  done

  echo "[3/6] RAPL: PL1=${PL1_UW}uW PL2=${PL2_UW}uW"
  local rapl="/sys/class/powercap/intel-rapl/intel-rapl:0"
  if [[ -d "$rapl" ]]; then
    sysfs_write "$rapl/enabled" 1
    sysfs_write "$rapl/constraint_0_power_limit_uw" "$PL1_UW"
    sysfs_write "$rapl/constraint_1_power_limit_uw" "$PL2_UW"
  fi
  local psys="/sys/class/powercap/intel-rapl/intel-rapl:1"
  if [[ -d "$psys" && "$(cat "$psys/name" 2>/dev/null)" == "psys" ]]; then
    sysfs_write "$psys/enabled" 1
    sysfs_write "$psys/constraint_0_power_limit_uw" "$PSYS_UW"
    sysfs_write "$psys/constraint_1_power_limit_uw" "$PSYS_UW"
  fi

  echo "[4/6] iGPU cap ${IGPU_MAX_MHZ} MHz"
  local card
  for card in /sys/class/drm/card*/gt_max_freq_mhz; do
    [[ -f "$card" ]] || continue
    local dir
    dir="$(dirname "$card")"
    sysfs_write "$card" "$IGPU_MAX_MHZ"
    if [[ -f "$dir/gt_boost_freq_mhz" ]]; then
      sysfs_write "$dir/gt_boost_freq_mhz" "$IGPU_MAX_MHZ"
    fi
  done

  echo "[5/6] Mask power-profiles-daemon so it stops overwriting EPP"
  systemctl stop power-profiles-daemon.service 2>/dev/null || true
  systemctl mask power-profiles-daemon.service 2>/dev/null || true

  echo "[6/6] Set Static IP ($STATIC_IP) on $INTERFACE"
  if command -v nmcli >/dev/null; then
    nmcli device modify "$INTERFACE" ipv4.addresses "$STATIC_IP" ipv4.method manual 2>/dev/null || true
    nmcli device reapply "$INTERFACE" 2>/dev/null || true
  else
    ip addr add "$STATIC_IP" dev "$INTERFACE" 2>/dev/null || true
  fi
}

install_persist() {
  echo "Installing persistence..."
  install -m 755 "$0" "$APPLY_PATH"

  cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Downclock CPU/GPU for 12V PSU on 19V mini PC
After=multi-user.target NetworkManager.service
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=${APPLY_PATH} --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
EOF

  cat >/etc/modprobe.d/blacklist-wifi-bt.conf <<'EOF'
blacklist iwlwifi
blacklist iwlmvm
blacklist btusb
blacklist btintel
blacklist btrtl
blacklist btbcm
blacklist bluetooth
EOF

  systemctl daemon-reload
  systemctl enable downclock.service
  systemctl disable --now "${OLD_UNIT}" >/dev/null 2>&1 || true
}

status() {
  echo "============================================"
  echo "governor:     $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  echo "max freq:     $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) kHz"
  echo "EPP:          $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
  echo "no_turbo:     $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
  echo "online cpus:  $(cat /sys/devices/system/cpu/online)"
  echo "RAPL PL1:     $(cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) uW"
  echo "RAPL PL2:     $(cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null) uW"
  echo "iGPU max:     $(cat /sys/class/drm/card*/gt_max_freq_mhz 2>/dev/null | head -n 1) MHz"
  echo "IP address:   $(ip -4 -br addr show "$INTERFACE" 2>/dev/null | awk '{print $3}')"
  echo "============================================"
}

case "${1:-}" in
--apply)
  apply
  ;;
--status)
  status
  ;;
*)
  apply
  install_persist
  systemctl restart downclock.service
  status
  echo "Done. IP is static and background power daemons are masked."
  ;;
esac
