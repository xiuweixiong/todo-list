#!/usr/bin/env bash
# 备份所有人数据成一个 tar 包。手动跑或挂到 cron 都行。
#   ./backup.sh            -> /var/backups/todo-push/users-2026-11-17.tar.gz
#   ./backup.sh /data/bak  -> 指定目录
# 保留 30 天，更早的自动删。

set -euo pipefail
BASE="${BASE:-/opt/todo-push}"
OUT="${1:-/var/backups/todo-push}"
STAMP="$(TZ=Asia/Shanghai date +%F)"

mkdir -p "$OUT"
tar -czf "$OUT/users-$STAMP.tar.gz" -C "$BASE" users
find "$OUT" -maxdepth 1 -name 'users-*.tar.gz' -mtime +30 -delete
echo "已备份：$OUT/users-$STAMP.tar.gz"
