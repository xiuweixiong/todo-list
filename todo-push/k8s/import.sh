#!/usr/bin/env bash
# 把镜像弄进节点的 containerd。两个镜像：todo-push:1.0 和 nginx:1.27-alpine。
#
# 支持 k3s 和标准 k8s（containerd），运行时差异都在 runtime.sh 里处理：
#   k3s        → k3s ctr
#   标准 k8s   → ctr -n k8s.io（命名空间必须是 k8s.io，否则 kubelet 看不见）
#   其他       → nerdctl -n k8s.io；crictl 只能拉不能导
#
# 为什么这一个脚本这么长 —— 因为这两个镜像的最优导入路径不一样：
#
#   todo-push:1.0      自己 build 的，本地 docker 里就有，走 docker save -> images import
#   nginx:1.27-alpine  官方镜像，带 attestation（构建溯源）清单，docker save 出来的
#                      tar 里 index 会引用那些说明层，但 save 没把它们的 blob 写进去，
#                      于是导入时报 "content digest sha256:xxx: not found"，
#                      加 --all-platforms / --digests 都没用（试过了）。
#
# 所以 nginx 走 containerd 自己的 pull：它解析 index 时会跳过不匹配平台和 attestation，
# 拉下来是干净的。拉完再打 tag 改成 k8s 清单要的标准名。
#
# 用法：
#   ./import.sh                                  # 两个都弄
#   ./import.sh --nginx-ref <镜像地址>            # 换 nginx 来源（默认 daocloud）
#   ./import.sh --skip-nginx                     # 只弄 todo-push

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=runtime.sh
. ./runtime.sh

API_IMG=todo-push:1.0
NGINX_IMG=nginx:1.27-alpine
# k8s 清单写的是 nginx:1.27-alpine，kubelet 会解析成这个完整名去 containerd 里找
NGINX_FULL=docker.io/library/nginx:1.27-alpine
NGINX_REF=docker.m.daocloud.io/library/nginx:1.27-alpine
SKIP_NGINX=0

while [ $# -gt 0 ]; do
  case "$1" in
    --nginx-ref)   NGINX_REF="${2:?--nginx-ref 后面要跟镜像地址}"; shift 2 ;;
    --nginx-src)   NGINX_REF="${2:?-}"; shift 2 ;;
    --skip-nginx)  SKIP_NGINX=1; shift ;;
    --with-nginx)  SKIP_NGINX=0; shift ;;   # 老参数，现在默认就导
    *) echo "用法: $0 [--nginx-ref 镜像地址] [--skip-nginx]"; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m    OK\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

RT_BACKEND=$(rt_backend) || die "找不到容器运行时。k3s 节点上要有 k3s 命令；标准 k8s 节点上要有 ctr（containerd 自带）或 nerdctl。
   检查：command -v k3s ctr nerdctl crictl"
echo "    运行时：$(rt_backend_desc)"

HAVE_DOCKER=0
command -v docker >/dev/null 2>&1 && HAVE_DOCKER=1

# 本机架构，pull 时指定，避免去要别的平台的 blob
case "$(uname -m)" in
  x86_64|amd64) PLATFORM=linux/amd64 ;;
  aarch64|arm64) PLATFORM=linux/arm64 ;;
  *) PLATFORM="" ;;
esac

have_docker_img() { [ "$HAVE_DOCKER" -eq 1 ] && docker image inspect "$1" >/dev/null 2>&1; }

# ---------- 1. todo-push:1.0 ----------
say "1/4 检查 $API_IMG"
if [ "$HAVE_DOCKER" -eq 0 ] && ! rt_img_has "docker.io/library/$API_IMG"; then
  die "既没有 docker，节点里也没有 $API_IMG。镜像得先在能 build 的机器上打好再传过来"
fi
if have_docker_img "$API_IMG"; then
  ok "docker 里有 $API_IMG"
elif rt_img_has "docker.io/library/$API_IMG"; then
  ok "节点里已经有 $API_IMG，跳过导入"
