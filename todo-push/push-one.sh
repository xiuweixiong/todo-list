#!/usr/bin/env bash
# 给单个用户发一条推送。
#   ./push-one.sh /opt/todo-push/users/a3f9c1d2e7b40f58 [YYYY-MM-DD]
# 不带日期参数就按北京时间取今天。手动跑一次就够验证这个人的配置对不对。

set -uo pipefail

# SELF = 脚本目录（找 env.sh）；BASE = 数据目录（见 env.sh 注释）。
# 不要在脚本里用 SELF 覆盖 BASE——k8s 里脚本在 /opt/todo-push，数据在 /data。
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SELF/env.sh"

DIR="${1:?用法: push-one.sh <用户目录> [YYYY-MM-DD]}"
TODAY="${2:-$(today)}"
DIR="${DIR%/}"

if [ ! -f "$DIR/conf" ]; then
  log "SKIP $(basename "$DIR") 没有 conf 文件——网页「云同步」里没填 SendKey。填一次再点「立即上传」"
  exit 0
fi

# conf 里只有这三个变量，先给默认值防止 set -u 报错
SENDKEY=""; PUSH_AT="08:00"; NICK=""
# shellcheck disable=SC1090
. "$DIR/conf"

NAME="${NICK:-$(basename "$DIR")}"
DB="$DIR/todos.sqlite"
ERR="$DIR/last.log"

if ! command -v sqlite3 >/dev/null 2>&1; then
  log "FAIL sqlite3 未安装（apt install -y sqlite3）"
  exit 1
fi
if [ -z "$SENDKEY" ]; then
  log "SKIP $NAME 的 conf 里 SENDKEY 是空的——在网页「云同步」里填 SendKey 后重新上传"
  exit 0
fi
if [ ! -s "$DB" ]; then
  log "SKIP $NAME 没有 todos.sqlite——网页上还没点过「立即上传」"
  exit 0
fi

# Server酱的接口域名按 key 前缀分两种，认错就是 404
case "$SENDKEY" in
  SCT*)
    URL="https://sctapi.ftqq.com/$SENDKEY.send"
    ;;
  sctp*)
    UID_N="$(printf '%s' "$SENDKEY" | sed -n 's/^sctp\([0-9]\{1,\}\)t.*/\1/p')"
    if [ -z "$UID_N" ]; then
      log "FAIL $NAME SendKey 格式不对，取不到 uid"
      exit 1
    fi
    URL="https://$UID_N.push.ft07.com/send/$SENDKEY.send"
    ;;
  *)
    log "FAIL $NAME SendKey 前缀不认识（应为 SCT 或 sctp 开头）"
    exit 1
    ;;
esac

q() { sqlite3 "$DB" "$1" 2>/dev/null; }

N_OVER=$(q "SELECT count(*) FROM todos WHERE done=0 AND due_date IS NOT NULL AND due_date<>'' AND due_date < '$TODAY'")
N_TDAY=$(q "SELECT count(*) FROM todos WHERE done=0 AND due_date = '$TODAY'")
N_OVER="${N_OVER:-0}"
N_TDAY="${N_TDAY:-0}"

# 没有到期也没有逾期就不发，省额度
if [ "$N_OVER" -eq 0 ] && [ "$N_TDAY" -eq 0 ]; then
  log "SKIP $NAME 今天既没逾期也没到期（没这两类就不发，省额度）"
  exit 0
fi

PRIO="CASE priority WHEN 2 THEN '高' WHEN 1 THEN '中' ELSE '低' END"

TITLE="待办：今天到期 ${N_TDAY} 件，逾期 ${N_OVER} 件"
BODY=""

if [ "$N_OVER" -gt 0 ]; then
  LIST=$(q "SELECT '【'||$PRIO||'】'||content||'（'||due_date||'）' FROM todos
            WHERE done=0 AND due_date IS NOT NULL AND due_date<>'' AND due_date < '$TODAY'
            ORDER BY priority DESC, due_date")
  BODY+="**已逾期 ${N_OVER} 件**"$'\n\n'"$(printf '%s\n' "$LIST" | sed 's/^/- /')"$'\n\n'
fi

if [ "$N_TDAY" -gt 0 ]; then
  LIST=$(q "SELECT '【'||$PRIO||'】'||content FROM todos
            WHERE done=0 AND due_date = '$TODAY'
            ORDER BY priority DESC, id DESC")
  BODY+="**今天到期 ${N_TDAY} 件**"$'\n\n'"$(printf '%s\n' "$LIST" | sed 's/^/- /')"$'\n\n'
fi

# 一行尾巴，方便判断这份清单是什么时候导出的
BODY+="> 数据更新于 $(TZ=$TZ_CN date -r "$DB" '+%m-%d %H:%M' 2>/dev/null || echo '未知')"

# 只预览不发送：DRY=1 ./push-one.sh <用户目录>
# 用来确认正文对不对、会不会误推，不消耗 Server酱 额度。
if [ "${DRY:-0}" = "1" ]; then
  printf '%s\n\n%s\n' "$TITLE" "$BODY"
  log "DRY  $NAME 只预览，未发送"
  exit 0
fi

RESP=$(curl -sS --max-time 15 -X POST "$URL" \
  --data-urlencode "title=$TITLE" \
  --data-urlencode "desp=$BODY" 2>&1)
RC=$?

CODE=$(printf '%s' "$RESP" | grep -o '"code":[[:space:]]*-\?[0-9]*' | head -1 | grep -o '\-\?[0-9]*$')

{
  printf '%s 推送 %s：%s\n' "$(TZ=$TZ_CN date '+%F %T')" "$NAME" "$TITLE"
  printf '  逾期%d 到期%d curl_rc=%d api_code=%s\n' "$N_OVER" "$N_TDAY" "$RC" "${CODE:-无}"
  [ -n "$RESP" ] && printf '  %s\n' "$RESP" | head -3
} > "$ERR" 2>&1 || true

if [ "$RC" -eq 0 ] && [ "$CODE" = "0" ]; then
  log "OK   $NAME 逾期${N_OVER} 到期${N_TDAY}"
  exit 0
fi

log "FAIL $NAME rc=$RC code=${CODE:-?} $(printf '%s' "$RESP" | head -c 200)"
exit 1
