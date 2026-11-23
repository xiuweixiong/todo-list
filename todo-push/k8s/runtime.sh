#!/usr/bin/env bash
# 运行环境探测 —— 让同一套脚本在 k3s 和标准 k8s 上都能跑。
#
# 为什么单独抽一个文件：k3s 把 ctr 包成了 `k3s ctr`，标准 k8s 得用
# `ctr -n k8s.io`，有些集群只装了 crictl 或 nerdctl。这些差异如果散落在
# deploy.sh / import.sh / check.sh / backup.sh 四个脚本里各写一遍，
# 以后改一处就会漏三处。
#
# 【最容易踩的坑】containerd 的命名空间
#   ctr images import foo.tar          → 进 default 命名空间，kubelet 看不见
#   ctr -n k8s.io images import foo.tar → 进 k8s.io，这才是 k8s 在用的
# 导入"成功"了但 Pod 一直 ImagePullBackOff，八成就是这个。
#
# 用法：
#   . ./runtime.sh
#   K=$(rt_kubectl) || die "没有 kubectl"
#   RT_BACKEND=$(rt_backend) || die "找不到容器运行时"
#   rt_img_has docker.io/library/nginx:1.27-alpine && echo 在

# ---------- kubectl ----------
# 返回可执行的 kubectl 命令（可能是 "k3s kubectl" 这种带前缀的）
rt_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    printf 'kubectl\n'
  elif command -v k3s >/dev/null 2>&1; then
    printf 'k3s kubectl\n'
  elif command -v microk8s >/dev/null 2>&1; then
    printf 'microk8s kubectl\n'
  else
    return 1
  fi
}

# ---------- 容器运行时 ----------
# 输出：k3s-ctr / ctr / nerdctl / crictl；都没有则返回 1
rt_backend() {
  if command -v k3s >/dev/null 2>&1 && k3s ctr version >/dev/null 2>&1; then
    printf 'k3s-ctr\n'; return 0
  fi
  if command -v ctr >/dev/null 2>&1 && ctr -n k8s.io version >/dev/null 2>&1; then
    printf 'ctr\n'; return 0
  fi
  if command -v nerdctl >/dev/null 2>&1 && nerdctl -n k8s.io version >/dev/null 2>&1; then
    printf 'nerdctl\n'; return 0
  fi
  if command -v crictl >/dev/null 2>&1 && rt_crictl images >/dev/null 2>&1; then
    printf 'crictl\n'; return 0
  fi
  return 1
}

# crictl 常常因为找不到 /etc/crictl.yaml 而连不上，这里把 endpoint 显式写死
rt_crictl() {
  if [ -S /run/containerd/containerd.sock ]; then
    crictl -r unix:///run/containerd/containerd.sock "$@"
  else
    crictl "$@"
  fi
}

# 内部用：优先用调用方缓存好的 RT_BACKEND，避免每次都去跑 version
_rtb() {
  if [ -n "${RT_BACKEND:-}" ]; then printf '%s\n' "$RT_BACKEND"; else rt_backend; fi
}

# 当前后端的人话名字，用于打印
rt_backend_desc() {
  case "$(_rtb)" in
    k3s-ctr) printf 'k3s ctr（k3s 自带）' ;;
    ctr)     printf 'ctr -n k8s.io（标准 k8s / containerd）' ;;
    nerdctl) printf 'nerdctl -n k8s.io' ;;
    crictl)  printf 'crictl（能力受限，只能拉不能导）' ;;
    *)       printf '未知' ;;
  esac
}

# ---------- 镜像操作 ----------
# 列出镜像完整名（一行一个）
rt_img_ls() {
  case "$(_rtb)" in
    k3s-ctr) k3s ctr images ls -q ;;
    ctr)     ctr -n k8s.io images ls -q ;;
    nerdctl) nerdctl -n k8s.io images -q ;;
    crictl)  rt_crictl images 2>/dev/null | awk 'NR>1 {print $1":"$2}' | sed 's/:<none>$//' ;;
    *)       return 1 ;;
  esac
}