else
  die "docker 里没有 $API_IMG，先 build：cd .. && docker build -t $API_IMG ."
fi

# 磁盘空间：docker save 写满会把 tar 截断，导入时报错看着像镜像坏了
AVAIL=$(df -Pk /tmp | awk 'NR==2{print int($4/1024)}')
if [ "${AVAIL:-0}" -lt 1024 ]; then
  warn "/tmp 只剩 ${AVAIL}MB，可能写不下镜像包。先清理或换目录"
fi

# ---------- 2. 导 todo-push:1.0 ----------
say "2/4 导入 $API_IMG"
if rt_img_has "docker.io/library/$API_IMG"; then
  ok "节点里已有，跳过"
elif ! have_docker_img "$API_IMG"; then
  warn "docker 里没有 $API_IMG，跳过"
else
  safe=$(printf '%s' "$API_IMG" | tr ':/' '__')
  tar=/tmp/k3s-import-$safe.tar

  if ! docker save "$API_IMG" -o "$tar"; then
    warn "docker save 失败（多半是 No such image 或磁盘满）"
    rm -f "$tar"
  else
    size=$(stat -c%s "$tar" 2>/dev/null || echo 0)
    if [ "$size" -lt 1048576 ]; then
      warn "tar 只有 $size 字节，明显不完整，丢掉"
      rm -f "$tar"
    elif ! tar -tf "$tar" >/tmp/k3s-tar-list.txt 2>/tmp/k3s-tar.err; then
      warn "tar 读不出来，包是坏的（可能是磁盘写满）"
      sed 's/^/      /' /tmp/k3s-tar.err | head -3
      rm -f "$tar"
    else
      echo "    $(du -h "$tar" | cut -f1)  $tar，包内 $(wc -l < /tmp/k3s-tar-list.txt) 个条目"
      if rt_img_import "$tar" 2>/tmp/k3s-import.err; then
        ok "已导入"
      elif rt_img_import "$tar" --all-platforms 2>>/tmp/k3s-import.err; then
        ok "已导入（--all-platforms）"
      else
        warn "导入失败，报错："
        sed 's/^/      /' /tmp/k3s-import.err | tail -6
        case "$RT_BACKEND" in
          crictl)
            warn "crictl 不支持从 tar 导入。换成 ctr 再跑："
            echo "      ctr -n k8s.io images import $tar"
            echo "      或者把镜像推到私有仓库，用 ./deploy.sh --registry <前缀>"
            ;;
        esac
      fi
      rm -f "$tar"
    fi
  fi
fi

# ---------- 3. nginx ----------
say "3/4 准备 $NGINX_IMG"
if [ "$SKIP_NGINX" -eq 1 ]; then
  echo "    --skip-nginx，跳过"
elif rt_img_has "$NGINX_FULL"; then
  ok "节点里已经有 $NGINX_FULL，跳过"
