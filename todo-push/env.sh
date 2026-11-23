#!/usr/bin/env bash
# 公共变量与函数。被 push-all.sh / push-one.sh source，不要直接执行。
# 想改端口、日志位置，改这里一处即可。

# BASE 是「数据目录」，里面放 users/、push.log、.lock。
#   k8s 里由 Deployment / CronJob 的 env BASE=/data 传进来（那是挂载的卷）；
#   在宿主机手动跑时默认 /opt/todo-push。
# 注意它和「脚本所在目录」是两件事：脚本可以放在 /opt/todo-push，
# 数据放在 /data，所以不要在脚本里用脚本目录去覆盖 BASE。
BASE="${BASE:-/opt/todo-push}"
USERS="$BASE/users"
LOG="$BASE/push.log"
TZ_CN="Asia/Shanghai"

# 追加一行推送记录。
# 注意：同时打到 stderr。原因有两个：
#   1) CronJob 里 stderr 会进 kubectl logs，出问题能看到「为什么没推」
#   2) 手动 exec 进来跑时，屏幕上也直接看得到
# 早期版本只写文件，碰上日志目录没权限（比如 BASE 指错），
# 表现就是「屏幕上只剩一行 Permission denied，为什么会跳过完全不知道」。
_LOG_WARNED=0
log() {
  local line
  line="$(TZ=$TZ_CN date '+%F %T') $*"
  printf '%s\n' "$line" >&2
  if ! { printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null; then
    if [ "$_LOG_WARNED" = "0" ]; then
      printf '!! 日志写不进 %s（uid=%s），本行及后续只显示不落盘\n' "$LOG" "$(id -u)" >&2
      _LOG_WARNED=1
    fi
  fi
}

# 设备码 -> 目录名。取 sha256 前 16 位，目录里不出现完整凭据。
tok2dir() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

today()  { TZ=$TZ_CN date +%F; }
now_hm() { TZ=$TZ_CN date +%H:%M; }
