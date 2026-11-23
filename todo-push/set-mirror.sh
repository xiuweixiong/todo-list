#!/usr/bin/env bash
# 给 docker 配镜像加速，解决拉不到 Docker Hub 的报错：
#   dial tcp 202.160.129.36:443: connect: connection refused
#
#   sudo ./set-mirror.sh               # 探测 -> 写 daemon.json -> 重启 docker -> 验证
#   sudo ./set-mirror.sh --dry-run     # 只探测，不动任何配置
#   sudo ./set-mirror.sh --no-k3s      # 顺带不生成 k3s 的 registries.yaml
#
# 会先备份原来的 daemon.json，改坏了能退回去。

set -uo pipefail

DRY=0
DO_K3S=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-k3s)  DO_K3S=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "用法: $0 [--dry-run] [--no-k3s]"; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '    \033[33m[注意]\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m[OK]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root：sudo $0"
command -v curl >/dev/null 2>&1 || die "缺 curl，先 apt install -y curl"

# 候选源。判定标准不是 "/v2/ 能不能通"，而是"能不能真的取到某个镜像的 manifest"——
# 因为有些站（比如 dockerproxy.net）根路径活着，但 /v2/library/xxx 是 404，
# 配进 daemon.json 只会让 docker 白等一轮超时。
#
# 200 = 直接给到 manifest；401 = 要 token，正常，docker 自己会去拿。这两种都算可用。
CANDS="docker.m.daocloud.io docker.1panel.live docker.1ms.run hub.rat.dev"
PROBE_PATH="v2/library/python/manifests/3.11-slim"

say "1/4 探测镜像源（超时 6 秒）"
printf '    %-38s %-6s %s\n' "源" "状态" "耗时"
GOOD=""
for h in $CANDS; do
  r=$(curl -sk -o /dev/null -m 6 -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -w '%{http_code} %{time_total}' "https://$h/$PROBE_PATH" 2>/dev/null) || r="000 99"
  code=${r%% *}
  t=${r##* }
  case "$code" in
    200|401)
      printf '    \033[32m%-38s %-6s %ss\033[0m\n' "$h" "可用" "$t"
      GOOD="$GOOD$t $h"$'\n'
      ;;
    302|429|525)
      printf '    \033[33m%-38s %-6s %s\033[0m\n' "$h" "不稳定" "$code"
      ;;
    *)
      printf '    \033[90m%-38s %-6s %s\033[0m\n' "$h" "不可用" "$code"
      ;;
  esac
done

[ -n "$GOOD" ] || die "一个源都不通。别在这死磕，改走下面任一条：
    1) 用国内地址直接构建（不配加速器）：
       docker build --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.11-slim -t todo-push:1.0 .
    2) 在一台能上网的机器上 build 好，save 成 tar 传过来：
       docker save todo-push:1.0 nginx:1.27-alpine | gzip > img.tar.gz
       gunzip -c img.tar.gz | k3s ctr images import -   （然后 ./deploy.sh --skip-build）"

# 按耗时升序，取前 3 个
PICK=$(printf '%s' "$GOOD" | sort -n | head -3 | awk '{print $2}')
say "2/4 选中（按速度排序）"
for m in $PICK; do echo "    https://$m"; done

if [ "$DRY" -eq 1 ]; then
  say "--dry-run，不写配置"
  echo "    确认无误就去掉 --dry-run 重跑一次"
  exit 0
fi

# ---------- 3. 写 docker 配置 ----------
say "3/4 写入 /etc/docker/daemon.json"
command -v docker >/dev/null 2>&1 || die "这台机器上没有 docker，先装 docker 再跑本脚本"

install -d -m 755 /etc/docker
if [ -f /etc/docker/daemon.json ]; then
  BAK="/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  cp -a /etc/docker/daemon.json "$BAK"
  ok "已备份原配置 -> $BAK"
fi

python3 - "$PICK" <<'PY' || die "写 daemon.json 失败"
import json, os, sys, shutil
p = '/etc/docker/daemon.json'
mirrors = ['https://' + m for m in sys.argv[1].split()]
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p, encoding='utf-8'))
    except Exception:
        # 原文件是坏的，留个证据再重建，别让用户以为配置丢了
        shutil.copy2(p, p + '.broken')
        print('    原 daemon.json 不是合法 JSON，已另存为 daemon.json.broken，按空配置重建')
        d = {}
d['registry-mirrors'] = mirrors
with open(p, 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('    registry-mirrors =', mirrors)
PY

systemctl daemon-reload 2>/dev/null || true
systemctl restart docker || die "重启 docker 失败，看 journalctl -u docker -n 50"
sleep 2

if docker info 2>/dev/null | grep -q "$(printf '%s' "$PICK" | head -1)"; then
  ok "docker 已加载加速配置"
else
  warn "docker info 里没看到镜像源，可能被 /etc/docker/daemon.json 之外的方式覆盖了"
fi

# ---------- 4. 验证 ----------
say "4/4 验证能不能真的拉到镜像"
if timeout 90 docker pull hello-world >/dev/null 2>&1; then
  ok "拉到 hello-world 了，说明通道通了"
  docker rmi hello-world >/dev/null 2>&1 || true
else
  warn "hello-world 还是拉不下来。依次试："
  warn "  1) curl -sI https://$(printf '%s' "$PICK" | head -1)/$PROBE_PATH  看是不是 401/200"
  warn "  2) journalctl -u docker -n 50 --no-pager"
  warn "  3) 绕开加速器，改用国内地址直接构建："
  warn "     docker build --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.11-slim -t todo-push:1.0 ."
  exit 1
fi

# ---------- k3s 也要能拉镜像 ----------
if [ "$DO_K3S" -eq 1 ] && command -v k3s >/dev/null 2>&1; then
  say "附：给 k3s 也写一份 registries.yaml（当前不生效）"
  RK=/etc/rancher/k3s/registries.yaml
  install -d -m 755 /etc/rancher/k3s
  if [ -f "$RK" ]; then
    warn "$RK 已存在，不动它。要合并请手动参考下面的内容："
    echo
    echo "mirrors:"
    echo "  docker.io:"
    echo "    endpoint:"
    printf '      - "https://%s"\n' $PICK
    echo
  else
    {
      echo "mirrors:"
      echo "  docker.io:"
      echo "    endpoint:"
      printf '      - "https://%s"\n' $PICK
    } > "$RK"
    ok "已写 $RK"
    warn "要生效得重启 k3s：systemctl restart k3s"
    warn "这会重启你机器上所有 Pod，挑个没人用的时候做"
    warn "（走 deploy.sh 的话不需要重启：它会把 nginx 也一起导入，Pod 不访问外网）"
  fi
fi

cat <<'EOF'

────────────────────────────────────────
加速器配好了。接着跑部署：

    cd /root/todo-push/k8s && ./deploy.sh

────────────────────────────────────────
EOF