else
  # 可能之前以带镜像源前缀的名字躺在里面了，直接打 tag 成标准名，零网络
  EXIST=$(rt_img_find "nginx:1.27-alpine")
  if [ -n "$EXIST" ]; then
    echo "    containerd 里已有同版本镜像，打上标准名（不联网）："
    printf '%s\n' "$EXIST" | sed 's/^/      /'
    for src in $EXIST; do
      [ "$src" = "$NGINX_FULL" ] && continue
      if rt_img_tag "$src" "$NGINX_FULL" 2>/dev/null; then
        ok "tagged $src -> $NGINX_FULL"
        break
      fi
    done
  fi

  # 首选：containerd 自己拉。绕开 docker save/import 的 attestation 问题
  if ! rt_img_has "$NGINX_FULL"; then
    echo "    从 $NGINX_REF 直接拉到 containerd（绕过 docker save/import）"
    if rt_img_pull "$NGINX_REF" "$NGINX_FULL" "$PLATFORM" 2>/tmp/k3s-pull.err; then
      ok "拉取成功"
      if [ "$NGINX_REF" != "$NGINX_FULL" ]; then
        if rt_img_tag "$NGINX_REF" "$NGINX_FULL" 2>/dev/null; then
          ok "已改名为 $NGINX_FULL（k8s 清单要的就是这个）"
        elif [ "$RT_BACKEND" = "crictl" ]; then
          ok "crictl 直接按标准名拉的，不需要改名"
        else
          warn "改名失败，只能让清单直接用 $NGINX_REF"
          echo "      补救：kubectl -n todo set image deploy/todo-app web=$NGINX_REF"
        fi
      fi
    else
      warn "containerd 直接拉失败："
      sed 's/^/      /' /tmp/k3s-pull.err | tail -5

      # 退路：docker pull 再 save/import。这条路对 nginx 的 attestation 可能不通，
      # 但万一你这台机器的 docker 是老版本（save 出来不带 index），反而能成
      if [ "$HAVE_DOCKER" -eq 1 ]; then
        echo "    退回 docker 路线：pull -> save -> import"
        docker pull --platform "${PLATFORM:-linux/amd64}" "$NGINX_REF" >/dev/null 2>&1 \
          || warn "docker pull $NGINX_REF 也失败"
        if have_docker_img "$NGINX_REF"; then
          safe=nginx
          tar=/tmp/k3s-import-$safe.tar
          if docker save "$NGINX_REF" -o "$tar" 2>/dev/null; then
            rt_img_import "$tar" --all-platforms 2>/tmp/k3s-import2.err \
              && ok "已导入（docker 路线）" \
              || { warn "import 仍失败："; sed 's/^/      /' /tmp/k3s-import2.err | tail -4; }
            rm -f "$tar"
          fi
          # save 出来的名字带前缀，tag 一下
          rt_img_tag "$NGINX_REF" "$NGINX_FULL" 2>/dev/null && ok "已改名为 $NGINX_FULL"
        fi
      fi
    fi
  fi
fi

# ---------- 4. 校验 ----------
say "4/4 校验镜像库"
LIST=$(rt_img_ls 2>/dev/null)
FAIL=0
if printf '%s\n' "$LIST" | grep -qxF "docker.io/library/$API_IMG"; then
  ok "$API_IMG 在节点里"
else
  warn "$API_IMG 不在节点里"
  FAIL=1
fi
if [ "$SKIP_NGINX" -eq 0 ]; then
  if printf '%s\n' "$LIST" | grep -qxF "$NGINX_FULL"; then
    ok "$NGINX_IMG 在节点里"
  else
    warn "$NGINX_IMG 不在节点里（Pod 会卡在 ImagePullBackOff）"
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  cat <<HINT

    镜像没进去。按这个顺序查：

      1) 现在 containerd 里到底有什么（当前后端：$(rt_backend_desc)）：
           $(rt_hint_cmd)
        如果看到的是带前缀的名字（如 $NGINX_REF），
        手动改名即可，不用重新拉：
           ctr -n k8s.io images tag $NGINX_REF $NGINX_FULL
         （k3s 上把 "ctr -n k8s.io" 换成 "k3s ctr"）

      2) 换一家镜像源（实测能用的另外两个）：
           ./import.sh --nginx-ref docker.1ms.run/library/nginx:1.27-alpine
           ./import.sh --nginx-ref docker.1panel.live/library/nginx:1.27-alpine

      3) 磁盘：
           df -h /tmp /var/lib/rancher /var/lib/containerd
         空间不足会让 docker save 写出残包，导入时表现为
         "content digest ... not found" —— 看着像镜像坏了，其实是没写全

      4) 多节点集群：本脚本只处理当前这台机器。
         别的节点要么也跑一遍，要么用 ./deploy.sh --registry <私有仓库前缀>
         把镜像推到仓库，让每台节点自己拉。

HINT
  exit 1
fi

say "全部就绪"
echo "    下一步： kubectl apply -f todo-push.yaml"
echo "        或： ./deploy.sh --skip-build"
