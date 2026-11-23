#!/usr/bin/env bash
# 遍历所有用户，谁到点了就推谁。由 cron 每 15 分钟调一次。
#
# 判定逻辑不是"现在正好等于 08:00"，而是"已过点且今天还没推过"。
# 好处：服务器重启、cron 漏跑、网络抖动，下一个 15 分钟会补上，也不会重复推。
# 失败最多重试 MAX_TRIES 次（默认 2，Server酱失败也计数，不能无限重试），之后放弃等明天。
# 次数按天算：.tries 里存「日期 次数」，跨天自动归零（不归零会永久卡死，见 read_tries）。

set -uo pipefail

# SELF = 脚本所在目录（用来找 env.sh 和 push-one.sh）
# BASE = 数据目录（含 users/、push.log、.lock），由环境变量传入，默认 /opt/todo-push
# 两者不能混：k8s 里脚本在 /opt/todo-push，数据在 /data，混了就会去扫一个空目录。
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SELF/env.sh"

# 数据目录不可写时，下面的 exec 9> 会静默失败，flock 跟着失败，脚本就假装跑完了。
# 先挡住这种情况，否则表现是「定时任务在跑，但一条都不推」。
if [ ! -d "$BASE" ] || [ ! -w "$BASE" ]; then
  echo "FAIL 数据目录 $BASE 不存在或不可写（uid=$(id -u)）。检查环境变量 BASE 是否指向挂载的卷。" >&2
  exit 1
fi

# 防止两次 cron 叠在一起跑（上一次还没跑完）
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BASE/.lock"
  if ! flock -n 9; then
    exit 0
  fi
else
  log "WARN 系统没有 flock（util-linux），本次不加锁直接跑"
fi

command -v sqlite3 >/dev/null 2>&1 || { log "FAIL sqlite3 未安装"; exit 1; }

TODAY=$(today)
NOW=$(now_hm)
# 一天最多试几次。Server酱 免费版每天 5 条额度，发送失败也计数，
# 所以「1 条正常 + 2 次重试 = 3 条」给个人额度留了余量。
MAX_TRIES="${MAX_TRIES:-2}"
N_DONE=0; N_FAIL=0; N_SKIP=0

# 读今天的失败次数。
# .tries 存的是「日期 次数」两栏，比如 "2026-11-18 1"。
# 为什么要日期：早期版本只存一个数字，结果是——某人某天连续失败 3 次，
# .tries 永远停在 3，之后每天都判定"放弃"，这个人从此静默收不到推送，
# 而且日志里只写一句"今天不再重试"，明天看起来一切正常。典型的沉默故障。
# 老格式（纯数字）在这里自然失效：read 出来的第一栏是次数、不是日期，
# 对不上今天就算 0，顺手把历史脏数据也清掉了。
read_tries() {
  local f="$1/.tries" d="" n=""
  [ -f "$f" ] || { echo 0; return; }
  # 注意：文件末尾没有换行时 read 会返回非 0（虽然值已经读进来了），
  # 所以不能拿 read 的返回值判断有没有读到东西，只看读到的内容。
  read -r d n < "$f" 2>/dev/null || true
  [ "$d" = "$TODAY" ] || { echo 0; return; }
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}

shopt -s nullglob
for d in "$USERS"/*/; do
  d="${d%/}"
  [ -f "$d/conf" ] || continue

  PUSH_AT=$(sed -n 's/^PUSH_AT=//p' "$d/conf" | head -1)
  PUSH_AT="${PUSH_AT:-08:00}"

  # SCAN_ONLY=1：只打印判定结果，不调用 push-one.sh、不写 .sent/.tries。
  # 用来零消耗地确认「扫到了谁、每个人会不会推、为什么不会」。
  #   k3s kubectl -n todo exec deploy/todo-app -c api -- \
  #     env SCAN_ONLY=1 /opt/todo-push/push-all.sh
  if [ "${SCAN_ONLY:-0}" = "1" ]; then
    SENT="$(cat "$d/.sent" 2>/dev/null || true)"
    TRIES_S="$(read_tries "$d")"
    if [ "$SENT" = "$TODAY" ]; then
      VERDICT="跳过（今天已推过）"
    elif [ "$NOW" \< "$PUSH_AT" ]; then
      VERDICT="跳过（还没到点 $PUSH_AT）"
    elif [ "$TRIES_S" -ge "$MAX_TRIES" ]; then
      VERDICT="跳过（今天已失败 ${TRIES_S} 次，达上限 $MAX_TRIES，明天重来）"
    else
      VERDICT="会推"
    fi
    log "SCAN $(basename "$d") NOW=$NOW PUSH_AT=$PUSH_AT .sent=${SENT:-无} 今日失败=${TRIES_S} → $VERDICT"
    continue
  fi

  # 今天已经推过了
  if [ "$(cat "$d/.sent" 2>/dev/null)" = "$TODAY" ]; then
    N_SKIP=$((N_SKIP + 1)); continue
  fi
  # 还没到点（HH:MM 定长，字符串比较即可）
  if [ "$NOW" \< "$PUSH_AT" ]; then
    continue
  fi

  TRIES=$(read_tries "$d")
  if [ "$TRIES" -ge "$MAX_TRIES" ]; then
    printf '%s' "$TODAY" > "$d/.sent"
    log "GIVEUP $(basename "$d") 今天已失败 ${TRIES} 次（上限 $MAX_TRIES），今天不再试，明天自动重来"
    N_FAIL=$((N_FAIL + 1)); continue
  fi

  if "$SELF/push-one.sh" "$d" "$TODAY"; then
    printf '%s' "$TODAY" > "$d/.sent"
    rm -f "$d/.tries"
    N_DONE=$((N_DONE + 1))
  else
    printf '%s %s\n' "$TODAY" "$((TRIES + 1))" > "$d/.tries"
    N_FAIL=$((N_FAIL + 1))
  fi
done

# 只在真有事的时候写汇总，避免日志刷屏
if [ "$N_DONE" -gt 0 ] || [ "$N_FAIL" -gt 0 ]; then
  log "TICK 处理${N_DONE} 失败${N_FAIL} 今日已推${N_SKIP}"
fi
exit 0
