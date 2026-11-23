#!/usr/bin/env bash
# 备份 / 恢复所有人的数据（在 k3s 节点上执行）
#
#   ./backup.sh                  # 备份到 ./backups/users-2026-11-17.tar.gz
#   ./backup.sh /data/bak        # 指定目录
#   ./backup.sh --restore 文件    # 从备份恢复（会覆盖同名用户目录）
#
# 备份的是 /data/users 整个目录：一人一个 sqlite + conf + 推送标记。
# 想连网页一起备份就自己 tar 一把卷目录，见 README。

set -euo pipefail
NS=todo
if command -v kubectl >/dev/null 2>&1; then K="kubectl"; else K="k3s kubectl"; fi
POD=$($K -n "$NS" get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "找不到 todo-app 的 Pod，先 kubectl -n $NS get pod"; exit 1; }

if [ "${1:-}" = "--restore" ]; then
  F="${2:?--restore 后面要跟备份文件}"
  [ -f "$F" ] || { echo "文件不存在：$F"; exit 1; }
  echo "恢复 $F -> $POD:/data （会覆盖同名用户）"
  $K -n "$NS" exec -i "$POD" -c api -- tar -xzf - -C /data < "$F"
  echo "完成。重启一下让接口重新读一遍：$K -n $NS rollout restart deploy/todo-app"
  exit 0
fi

OUT="${1:-./backups}"
STAMP=$(TZ=Asia/Shanghai date +%F)
mkdir -p "$OUT"
$K -n "$NS" exec "$POD" -c api -- tar -czf - -C /data users > "$OUT/users-$STAMP.tar.gz"
find "$OUT" -maxdepth 1 -name 'users-*.tar.gz' -mtime +30 -delete
echo "已备份：$OUT/users-$STAMP.tar.gz  $(du -h "$OUT/users-$STAMP.tar.gz" | cut -f1)"

TOTAL=$($K -n "$NS" exec "$POD" -c api -- sh -c 'ls -1d /data/users/*/ 2>/dev/null | wc -l')
echo "当前用户数：$TOTAL"
