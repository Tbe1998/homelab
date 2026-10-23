#!/usr/bin/env bash
# 备份 docker 配置（compose/.env/脚本），不备份数据卷本身。
# 数据卷按服务各自 dump（如 mysqldump）更可靠，见 docs/runbook.md 的说明。
#
# 用法: ./backup_stacks.sh /volume1/docker /volume1/backup 7

set -euo pipefail

SRC="${1:-/volume1/docker}"
DST="${2:-/volume1/backup}"
KEEP="${3:-7}"

[ -d "$SRC" ] || { echo "源目录不存在: $SRC" >&2; exit 1; }
mkdir -p "$DST"
cd "$DST"

stamp=$(date +%Y%m%d_%H%M%S)
out="docker_config_${stamp}.tar.gz"

# 只收配置，排除运行态大目录；.env 收进去是因为恢复时必须配套
tar -czf "$out" -C "$SRC" \
  --exclude='*/mysql' --exclude='*/data' --exclude='*@eaDir*' \
  --exclude='*.log' --exclude='*.tar.gz' \
  $(cd "$SRC" && ls -d */ 2>/dev/null) 2>/dev/null || true

[ -s "$out" ] || { echo "备份包为空，检查源目录" >&2; exit 1; }
chmod 600 "$out"
echo "已生成 $(pwd)/$out ($(du -h "$out" | cut -f1))"

# 保留最近 N 份（先列出再删，避免误删最新一份）
ls -1t docker_config_*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  echo "清理旧备份: $old"
  rm -f -- "$old"
done
