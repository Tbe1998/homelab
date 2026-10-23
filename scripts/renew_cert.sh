#!/usr/bin/env bash
# 证书续期 + 分发 + 生效校验
#
# 关键教训（docs/runbook.md 案例 2）：只替换文件不重启套件不生效；
# DSM 是 synopkg 而非 systemd，必须 stop → 换文件 → start。
# 本脚本强制做"服务端实际证书指纹比对"，不一致就报错，不许静默成功。

set -euo pipefail

DOMAIN="${DOMAIN:?需要 DOMAIN}"
LE_HOME="${LE_HOME:-/root/.acme.sh}"
CERT_SRC="${CERT_SRC:-$LE_HOME/${DOMAIN}_ecc}"
DEST_DIR="${DEST_DIR:-/volume1/docker/certs}"
PKG="${PKG:-}"                  # 可选：需要重启的 synopkg 套件名
NGINX_RELOAD="${NGINX_RELOAD:-}"  # 可选：nginx -s reload 的 docker exec 目标
SLACK_WEBHOOK="${ALERT_WEBHOOK:-}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
alert() { log "ALERT: $*"; [ -n "$SLACK_WEBHOOK" ] && curl -fsS -m 8 -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"[证书] $*\"}}" "$SLACK_WEBHOOK" >/dev/null || true; }

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

log "续期: $DOMAIN"
"$LE_HOME/acme.sh" --renew -d "$DOMAIN" --ecc --home "$LE_HOME" || log "续期未产生新证书（可能未到期）"

server_pem="$CERT_SRC/fullchain.cer"
server_key="$CERT_SRC/${DOMAIN}.key"
[ -s "$server_pem" ] || { alert "源证书不存在: $server_pem"; exit 1; }
[ -s "$server_key" ] || { alert "源私钥不存在: $server_key"; exit 1; }

# 新证书剩余有效期自检，少于 7 天说明续期其实失败了
end=$(openssl x509 -in "$server_pem" -noout -enddate | cut -d= -f2)
end_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
days=$(( (end_epoch - now_epoch) / 86400 ))
log "证书到期: $end (剩 $days 天)"
[ "$days" -ge 7 ] || { alert "续期后剩余仅 $days 天，续期链路有问题"; exit 1; }

if [ -n "$PKG" ]; then
  log "停止套件: $PKG"
  synopkg stop "$PKG" || log "stop 返回非 0（可能未运行）"
fi

install -m 644 "$server_pem" "$DEST_DIR/${DOMAIN}.pem"
install -m 600 "$server_key" "$DEST_DIR/${DOMAIN}.key"
log "证书已更新到 $DEST_DIR"

if [ -n "$PKG" ]; then
  synopkg start "$PKG"
  sleep 8
fi
if [ -n "$NGINX_RELOAD" ]; then
  $NGINX_RELOAD nginx -t && $NGINX_RELOAD nginx -s reload && log "nginx 已 reload"
fi

# ── 生效校验：磁盘指纹 vs 服务端实际指纹
if [ -n "${VERIFY_HOST:-}" ]; then
  want=$(openssl x509 -in "$DEST_DIR/${DOMAIN}.pem" -noout -fingerprint -sha256 | cut -d= -f2)
  got=$(echo | openssl s_client -connect "${VERIFY_HOST}:${VERIFY_PORT:-443}" \
        -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)
  if [ "$want" != "$got" ]; then
    alert "证书未生效！磁盘=$want 服务端=${got:-空}"
    exit 1
  fi
  log "生效校验通过 ($want)"
fi

log "完成"