# 镜像在不在（完整名精确匹配）
rt_img_has() {
  rt_img_ls 2>/dev/null | grep -qxF "$1"
}

# 名字里包含某段（用来找"同版本但带镜像源前缀"的镜像）
rt_img_find() {
  rt_img_ls 2>/dev/null | grep -F "$1" | head -3
}

# 打 tag。crictl 没有这个能力，返回 2
rt_img_tag() {
  case "$(_rtb)" in
    k3s-ctr) k3s ctr images tag "$1" "$2" ;;
    ctr)     ctr -n k8s.io images tag "$1" "$2" ;;
    nerdctl) nerdctl -n k8s.io tag "$1" "$2" ;;
    crictl)  return 2 ;;
    *)       return 1 ;;
  esac
}

# 从仓库拉。$1=源地址 $2=目标名（crictl 没有 tag，所以直接拉目标名）$3=平台
rt_img_pull() {
  local ref=$1 dst=${2:-$1} platform=${3:-}
  case "$(_rtb)" in
    k3s-ctr|ctr|nerdctl)
      local cmd
      case "$(_rtb)" in
        k3s-ctr) cmd="k3s ctr images pull" ;;
        ctr)     cmd="ctr -n k8s.io images pull" ;;
        nerdctl) cmd="nerdctl -n k8s.io pull" ;;
      esac
      local pargs=()
      [ -n "$platform" ] && pargs+=(--platform "$platform")
      # shellcheck disable=SC2086  # cmd 需要按空格拆成多个词
      $cmd "${pargs[@]}" "$ref"
      ;;
    crictl)
      # crictl 只能按最终名拉，拉完名字天然就是对的
      rt_crictl pull "$dst"
      ;;
    *) return 1 ;;
  esac
}

# 从 tar 导入。crictl 不支持，返回 2。$2 可传 --all-platforms
rt_img_import() {
  local tar=$1 extra=${2:-}
  case "$(_rtb)" in
    k3s-ctr)
      if [ -n "$extra" ]; then k3s ctr images import "$extra" "$tar"; else k3s ctr images import "$tar"; fi ;;
    ctr)
      if [ -n "$extra" ]; then ctr -n k8s.io images import "$extra" "$tar"; else ctr -n k8s.io images import "$tar"; fi ;;
    nerdctl)
      # nerdctl 的 load 不吃 --all-platforms，tar 里的都导
      nerdctl -n k8s.io load -i "$tar" ;;
    crictl)  return 2 ;;
    *)       return 1 ;;
  esac
}

# 当前后端对应的"手命令"，出错时打印出来让用户能自己接着查
rt_hint_cmd() {
  case "$(_rtb)" in
    k3s-ctr) printf 'k3s ctr images ls -q | grep -i nginx\n' ;;
    ctr)     printf 'ctr -n k8s.io images ls -q | grep -i nginx\n' ;;
    nerdctl) printf 'nerdctl -n k8s.io images | grep -i nginx\n' ;;
    crictl)  printf 'crictl -r unix:///run/containerd/containerd.sock images | grep -i nginx\n' ;;
    *)       printf 'echo 没有可用的容器运行时\n' ;;
  esac
}

# ---------- 存储 ----------
# 找出 PVC 在宿主机上的真实目录。$1=namespace $2=pvc 名
# 依赖调用方已经设置 $K（kubectl 命令）。找不到返回 1。
rt_pvc_dir() {
  local ns=$1 name=$2 vol path d
  vol=$($K -n "$ns" get pvc "$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
  [ -n "$vol" ] || return 1

  # hostPath 类型的 PV：直接问 API，最准
  path=$($K get pv "$vol" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null)
  if [ -n "$path" ]; then printf '%s\n' "$path"; return 0; fi

  # local-path 供应器：k3s 在 /var/lib/rancher/k3s/storage/，独立装在 /opt/local-path-provisioner/
  for d in /var/lib/rancher/k3s/storage/*_"${ns}"_"${name}" \
           /opt/local-path-provisioner/*_"${ns}"_"${name}"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}
