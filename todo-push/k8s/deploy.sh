#!/usr/bin/env bash
# 在集群节点上执行。做五件事：构建镜像 -> 镜像就位 -> 部署 -> 传网页 -> 自检
#
# k3s 和标准 k8s 都能跑（运行时差异见 runtime.sh）。
#
#   ./deploy.sh                        # 全套（节点上要装 docker）
#   ./deploy.sh --skip-build           # 镜像已经好了，只部署
#   ./deploy.sh --html /path/x.html    # 指定网页文件
#   ./deploy.sh --base <镜像地址>       # 拉不到 Docker Hub 时换基础镜像
#   ./deploy.sh --nginx <镜像地址>      # 换 nginx 来源（默认 daocloud）
#   ./deploy.sh --apt-mirror <域名>     # 容器内 apt 卡住时指定 Debian 源
#
# 标准 k8s 额外两个参数（k3s 一般用不上）：
#   ./deploy.sh --storage-class longhorn    # 指定 PVC 的 StorageClass
#   ./deploy.sh --storage-class -           # 不指定，用集群默认（默认就是这行为）
#   ./deploy.sh --registry registry.x.com/todo   # 推到私有仓库，多节点必备
#
# 两个镜像：todo-push:1.0（自己 build）+ nginx:1.27-alpine（网页服务）。
# nginx 由 import.sh 用 containerd 直接拉，不走 docker save（那条路会撞上
# 官方镜像的 attestation 清单，报 content digest not found）。
#
# 拉不到 Docker Hub（connection refused / failed to resolve）时，二选一：
#   A) 先跑 ../set-mirror.sh 配加速器，再照常 ./deploy.sh
#   B) 不配加速器，直接指定国内镜像：
#      ./deploy.sh \
#        --base  docker.m.daocloud.io/library/python:3.11-slim \
#        --nginx docker.m.daocloud.io/library/nginx:1.27-alpine
#
# 重复执行安全：apply 是幂等的，网页会被覆盖成新版。
# 已有 PVC 不会重复 apply（storageClassName 不可变，硬 apply 会报错）。

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=runtime.sh
. ./runtime.sh

