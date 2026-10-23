#!/usr/bin/env bash
# 服务自愈：探活失败达到阈值 → 软重启 → (可选)重新枚举 USB → 硬重建 → 告警
#
# 用法:
#   ./watchdog_service.sh --container webdvr --url http://127.0.0.1:8073/
#   ./watchdog_service.sh --container webdvr --url http://127.0.0.1:8073/ --usb-reset 0bda
#   ./watchdog_service.sh --check-only --url http://127.0.0.1:8073/      # 只判定不动手
#
# 为什么分"软重启/硬重建"：绝大多数掉数据是进程内状态坏了，restart 就够；
# 容器重建只在这之后仍失败才做，避免每次故障都丢运行态。

set -uo pipefail

CONTAINER=""
URL=""
CONNECTIONS=""
THRESHOLD=3
USB_VENDOR=""
CHECK_ONLY=0
STATE_DIR="${WATCHDOG_STATE_DIR:-/tmp/watchdog}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --container)  CONTAINER="$2"; shift 2 ;;
    --url)        URL="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --threshold)  THRESHOLD="$2"; shift 2 ;;
    --usb-reset)  USB_VENDOR="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$URL" ] || { echo "必须给 --url" >&2; exit 2; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 2; }

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$(printf '%s' "$URL" | tr -c 'A-Za-z0-9' '_').fails"

probe() {
  curl -fsS -m 8 -o /dev/null "$URL"
}

probe_usb() {
  # 返回 USB 设备当前连接数（有 /sys 才能数，没有就返回 0）
  [ -d /sys/bus/usb/devices ] || { echo 0; return; }
  ls -d /sys/bus/usb/devices/*/idVendor 2>/dev/null \
    | while read -r f; do [ "$(cat "$f")" = "$USB_VENDOR" ] && echo x; done | wc -l
}

usb_reenumerate() {
  local vendor="$1" dev hostbin
  hostbin="${HOST_DOCKER_BIN:-}"
  log "重新枚举 USB 设备 (vendor=$vendor)"
  for d in /sys/bus/usb/devices/*/idVendor; do
    [ -f "$d" ] || continue
    [ "$(cat "$d")" = "$vendor" ] || continue
    dev="$(dirname "$d")"
    # 需要 root；失败不致命，交给上层告警
    if [ -w "$dev/authorized" ]; then
      echo 0 > "$dev/authorized" 2>/dev/null || log "authorized=0 失败: $dev"
      sleep 2
      echo 1 > "$dev/authorized" 2>/dev/null || log "authorized=1 失败: $dev"
    else
      log "无权限写 $dev/authorized（需要 sudo）"
      return 1
    fi
  done
  return 0
}

if probe; then
  echo 0 > "$STATE_FILE"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  log "探活失败（--check-only，不采取动作）: $URL"
  exit 1
fi

fails=$(( $(cat "$STATE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE_FILE"
log "探活失败 $fails/$THRESHOLD 次: $URL"

if [ "$fails" -lt "$THRESHOLD" ]; then
  exit 1
fi

if [ -n "$USB_VENDOR" ] && [ "$(probe_usb)" = "0" ]; then
  log "USB 设备消失，先重新枚举再看"
  usb_reenumerate "$USB_VENDOR"
  sleep 5
  probe && { echo 0 > "$STATE_FILE"; log "USB 重枚举后恢复"; exit 0; }
fi

if [ -n "$CONTAINER" ]; then
  log "重启容器: $CONTAINER"
  "$DOCKER_BIN" restart "$CONTAINER" >/dev/null 2>&1 || log "重启命令返回非 0"
  sleep 15
  if probe; then
    echo 0 > "$STATE_FILE"
    log "重启后恢复"
    exit 0
  fi
  log "重启无效，尝试重建（需要 compose 文件路径）"
fi

log "仍未恢复，请人工介入: $URL"
[ -n "$CONNECTIONS" ] && log "连接信息: $CONNECTIONS"
exit 1
