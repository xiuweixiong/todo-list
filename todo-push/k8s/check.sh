#!/usr/bin/env bash
# 部署完之后跑一遍，确认「网页能打开、数据能存、推送能读」这三条链条都通。
#
#   ./check.sh                      # 在 k3s 节点上跑
#   ./check.sh --host 1.2.3.4       # 从别的机器检查，指定节点 IP
#   ./check.sh --port 30080
#
# 只读为主，唯一会写东西的是「同步闭环」那一项：用一个测试设备码上传一个
# 临时 sqlite 再读回来比对，跑完会把这个测试用户的数据删掉，不留垃圾。

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NS=todo
HOST=127.0.0.1
PORT=30080
TOK=ffffffffffffffffffffffffffffffff   # 32 个 f，纯粹给自检用，跟你自己的设备码无关
TMPDB=/tmp/check-todo.sqlite

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host 后面要跟 IP}"; shift 2 ;;
    --port) PORT="${2:?--port 后面要跟端口}"; shift 2 ;;
    *) echo "用法: $0 [--host IP] [--port 端口]"; exit 1 ;;
  esac
done

BASE="http://$HOST:$PORT"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m-\033[0m %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

if command -v kubectl >/dev/null 2>&1; then K="kubectl"; else K="k3s kubectl"; fi
command -v k3s >/dev/null 2>&1 || { echo "没找到 k3s，本脚本要在节点上跑"; exit 1; }
$K get nodes >/dev/null 2>&1 || { echo "kubectl 连不上集群"; exit 1; }

# ============ 1. 集群和存储 ============
sec "1. 集群 / 存储"

$K get ns "$NS" >/dev/null 2>&1 && pass "命名空间 $NS 存在" || bad "命名空间 $NS 不存在，清单没 apply？"

PVC=$($K -n "$NS" get pvc todo-data -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PVC" = "Bound" ] && pass "存储卷 todo-data 已绑定（数据真的落盘了）" \
  || bad "存储卷 todo-data 状态是 '$PVC'，应该是 Bound"

# 数据实际落在哪，直接给路径，方便他自己去备份
PV_PATH=$($K -n "$NS" get pvc todo-data -o jsonpath='{.spec.volumeName}' 2>/dev/null)
if [ -n "$PV_PATH" ]; then
  REAL=$(ls -d /var/lib/rancher/k3s/storage/*_${NS}_todo-data 2>/dev/null | head -1)
  [ -n "$REAL" ] && note "数据目录：$REAL"
fi

# ============ 2. Pod ============
sec "2. 应用 Pod"

READY=$($K -n "$NS" get deploy todo-app -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)
[ "$READY" = "1/1" ] && pass "todo-app 就绪 1/1" || bad "todo-app 就绪 $READY"

POD=$($K -n "$NS" get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
  PHASE=$($K -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
  [ "$PHASE" = "Running" ] && pass "Pod $POD 正在运行" || bad "Pod $POD 状态 $PHASE"

  # 两个容器都得 ready：只有 api 起来、web 没起来时网页打不开（503）
  for c in api web; do
    R=$($K -n "$NS" get pod "$POD" -o jsonpath="{.status.containerStatuses[?(@.name=='$c')].ready}" 2>/dev/null)
    case "$c" in
      api) [ "$R" = "true" ] && pass "容器 api 就绪（同步接口）" || bad "容器 api 未就绪" ;;
      web) [ "$R" = "true" ] && pass "容器 web 就绪（nginx）" || bad "容器 web 未就绪" ;;
    esac
  done

  RESTARTS=$($K -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null)
  case "$RESTARTS" in
    *[1-9]*) note "重启次数：$RESTARTS（偶尔重启不致命，看下面日志确认原因）" ;;
    *)       pass "没有异常重启" ;;
  esac

  # nginx 配置是 ConfigMap 挂进去的，名字对不上 nginx 会起不来
  $K -n "$NS" get configmap todo-nginx >/dev/null 2>&1 \
    && pass "nginx 配置 ConfigMap 存在" || bad "缺少 ConfigMap/todo-nginx，nginx 会起不来"

  # 镜像是不是本地导入的（真从 Docker Hub 拉的话，内网断了重启会起不来）
  IMG=$($K -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="api")].imageID}' 2>/dev/null)
  note "api 镜像：${IMG:0:60}"
else
  bad "没找到 Pod"
fi

# ============ 3. 网页 ============
sec "3. 网页（从 $BASE 访问）"

CODE=$(curl -s -o /tmp/check-index.html -w '%{http_code}' --max-time 30 "$BASE/" 2>/dev/null || echo 000)
SIZE=$(stat -c%s /tmp/check-index.html 2>/dev/null || echo 0)

if [ "$CODE" = "200" ]; then
  pass "首页 HTTP 200"
  if [ "$SIZE" -gt 7000000 ]; then
    pass "首页大小 $(du -h /tmp/check-index.html | cut -f1)（完整网页，约 7.5MB）"
  else
    bad "首页只有 $SIZE 字节，网页没传完整。重传方法见下面（注意 cp 只认 Pod 名）"
  fi
  head -c 200 /tmp/check-index.html | grep -qi '<!doctype html\|<html' \
    && pass "返回的确实是 HTML" || bad "返回内容不像 HTML"
else
  case "$CODE" in
    000) bad "首页连不上（HTTP 000）：30080 被防火墙/安全组挡住，或 Pod 根本没起来" ;;
    403) bad "首页 HTTP 403：nginx 在跑，但 /data/www 里没有 index.html——就是网页没传上去"
         note "传（kubectl cp 只认 Pod 名，不认 deploy/ 简写，且必须 -c api）："
         note "  POD=\$($K -n $NS get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')"
         note "  $K -n $NS cp ../www/index.html \$POD:/data/www/index.html -c api" ;;
    404) bad "首页 HTTP 404：nginx 的 root 路径不对，检查 ConfigMap 里的 root /data/www" ;;
    503) bad "首页 HTTP 503：nginx 起来了但拿不到网页，看 $K -n $NS logs deploy/todo-app -c web" ;;
    502|504) bad "首页 HTTP $CODE：nginx 连不上 api 容器，看 $K -n $NS logs deploy/todo-app -c api" ;;
    *)   bad "首页 HTTP $CODE" ;;
  esac
  WWW=$($K -n "$NS" exec deploy/todo-app -c api -- sh -c 'ls -l /data/www 2>/dev/null' 2>/dev/null)
  if [ -z "$WWW" ]; then
    note "容器里 /data/www 是空的"
  else
    note "容器里 /data/www 的内容："
    printf '%s\n' "$WWW" | sed 's/^/        /'
  fi
fi

# gzip：7.8MB 的页面压完约 3.8MB（里面大半是 base64，压不动），手机省一半流量
if [ "$CODE" = "200" ]; then
  GZ=$(curl -s -o /dev/null -w '%{size_download}' -H 'Accept-Encoding: gzip' --max-time 30 "$BASE/" 2>/dev/null || echo 0)
  if [ "$GZ" -gt 0 ] && [ "$GZ" -lt "$SIZE" ]; then
    pass "gzip 生效（传输 $((GZ / 1024))KB / 原始 $((SIZE / 1024))KB）"
  else
    bad "gzip 没生效（ConfigMap 里 gzip on 应该开着，检查有没有 apply 到新配置）"
  fi

  # 第二次打开走 304，几乎不耗流量
  ET=$(curl -s -o /dev/null -D - --max-time 30 "$BASE/" 2>/dev/null | grep -i '^etag:' | tr -d '\r' | cut -d' ' -f2)
  if [ -n "$ET" ]; then
    C304=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "If-None-Match: $ET" "$BASE/" 2>/dev/null)
    [ "$C304" = "304" ] && pass "第二次打开走 304（不重复下载 $((SIZE / 1024))KB）" \
      || skip "带 ETag 再请求返回 $C304，nginx 没走 304（不影响使用）"
  else
    skip "首页没返回 ETag"
  fi
fi

# ============ 4. 接口闭环 ============
sec "4. 同步接口（上传 → 回读 → 拒收坏库）"

H=$(curl -s --max-time 5 "$BASE/healthz" 2>/dev/null)
[ "$H" = "ok" ] && pass "/healthz 返回 ok" || bad "/healthz 返回 '$H'，api 容器可能没起来"

if command -v python3 >/dev/null 2>&1; then
  rm -f "$TMPDB"
  python3 - "$TMPDB" <<'PY' 2>/dev/null
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE todos(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL,
             priority INTEGER DEFAULT 1, done INTEGER DEFAULT 0, category TEXT DEFAULT '工作',
             due_date TEXT, created_at TEXT)""")
c.execute("INSERT INTO todos(content,priority,done,created_at) VALUES('部署自检-可删除',2,0,datetime('now','localtime'))")
c.commit(); c.close()
PY

  if [ -f "$TMPDB" ]; then
    UP=$(curl -s -o /tmp/check-up.txt -w '%{http_code}' --max-time 15 \
         -X PUT "$BASE/api/todos" -H "X-Token: $TOK" \
         --data-binary "@$TMPDB" 2>/dev/null || echo 000)
    if [ "$UP" = "200" ]; then
      pass "上传成功（服务器收下并校验通过）"
      curl -s --max-time 20 -H "X-Token: $TOK" "$BASE/api/todos" -o /tmp/check-down.sqlite 2>/dev/null
      # 用 md5sum 比，不用 cmp：有些精简系统没装 diffutils，会误报"不一致"
      UPMD5=$(md5sum "$TMPDB" 2>/dev/null | cut -d' ' -f1)
      DNMD5=$(md5sum /tmp/check-down.sqlite 2>/dev/null | cut -d' ' -f1)
      if [ -n "$UPMD5" ] && [ "$UPMD5" = "$DNMD5" ]; then
        pass "回读一致（md5 $UPMD5，存的就是原文件）"
      else
        bad "回读和上传的内容不一致（上传 $UPMD5 / 回读 $DNMD5）"
      fi
    else
      bad "上传返回 HTTP $UP $(head -c 100 /tmp/check-up.txt 2>/dev/null)"
      note "400 = 库结构不合格；413 = 超过 8MB；500 = api 内部错误，看容器日志"
    fi

    # 坏文件必须被拒，这条决定了「用户传了个坏库会不会把旧数据覆盖掉」
    BAD=$(printf 'this is not a sqlite file' | curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          -X PUT "$BASE/api/todos" -H "X-Token: $TOK" --data-binary @- 2>/dev/null || echo 000)
    [ "$BAD" = "400" ] && pass "坏文件被拒绝（不会覆盖已有数据）" \
      || bad "坏文件居然被接受了（HTTP $BAD），这个要查"

    # 清理测试数据，别在用户的 users/ 里留个假账号
    HASH=$(printf '%s' "$TOK" | sha256sum | cut -c1-16)
    if $K -n "$NS" exec deploy/todo-app -c api -- rm -rf "/data/users/$HASH" >/dev/null 2>&1; then
      pass "测试数据已清理"
    else
      skip "测试数据没删掉，手动清：$K -n $NS exec deploy/todo-app -c api -- rm -rf /data/users/$HASH"
    fi
  else
    skip "python3 生成测试库失败，跳过接口闭环"
  fi
else
  skip "节点上没有 python3，跳过接口闭环（也可以直接在网页上点「立即上传」验证）"
fi

# ============ 5. 真实用户数据 ============
sec "5. 真实数据"

NUSER=$($K -n "$NS" exec deploy/todo-app -c api -- sh -c 'ls -1 /data/users 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')
case "$NUSER" in
  ''|0) note "还没有人同步过数据（正常，等他们打开网页点「立即上传」）" ;;
  *)    pass "已有 $NUSER 个用户的同步数据" ;;
esac

if [ "${NUSER:-0}" != "0" ] && [ -n "$NUSER" ]; then
  CONF=$($K -n "$NS" exec deploy/todo-app -c api -- sh -c 'cat /data/users/*/conf 2>/dev/null | grep -c "^SENDKEY=SCT"' 2>/dev/null | tr -d ' \r')
  case "$CONF" in
    ''|0) note "其中填了 SendKey 的有 0 个——推送不会发，得让他们在网页「云同步」里填" ;;
    *)    pass "其中 $CONF 个填了 SendKey（到点会推）" ;;
  esac
fi

# ============ 6. 推送任务 ============
sec "6. 微信推送任务"

CJ=$($K -n "$NS" get cronjob todo-push -o jsonpath='{.spec.schedule}' 2>/dev/null)
[ -n "$CJ" ] && pass "定时任务存在，调度：$CJ（UTC，脚本内部按北京时间判断，不用管）" \
  || bad "没有 cronjob/todo-push"

LAST=$($K -n "$NS" get jobs -l app=todo-push --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
if [ -n "$LAST" ]; then
  ST=$($K -n "$NS" get job "$LAST" -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}' 2>/dev/null)
  note "最近一次跑的是 $LAST（$ST）"
else
  note "还没跑过。想立刻试：$K -n $NS create job --from=cronjob/todo-push push-test1"
fi

# ============ 7. 推送的重试计数 ============
# 这一段会真的跑一次 push-all.sh，但带 SCAN_ONLY=1：只判定、不发送、不改用户的
# .sent/.tries，所以零额度消耗。它检查的是一个沉默故障：
# 如果 .tries 只存次数、不存日期，某人某天失败到上限之后，之后每天都会被判"放弃"，
# 这个人从此再也收不到推送，而且日志看起来一切正常。
sec "7. 推送重试（失败计数会不会永久卡死）"

PUSH_SH=$($K -n "$NS" exec deploy/todo-app -c api -- sh -c 'ls /opt/todo-push/push-all.sh 2>/dev/null' 2>/dev/null | tr -d '\r')
if [ -z "$PUSH_SH" ]; then
  skip "镜像里没有 /opt/todo-push/push-all.sh，跳过重试逻辑检查（--skip-build 会这样）"
else
  FD=/data/users/zz-check-tries      # zz 开头：列表排最后，一眼看出是自检用的

  # 造一个假用户：conf 里 PUSH_AT=00:00（保证"已到点"），SENDKEY 故意留空——
  # 万一有人误以非 SCAN_ONLY 方式跑了，push-one 会直接 SKIP，不会真发。
  mk_fake() {
    $K -n "$NS" exec deploy/todo-app -c api -- sh -c '
      d=/data/users/zz-check-tries
      mkdir -p "$d"
      printf "SENDKEY=\nPUSH_AT=00:00\nNICK=check\n" > "$d/conf"
      printf "%s" "$1" > "$d/.tries"
    ' sh "$1" >/dev/null 2>&1
  }
  # 只读这个假用户的判定结果
  judge() {
    $K -n "$NS" exec deploy/todo-app -c api -- env BASE=/data SCAN_ONLY=1 TZ=Asia/Shanghai \
      /opt/todo-push/push-all.sh 2>&1 | grep 'zz-check-tries' | tail -1
  }

  TODAY_C="$(TZ=Asia/Shanghai date +%F)"

  # (1) 昨天的失败记录（3 次，早已超上限）→ 今天必须重新会推
  mk_fake "2000-01-01 3"
  L=$(judge)
  case "$L" in
    *会推*) pass "昨天的失败记录不会卡死今天（跨天归零，照常会推）" ;;
    *跳过*) bad "昨天的失败记录把今天也挡了——这个人会永久收不到推送"
            note "判定输出：${L#*→ }"
            note "说明 .tries 还是旧格式（只存次数）。确认镜像里是新版 push-all.sh" ;;
    *)      skip "没拿到判定结果（假目录建不起来？）：$L" ;;
  esac

  # (2) 老格式（纯数字，没有日期）必须被当成 0 次，否则升级上来的机器会继续卡着
  mk_fake "3"
  L=$(judge)
  case "$L" in
    *会推*) pass "旧格式 .tries（纯数字）自动失效，不会继承历史失败次数" ;;
    *跳过*) bad "旧格式 .tries 被当成今天的 3 次失败，升级后仍会卡死" ;;
    *)      skip "没拿到判定结果：$L" ;;
  esac

  # (3) 今天的失败次数照样要挡住，否则每 15 分钟重试一次会把额度刷光
  mk_fake "$TODAY_C 3"
  L=$(judge)
  case "$L" in
    *跳过*) pass "今天的失败次数照样生效（不会无限重试耗额度）" ;;
    *会推*) bad "今天已经失败到上限还在推，会把 Server酱 免费额度刷光" ;;
    *)      skip "没拿到判定结果：$L" ;;
  esac

  $K -n "$NS" exec deploy/todo-app -c api -- rm -rf "$FD" >/dev/null 2>&1 \
    && pass "重试自检的临时目录已清理" \
    || skip "临时目录没清掉，手动删：$K -n $NS exec deploy/todo-app -c api -- rm -rf $FD"
fi

# ============ 汇总 ============
cat <<EOF

────────────────────────────────────────
通过 $PASS 项，失败 $FAIL 项，跳过 $SKIP 项
EOF

if [ "$FAIL" -gt 0 ]; then
  cat <<EOF

有 $FAIL 项没过。常看的四个地方：
  $K -n $NS logs deploy/todo-app -c web --tail=30     # nginx 报错（配置错、权限）
  $K -n $NS logs deploy/todo-app -c api --tail=50     # 接口报错
  $K -n $NS describe pod -l app=todo-app | tail -30
  $K -n $NS exec deploy/todo-app -c api -- ls -lh /data/www
────────────────────────────────────────
EOF
  exit 1
fi

cat <<'EOF'

机器能验的都过了。剩下三件事只能在浏览器里点（见下面的清单）。
────────────────────────────────────────
EOF