NS=todo
LOCAL_TAG=todo-push:1.0
HTML=""
SKIP_BUILD=0
BASE_IMAGE=""
APT_MIRROR=""
NGINX_REF=""
STORAGE_CLASS=""
REGISTRY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --html)  HTML="${2:?--html 后面要跟文件路径}"; shift 2 ;;
    --base)  BASE_IMAGE="${2:?--base 后面要跟镜像地址}"; shift 2 ;;
    --nginx) NGINX_REF="${2:?--nginx 后面要跟镜像地址}"; shift 2 ;;
    --apt-mirror) APT_MIRROR="${2:?--apt-mirror 后面要跟域名，如 mirrors.cloud.tencent.com}"; shift 2 ;;
    --storage-class) STORAGE_CLASS="${2:?--storage-class 后面要跟 StorageClass 名字，或 - 表示用默认}"; shift 2 ;;
    --registry) REGISTRY="${2:?--registry 后面要跟仓库前缀，如 registry.example.com/todo}"; shift 2 ;;
    *) echo "用法: $0 [--skip-build] [--html 文件] [--base 镜像] [--nginx 镜像] [--apt-mirror 域名] [--storage-class 名字|-] [--registry 前缀]"; exit 1 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m    OK\033[0m %s\n' "$*"; }
note(){ printf '    %s\n' "$*"; }
die() { printf '\n\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 环境探测 ----------
K=$(rt_kubectl) || die "没找到 kubectl（k3s 节点上会退化成 k3s kubectl，也没找到）
   标准 k8s：kubectl 应该在 PATH 里；k3s：确认 k3s 命令可用"
$K get nodes >/dev/null 2>&1 || die "kubectl 连不上集群（检查 KUBECONFIG / 是否在 master 节点上）"

RT_BACKEND=""
if [ -z "$REGISTRY" ]; then
  RT_BACKEND=$(rt_backend) || die "找不到容器运行时，镜像没法进节点。
   有 docker 也不够——kubelet 只认 containerd 里的镜像。检查：
     command -v k3s ctr nerdctl crictl"
  note "kubectl：$K"
  note "运行时：$(rt_backend_desc)"
else
  note "kubectl：$K"
  note "镜像走私有仓库：$REGISTRY（跳过本地导入，多节点各自去拉）"
fi

# 镜像最终名字
if [ -n "$REGISTRY" ]; then
  REGISTRY="${REGISTRY%/}"      # 去掉尾部斜杠，免得出现 // 
  IMG="$REGISTRY/todo-push:1.0"
else
  IMG="$LOCAL_TAG"
fi

# ---------- 1. 构建镜像 ----------
if [ "$SKIP_BUILD" -eq 0 ]; then
  say "1/5 构建镜像 $LOCAL_TAG"
  command -v docker >/dev/null 2>&1 || die "节点上没有 docker。请在能 build 的机器上打好镜像再传过来，然后加 --skip-build"

  # --base / --apt-mirror 都是可选参数，只在传了的时候才加进命令行
  BUILD_ARGS=()
  if [ -n "$BASE_IMAGE" ]; then
    BUILD_ARGS+=(--build-arg "BASE_IMAGE=$BASE_IMAGE")
    note "基础镜像：$BASE_IMAGE"
  else
    note "基础镜像：Dockerfile 默认（docker.m.daocloud.io/library/python:3.11-slim）"
  fi
  if [ -n "$APT_MIRROR" ]; then
    BUILD_ARGS+=(--build-arg "APT_MIRROR=$APT_MIRROR")
    note "apt 源：$APT_MIRROR"
  fi

  # ${arr[@]+...}：bash 4.4 之前，set -u 下展开空数组会报「未绑定的变量」
  if ! docker build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -t "$LOCAL_TAG" ../ 2>&1 | tail -40; then
    cat <<'HINT'

    构建失败。对号入座：

    A) 拉不到基础镜像（错误里有 connection refused / i/o timeout /
       failed to resolve source metadata，发生在 load metadata for ... 阶段）：
       Dockerfile 默认走 docker.m.daocloud.io，它也不通就按顺序试：
         1) 本地可能已经有这个镜像了，只是名字不一样，打个 tag 就不用联网：
              docker images | grep python
              docker tag <上面列出来的那个> docker.m.daocloud.io/library/python:3.11-slim
         2) 换一家镜像源（1ms.run / 1panel.live 实测也能用）：
              ./deploy.sh \
                --base  docker.1ms.run/library/python:3.11-slim \
                --nginx docker.1ms.run/library/nginx:1.27-alpine
         3) 配加速器：sudo ../set-mirror.sh 然后重跑本脚本

    B) 卡在 apt-get update（画面停在 "==> 试 apt 源: ..." 不动，或者
       错误里有 Ign: / Failed to fetch / Temporary failure resolving）：
         基础镜像已经拉下来了，只是容器里 Debian 源慢。
         Dockerfile 会自动依次试阿里云、清华、中科大、腾讯云，正常情况下会自己过去。
         全都试完还不行，就手动指定一个（在 Dockerfile 里是第一个试的）：
            ./deploy.sh --apt-mirror mirrors.cloud.tencent.com
         先在这台机器上测一下哪个快：
            for m in mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn \
                     mirrors.ustc.edu.cn mirrors.cloud.tencent.com; do
              echo -n "$m  "; curl -o /dev/null -s -w '%{http_code} %{time_total}s\n' \
                --max-time 8 http://$m/debian/dists/bookworm/Release
            done

HINT
    die "构建中断"
  fi
else
  say "1/5 跳过构建"
fi

# ---------- 2. 镜像就位 ----------
if [ -n "$REGISTRY" ]; then
  say "2/5 推镜像到 $REGISTRY"
  command -v docker >/dev/null 2>&1 || die "推仓库需要 docker（用来 tag 和 push）"
  docker image inspect "$LOCAL_TAG" >/dev/null 2>&1 || die "本地没有 $LOCAL_TAG，先建一次再推（去掉 --skip-build）"
  docker tag "$LOCAL_TAG" "$IMG"
  docker push "$IMG" || die "push 失败。检查 3 件事：
   1) 有没有登录：docker login $REGISTRY
   2) 仓库里那个项目（命名空间）建了吗
   3) 节点上有没有对应的 imagePullSecrets（私有仓库要配，见 README）"
  ok "已推送 $IMG"
  note "注意：清单里 imagePullPolicy 是 IfNotPresent，同名 tag 重复推不会自动更新。"
  note "     真要更新请在 Dockerfile 里改版本号，或者临时改成 Always。"
else
  say "2/5 导入镜像到节点"
  IMPORT_ARGS=()
  if [ -n "$NGINX_REF" ]; then
    IMPORT_ARGS+=(--nginx-ref "$NGINX_REF")
    note "nginx 来源：$NGINX_REF"
  fi
  bash ./import.sh ${IMPORT_ARGS[@]+"${IMPORT_ARGS[@]}"} || die "镜像没进节点。上面有逐条结论，Pod 现在起了也会 ImagePullBackOff"
fi

# ---------- 3. 部署 ----------
say "3/5 应用清单"

# 把多文档清单拆开，才能做到"已有 PVC 不重复 apply"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
# 目录通过环境变量传给 awk：用 -v 传带反斜杠的路径（Windows）会被当成转义序列
SPLIT_DIR="$TMPD" awk '
  BEGIN { n = 0; d = ENVIRON["SPLIT_DIR"] }
  /^---[[:space:]]*$/ { n++; next }
  { print > (d "/doc" n ".yaml") }
' todo-push.yaml

NS_FILE=""; PVC_FILE=""; REST=()
for f in "$TMPD"/doc*.yaml; do
  [ -f "$f" ] || continue
  KIND=$(grep -m1 '^kind:' "$f" | awk '{print $2}')
  [ -n "$KIND" ] || { rm -f "$f"; continue; }
  # 按 kind 改名：真要报错时，报错信息里的文件名能直接看出是哪个资源
  NF="$TMPD/$KIND.yaml"
  [ "$f" = "$NF" ] || mv -f "$f" "$NF"
  case "$KIND" in
    Namespace)             NS_FILE=$NF ;;
    PersistentVolumeClaim) PVC_FILE=$NF ;;
    *)                     REST+=("$NF") ;;
  esac
done

# 指定了 StorageClass 就写进 PVC 那一段（没指定则保持注释状态，跟随集群默认）
if [ -n "$STORAGE_CLASS" ] && [ "$STORAGE_CLASS" != "-" ] && [ -n "$PVC_FILE" ]; then
  if grep -q '^  # storageClassName:' "$PVC_FILE"; then
    sed -i "s|^  # storageClassName:.*|  storageClassName: $STORAGE_CLASS|" "$PVC_FILE"
  else
    sed -i "/^spec:/a\\  storageClassName: $STORAGE_CLASS" "$PVC_FILE"
  fi
  note "StorageClass：$STORAGE_CLASS"
fi

# 用私有仓库时，把清单里的镜像名换掉
if [ -n "$REGISTRY" ]; then
  for f in ${REST[@]+"${REST[@]}"}; do
    sed -i "s|image: $LOCAL_TAG|image: $IMG|g" "$f"
  done
fi

# 顺序：命名空间 -> PVC（不存在才建） -> 其余
if [ -n "$NS_FILE" ]; then
  $K apply -f "$NS_FILE" >/dev/null
fi

if [ -n "$PVC_FILE" ]; then
  if $K -n "$NS" get pvc todo-data >/dev/null 2>&1; then
    CUR=$($K -n "$NS" get pvc todo-data -o jsonpath='{.spec.storageClassName}' 2>/dev/null) || CUR=""
    note "PVC todo-data 已存在（StorageClass=${CUR:-集群默认}），跳过，不动它"
    if [ -n "$STORAGE_CLASS" ] && [ "$STORAGE_CLASS" != "-" ] && [ "$STORAGE_CLASS" != "$CUR" ]; then
      note "  你传的 --storage-class $STORAGE_CLASS 不会生效：PVC 的 StorageClass 创建后不可改。"
      note "  真要换：先 ./backup.sh 备份，再删 PVC（数据会丢）后重跑。"
    fi
  else
    $K apply -f "$PVC_FILE" >/dev/null
    note "PVC todo-data 已创建"
  fi
fi

if [ "${#REST[@]}" -eq 0 ]; then
  die "清单解析异常：todo-push.yaml 里没找到 Deployment / Service / CronJob，检查文件有没有被改坏"
fi
# 一次 apply 多个文件：必须给每个文件各写一个 -f
# 写成 "apply -f a.yaml b.yaml" 会被 kubectl 拒绝（Unexpected args）
APPLY_ARGS=()
for f in ${REST[@]+"${REST[@]}"}; do APPLY_ARGS+=(-f "$f"); done
$K apply "${APPLY_ARGS[@]}"
$K -n "$NS" rollout status deploy/todo-app --timeout=180s || \
  die "Pod 没起来，看：$K -n $NS describe pod -l app=todo-app
   常见原因：PVC 没绑上（kubectl -n $NS get pvc）、镜像不在节点（kubectl -n $NS describe pod 看 Events）"

# ---------- 4. 传网页 ----------
if [ -z "$HTML" ]; then
  for c in ./index.html ../www/index.html ../index.html "../../todo-app/待办清单.html"; do
    [ -f "$c" ] && { HTML="$c"; break; }
  done
fi

say "4/5 上传网页"
if [ -z "$HTML" ] || [ ! -f "$HTML" ]; then
  echo "    [跳过] 没找到网页文件。手动传（cp 只认 Pod 名）："
  echo "    POD=\$($K -n $NS get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')"
  echo "    $K -n $NS cp 待办清单.html \$POD:/data/www/index.html -c api"
else
  POD=$($K -n "$NS" get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}') || POD=""
  # 必须写进 api 容器：web 容器（nginx）的 /data 是 readOnly 挂载，
  # 往 web 里 cp 会直接报 Read-only file system。
  if $K -n "$NS" cp "$HTML" "$POD:/data/www/index.html" -c api; then
    echo "    已传到 $POD:/data/www/index.html（$(du -h "$HTML" | cut -f1)）"
  else
    # kubectl cp 依赖容器里有 tar，且目录属主得对。不通就直接写宿主机目录——
    # 数据本来就在本机磁盘上，绕开容器反而更快。路径由 runtime.sh 探测
    # （local-path 在 /var/lib/rancher/k3s/storage，hostPath 直接读 PV 定义）。
    echo "    [kubectl cp 失败] 改用节点直拷："
    if DIR=$(rt_pvc_dir "$NS" todo-data); then
      mkdir -p "$DIR/www"
      cp "$HTML" "$DIR/www/index.html" && chown 1000:1000 "$DIR/www" "$DIR/www/index.html" \
        && echo "    已直接写入 $DIR/www/index.html" \
        || echo "    直拷也失败了，检查 $DIR 的权限"
    else
      echo "    没找到数据目录（PV 不是 local-path / hostPath，或者不是在这台节点上）"
      echo "    多节点 + 共享存储时只能靠 kubectl cp，先看容器里有没有 tar："
      echo "      $K -n $NS exec deploy/todo-app -c api -- which tar"
    fi
  fi

  # 传完立刻验一次，别等第 5 步才发现没生效
  sleep 1
  HCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:30080/" || echo 000)
  if [ "$HCODE" = "200" ]; then
    echo "    首页 HTTP 200 ✓"
  else
    echo "    首页 HTTP $HCODE ✗"
    case "$HCODE" in
      000) echo "      000 = 连不上：先看 Pod 起没起，$K -n $NS get pod" ;;
      403) echo "      403 = nginx 在跑但 /data/www 里没有 index.html，就是这次没传成功" ;;
      404) echo "      404 = nginx 的 root 路径不对，检查 ConfigMap 里 root /data/www" ;;
      502|504) echo "      502/504 = nginx 连不上 api 容器，看 $K -n $NS logs deploy/todo-app -c api" ;;
    esac
  fi
fi

# ---------- 5. 自检 ----------
say "5/5 自检"
# hostname -I 是 iproute2 扩展，busybox / 精简系统没有；配合 set -e 会在这里
# 把整个脚本搞成"部署成功了却报失败"，所以失败也要吞掉
NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || NODE_IP=""
NODE_IP=${NODE_IP:-节点IP}
sleep 2
U=http://127.0.0.1:30080

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$U/" || echo 000)
SIZE=$(curl -s -o /dev/null -w '%{size_download}' --max-time 60 "$U/" || echo 0)
GSIZE=$(curl -s -o /dev/null -w '%{size_download}' --max-time 60 \
        -H 'Accept-Encoding: gzip' "$U/" || echo 0)

echo "    网页   $U/  -> HTTP $CODE"
echo "    体积   明文 $((SIZE / 1024))KB    gzip $((GSIZE / 1024))KB（手机走 gzip，省流量）"
echo "    接口   $(curl -s --max-time 3 "$U/healthz" || echo 不通)"
echo "    存储   $($K -n $NS get pvc todo-data -o jsonpath='{.status.phase}' 2>/dev/null)"
echo "    容器   $($K -n $NS get pod -l app=todo-app -o jsonpath='{.items[0].status.containerStatuses[*].name}' 2>/dev/null)  就绪 $($K -n $NS get deploy todo-app -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"

cat <<EOF

────────────────────────────────────────
部署完成，把下面这个地址发给用的人：

    http://$NODE_IP:30080/

云安全组要放行 30080 端口。

日常命令：
  $K -n $NS get pod -w                    # 看 Pod
  $K -n $NS logs deploy/todo-app -c web   # nginx 访问日志（谁开了网页、有哪些 4xx/5xx）
  $K -n $NS logs deploy/todo-app -c api   # 接口日志（谁什么时候同步了）
  $K -n $NS exec deploy/todo-app -c api -- tail -n 40 /data/push.log
  $K -n $NS create job --from=cronjob/todo-push push-manual   # 立刻手动跑一次推送
  ./backup.sh                             # 备份所有人数据
────────────────────────────────────────
EOF
