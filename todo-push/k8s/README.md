# k8s 部署说明（k3s 和标准 k8s 都适用）

清单全部是 stable API，脚本会自动识别容器运行时（`k3s ctr` / `ctr -n k8s.io` /
`nerdctl` / `crictl`），所以 kubeadm、k3s、k0s、RKE2 都能用。差别只有三处，
见下面的「一·五」——**不是 k3s 的先看那张表，能省掉一次 PVC 卡 Pending**。

> 和 `install.sh`（裸机 systemd + nginx + cron）**二选一**，数据格式完全一样，
> 以后想换回来直接拷 `users/` 目录就行。

---

## 一、跑起来是什么样

| 对象 | 作用 |
|---|---|
| `Deployment/todo-app` | **一个 Pod、两个容器**：`web`（nginx，发网页）+ `api`（同步接口） |
| `ConfigMap/todo-nginx` | nginx 的 `server` 配置，改它就能调缓存、超时、上传大小 |
| `Service/todo-web` | NodePort **30080**，对外入口 |
| `CronJob/todo-push` | 每 15 分钟一个 Job，跑 `push-all.sh` |
| `PVC/todo-data` | 2Gi，所有人共用同一个卷 |

Pod 内部：

```
浏览器 → NodePort 30080 → nginx:80 ─┬─ /          → /data/www/index.html（gzip + 304）
                                    └─ /api/todos → 127.0.0.1:8099（api 容器）
CronJob Pod ────────────────────────→ /data/users/*/todos.sqlite → Server酱
```

**为什么两个容器塞一个 Pod，而不是两个 Deployment**：nginx 反代 `127.0.0.1:8099`
就行，不用 Service、不用 DNS、不用管跨网段，而且两边天然共享同一个卷。
这是 k8s 里做「静态页 + 小后端」最省心的形状。代价是不能单独扩 api 的副本——你
30 个人用，本来也不需要扩。

**为什么网页不塞进镜像**：网页 7.8MB，每次改版都要重打镜像、重导镜像太笨。放卷里，
换网页只是 `kubectl cp` 一个文件，刷新即生效，nginx 和 api 都不用重启。

---

## 一·五、不是 k3s？先看这三处差异

| 事项 | k3s | 标准 k8s（kubeadm / k0s / RKE2） | 你要做什么 |
|---|---|---|---|
| **镜像怎么进节点** | `k3s ctr` | `ctr -n k8s.io`（**命名空间不是 k8s.io，kubelet 就看不见**） | 不用管，`import.sh` 自动探测 |
| **StorageClass** | 自带 `local-path` 且是集群默认 | 多数集群一个 SC 都没有 | 有默认 SC 就什么都不用做；没有就看第八节 |
| **多节点** | 一般单机 | 通常多节点，每台都要有镜像 | 用 `--registry` 推私有仓库 |

清单里已经把 `storageClassName` 注释掉了，意思是「跟随集群默认」——k3s 上仍然是
`local-path`，标准 k8s 上跟随你的默认 SC，**两种都不用手改 yaml**。

只有一种情况必须动手：集群里**一个 StorageClass 都没有**（`kubectl get sc` 空着）。
那时 PVC 会一直 Pending，Pod 卡在 `ContainerCreating`，解法见第八节。

---

## 二、部署（五步：构建 → 部署 → 传网页 → 自检 → 浏览器验）

### 1. 构建镜像、导入 k3s

镜像里打包的是 `api.py` + `push-*.sh`，**不含网页**（网页放卷里，改版不用重打镜像）。
nginx 用官方镜像，不用自己打。

服务器上如果装了 docker，直接在 `todo-push/` 目录：

```bash
docker build -t todo-push:1.0 .     # 基础镜像默认走国内源，见下面「拉不到镜像」
cd k8s && ./import.sh               # 两个镜像一起搞定
```

`import.sh` 对两个镜像用的是**两条不同的路**，这不是多余，是被坑出来的：

| 镜像 | 导入方式 | 原因 |
|---|---|---|
| `todo-push:1.0` | `docker save` → `ctr images import` | 自己 build 的，本地 docker 里就有，这条路稳 |
| `nginx:1.27-alpine` | `k3s ctr images pull` → `ctr images tag` | 官方镜像带 attestation 清单，`docker save` 出来的 tar 里 index 引用了那些说明层却没写进去，`ctr import` 就报 `content digest sha256:...: not found`，加 `--all-platforms` 也没用 |

所以看到 nginx 那步是「直接拉到 containerd」，不要奇怪。它会先看 containerd 里
有没有同版本的镜像（含带镜像源前缀的名字），有就直接 `tag` 改名，**一次网络都不走**。

手敲的话是这样（能连通就没问题，但 nginx 那条大概率会撞上面说的 digest 报错）：

```bash
docker save todo-push:1.0 -o /tmp/api.tar && k3s ctr images import /tmp/api.tar
k3s ctr images pull --platform linux/amd64 \
  docker.m.daocloud.io/library/nginx:1.27-alpine
k3s ctr images tag \
  docker.m.daocloud.io/library/nginx:1.27-alpine docker.io/library/nginx:1.27-alpine
k3s ctr images ls -q | grep -E 'todo-push|nginx'
```

最后一行要看到两条：

```
docker.io/library/nginx:1.27-alpine
docker.io/library/todo-push:1.0
```

**国内服务器大概率会在这一步失败**，报错长这样：

```
failed to resolve source metadata for docker.io/library/python:3.11-slim:
dial tcp 202.160.129.36:443: connect: connection refused
```

这是访问不了 Docker Hub，不是配置写错了。两个办法，任选其一：

```bash
# 办法一：配加速器（脚本会先探测哪个源还活着，再写 daemon.json）
sudo ../set-mirror.sh

# 办法二：不配加速器，只换基础镜像地址
docker build \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.11-slim \
  -t todo-push:1.0 .
```

`deploy.sh` 两个办法都支持：`./deploy.sh` 走加速器，`./deploy.sh --base <镜像地址>` 走第二条。

**基础镜像拉下来之后，下一个卡点是容器里的 `apt-get update`。**
官方 `python:3.11-slim` 的 Debian 源指向 `deb.debian.org`，国内经常几十秒不动或者
`Failed to fetch`。`Dockerfile` 里已经处理了：会依次试阿里云 → 清华 → 中科大 → 腾讯云 → 官方，
第一个能通的就用，顺便强制 IPv4（服务器没有 IPv6 时，apt 会先试 IPv6 白等一轮，这才是"卡住"的常见原因）。
构建日志里会看到：

```
==> 试 apt 源: mirrors.aliyun.com
```

正常会停在这一步往下走。如果四个国内源全试完还是不通，就手动指定：

```bash
./deploy.sh --apt-mirror mirrors.cloud.tencent.com
```

先测一下这台机器到各家源的速度，挑最快的那个：

```bash
for m in mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn \
         mirrors.ustc.edu.cn mirrors.cloud.tencent.com; do
  echo -n "$m  "
  curl -o /dev/null -s -w '%{http_code} %{time_total}s\n' \
    --max-time 8 http://$m/debian/dists/bookworm/Release
done
```

返回 `200` 且时间小的就是首选；返回 `000` 表示这个源根本连不上。

> 只有基础镜像需要拉。nginx 已经从架构里去掉了，不用再折腾它。

在 Windows 上 build 也行，镜像包大约 200MB：

```bash
docker build -t todo-push:1.0 .
docker save todo-push:1.0 | gzip > todo-push.tar.gz
scp todo-push.tar.gz root@你的IP:/root/
# 服务器上：
gunzip -c /root/todo-push.tar.gz | k3s ctr images import -
```

### 2. 部署清单

```bash
cd todo-push/k8s
k3s kubectl apply -f todo-push.yaml
k3s kubectl -n todo rollout status deploy/todo-app
```

### 3. 传网页

网页 `index.html` 已经打在包里（`todo-push/www/index.html`），不用另外准备：

```bash
POD=$(k3s kubectl -n todo get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')
k3s kubectl -n todo cp ../www/index.html $POD:/data/www/index.html -c api
```

两处容易踩的：

- `kubectl cp` **不认** `deploy/todo-app` 这种简写（`exec`/`logs` 认，`cp` 不认），必须传 Pod 名，
  否则报 `pods "todo-app" not found`。
- 必须 `-c api`。`web` 容器（nginx）的 `/data` 是 `readOnly: true`，往它里面写会报
  `Read-only file system`。nginx 只负责读，写由 api 容器做——这样即使网页被误改，
  nginx 也改不动它。

传完立刻验：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30080/`，要 `200`。

状态码对照（传网页这一步最常见的就是这三个）：

| 码 | 含义 | 怎么修 |
|---|---|---|
| `200` | 通了 | — |
| `403` | nginx 在跑，`/data/www` 里没有 `index.html` | 就是这次没传成功，重传 |
| `404` | nginx 的 root 路径不对 | 查 ConfigMap 里的 `root /data/www` |
| `000` | 连不上 | Pod 没起来，或 30080 被安全组挡了 |

`403` 不是权限问题，是「目录存在但没有首页文件」，nginx 不肯列目录就返回 403。

然后访问 `http://你的IP:30080/`。云厂商安全组记得放行 **30080**。

或者一条命令全干完（会自动找 `../www/index.html`，找不到才退回同级的 `待办清单.html`）：

```bash
./deploy.sh --skip-build      # 镜像已经 import 过
./deploy.sh                   # 节点上有 docker，连构建一起做
```

---

### 4. 验证

#### 先单独验 Server酱（跟 k8s 无关）

推送是整套系统里唯一依赖外部服务的环节。先用一个脚本把这条线单独通掉，
出问题就不用怀疑是 k8s 的锅：

```bash
bash ../test-push.sh SCT你的SendKey              # 真发一条
bash ../test-push.sh SCT你的SendKey --dry        # 只看地址，不发，不耗额度
```

成功判据是响应体里的 `"code":0`，**不是 HTTP 状态码**——key 错的时候
`sctapi` 返回 HTTP 400，而 `*.push.ft07.com` 反而返回 HTTP 200 + `code:10003`，
只看 HTTP 会把失败当成功。

#### 再跑自检脚本

机器能验的它全验一遍（约 10 秒）：

```bash
./check.sh
```

它检查六层，每项打 ✓ 或 ✗：

| 检查 | 说明 |
|---|---|
| 集群 / 存储 | 命名空间在、PVC 是 `Bound`（不是 Bound 说明数据没落盘） |
| 应用 Pod | 1/1 就绪、`api` 和 `web` 两个容器都 ready、有无异常重启、nginx 配置的 ConfigMap 在不在 |
| 网页 | 首页 HTTP 200、大小是否 7.5MB 左右（太小说明网页没传完）、gzip 生效否、第二次打开是否 304 |
| 同步接口 | **真跑一遍闭环**：造一个临时 sqlite 上传 → 读回 → md5 比对 → 再提交一个坏文件看会不会被拒 |
| 真实数据 | 已有几个用户的同步数据、其中几个人填了 SendKey |
| 推送任务 | 定时任务在不在、最近一次执行结果 |

最后那个「坏文件被拒」很重要，它证明用户误传坏库时**不会把已有待办覆盖掉**。

自检用的是临时设备码（32 个 `f`），跑完会把测试数据删干净，不影响真人数据。

### 5. 浏览器里点一遍（这部分机器验不了）

自检过了只说明服务和接口通，最后一公里得自己点：

1. **打开** `http://你的IP:30080/` ——能看到待办列表，右下角有ずんだもん
2. **建一条**：点「新建」写点东西 → **刷新页面**，条目还在（说明本机存储正常，跟服务器无关）
3. **同步上传**：点底部「云同步」→ 面板展开，里面已经有自动生成的**设备码**（32 位）
   - 「服务器地址」**留空**（网页就是这台服务器提供的，同源，不用填）
   - 点「立即上传」，状态行会变成已同步
   - 回服务器上看：`k3s kubectl -n todo exec deploy/todo-app -c api -- ls -R /data/users`
     应该多出一个 16 位十六进制名字的目录，里面有 `todos.sqlite`
4. **同步拉回**：换台设备/换个浏览器打开同一个地址 →「云同步」→ 把第 3 步那串设备码**贴进去** →
   点「从云端拉回」→ 待办回来了。这一步等于验证了「换手机不丢数据」
5. **推送**：在同一个面板填 SendKey（`SCT` 开头）和推送时间（`08:00`）→ 再点「立即上传」，
   然后服务器上确认写进去了：
   ```bash
   k3s kubectl -n todo exec deploy/todo-app -c api -- cat /data/users/*/conf
   ```
   想立刻试推送，不用等到 8 点：
   ```bash
   k3s kubectl -n todo create job --from=cronjob/todo-push push-test1
   k3s kubectl -n todo logs -l app=todo-push --tail=30
   ```

**设备码等于钥匙**，谁拿到谁就能读写那个人的待办。别截图发群里。

---

## 三、持久化存储（这是关键）

### 数据到底落在哪

PVC 绑定后，真实目录在**节点的磁盘**上。路径取决于 StorageClass：

```bash
# 让脚本直接告诉你（k3s / 标准 k8s 通用，会读 PV 定义和几个常见位置）
./check.sh | grep 数据目录

# 自己看也行：
kubectl -n todo get pvc todo-data -o jsonpath='{.spec.storageClassName}{"\n"}'
kubectl get pv $(kubectl -n todo get pvc todo-data -o jsonpath='{.spec.volumeName}') -o yaml | grep -A3 hostPath
```

两种常见结果：

```
k3s 默认 local-path  → /var/lib/rancher/k3s/storage/pvc-xxxxxxxx_todo_todo-data/
自己写的 hostPath PV → /opt/data/todo/          （你在 PV 里指定的那个路径）
    ├── www/index.html
    └── users/a3f9c1d2e7b40f58/{todos.sqlite,conf,.sent}
```

它是**节点本地盘**，不是网络存储。含义很直接：

- Pod 重建、重启、滚动更新、节点重启 → 数据都在
- 节点被删 / 重装系统 / 重装 k3s → 数据没了

所以**备份 = 备份这个目录**，别无他法。用现成脚本：

```bash
./backup.sh                 # → backups/users-2026-11-17.tar.gz，保留 30 天
./backup.sh --restore backups/users-2026-11-17.tar.gz
```

挂到宿主机 cron 每天跑一次（k3s 的 CronJob 也能跑，但备份写到卷里没意义，
不如写到宿主机磁盘，用宿主 cron 更实在）：

```bash
echo '0 3 * * * root cd /opt/todo-push/k8s && ./backup.sh /opt/backup >/dev/null 2>&1' > /etc/cron.d/todo-backup
```

### 想放到自己指定的目录（推荐给运维）

`local-path` 的目录名带随机 uid，而且重装 k3s 会一起没。如果你希望数据待在
一个自己说了算的路径，比如 `/opt/data/todo`，用它自己的 PV：

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: todo-data-pv
spec:
  capacity:
    storage: 2Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain    # 删 PVC 不删数据，这点比 local-path 安全
  storageClassName: todo-local
  hostPath:
    path: /opt/data/todo
    type: DirectoryOrCreate
```

然后指定它即可，不用手改 yaml：

```bash
./deploy.sh --skip-build --storage-class todo-local
```

之后备份就是熟悉的：

```bash
tar -czf /opt/backup/todo-$(date +%F).tar.gz -C /opt/data/todo users
```

> **PVC 的 storageClassName 创建后不可改。** 已经部署过再想换，必须先删 PVC
> （数据一起没，先 `./backup.sh`），所以一开始就定好。`deploy.sh` 检测到 PVC
> 已存在会直接跳过，不会去动它。

两种都行，看你习惯：
`local-path` 少写 20 行 yaml；`hostPath + Retain` 路径可控、误删 PVC 不丢数据。

### 三个关于 RWO 的注意点

**1. 默认只能一个节点挂。** `local-path` 是 `ReadWriteOnce`，多节点集群里只有
卷所在的那个节点能挂。你现在是单机 k3s，无感；将来加了节点，CronJob 的 Pod
可能被调度到别的节点上，表现是 Job 一直 `ContainerCreating` 卡住。解决办法二选一：

```yaml
# 办法 A：把 CronJob 钉在同一台节点上
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: 你的节点名
```

```yaml
# 办法 B：换支持 ReadWriteMany 的存储（Longhorn / NFS），accessModes 改 RWX
```

**2. Deployment 必须 `strategy: Recreate`。** 已经写在清单里了。用滚动更新的话，
新旧两个 Pod 会同时挂这个目录写 `users/`，30 个人正在同步时容易撞车。

**3. `local-path` 删 PVC 就删数据。** `persistentVolumeReclaimPolicy` 是 `Delete`。
手滑 `kubectl delete pvc` 会把 30 个人的库一起带走。用 hostPath+Retain 就没这个坑。
这条比什么都重要，清单里我给了注释。

### 容量

30 个人、每人 1000 条待办，一个库也就 60KB 上下，`users/` 总共不到 5MB。
给 2Gi 是留着余量——因为 `local-path` **不支持在线扩容**，改大小要删 PVC 重建，
特意一次给够。

---

## 四、想用 80 端口，不想带 :30080

k3s 默认带 Traefik，80 端口已经被它占了。最稳的是继续用 NodePort，地址丑一点但
零冲突。如果一定要 `http://IP/`，加一条**不带 host** 的 Ingress 当兜底：Traefik 里
带 Host 的规则优先级更高，不会抢你其他应用的域名。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: todo-catchall
  namespace: todo
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: todo-web
                port:
                  number: 80
```

风险说清楚：这是**兜底规则**，所有没匹配到具体 Host 的请求都会落到待办页上。
哪天你想让某个应用直接用 IP 访问，会先撞到它。

---

## 五、日常运维

```bash
K="k3s kubectl -n todo"

$K get pod -o wide                       # 看 Pod 在哪个节点
$K logs deploy/todo-app -c web --tail=50 # nginx：谁打开了网页、有没 4xx/5xx
$K logs deploy/todo-app -c api -f        # 谁什么时候同步了
$K exec deploy/todo-app -c api -- tail -n 50 /data/push.log    # 推送流水
$K exec deploy/todo-app -c api -- ls -l /data/users/           # 有多少人在用

# 手动跑一次推送（验证某个人的 SendKey 对不对）
$K create job --from=cronjob/todo-push push-manual-$(date +%s)
$K logs job/push-manual-xxxx

# 改完 api.py 后重新上线
docker build -t todo-push:1.0 . && docker save todo-push:1.0 -o /tmp/t.tar && k3s ctr images import /tmp/t.tar
$K rollout restart deploy/todo-app

# 只换网页，不需要重启（网页在 PVC 里，cp 进去立即生效）
POD=$($K -n todo get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')
$K -n todo cp ../www/index.html $POD:/data/www/index.html -c api
```

**改 nginx 配置**（调超时、加缓存头、限流都在这里）：

```bash
vi todo-push.yaml          # 改 ConfigMap 里 default.conf 的内容
k3s kubectl apply -f todo-push.yaml
k3s kubectl -n todo rollout restart deploy/todo-app     # 让 nginx 重读配置
```

⚠️ 只 `apply` 不改 `configmap-rev` 那个注解的话，Pod 不会重建，nginx 还是跑老配置。
要么每次改配置顺手把注解值加一，要么 apply 之后补一条 `rollout restart`（推荐后者，
省得记）。改完 nginx 起不来会直接 CrashLoop，用 `-c web` 的日志能看到是第几行配置错了。

`imagePullPolicy: IfNotPresent` 是故意的：镜像从本地 containerd import 进来，
不走仓库，也就没有 `latest` 缓存问题。改了代码一定要重新 build + import，
否则重启拉到的还是旧镜像。

---

## 六、踩过的坑（省你时间）

| 现象 | 原因 |
|---|---|
| `dial tcp ...:443: connect: connection refused` / `failed to resolve source metadata` | 拉不到 Docker Hub。跑 `../set-mirror.sh`，或 `./deploy.sh --base <国内镜像地址>` |
| 构建停在 `==> 试 apt 源: xxx` 不动，或 `Ign:` / `Failed to fetch` / `Temporary failure resolving` | 容器里 Debian 源慢。Dockerfile 会自动换国内源试四个，全不通就 `./deploy.sh --apt-mirror <最快那个源>` |
| Pod 卡在 `ImagePullBackOff` | 镜像没进 k3s 库。看 `describe pod` 里是哪个镜像：`todo-push:1.0` 或 `nginx:1.27-alpine`，跑 `./import.sh` 它会逐个核对 |
| `k3s ctr images import` 报 `content digest sha256:...: not found` | 两种原因。① tar 残包（`df -h /tmp` 空间不足，`docker save` 写一半停了）；② **官方镜像的 attestation 清单**：`docker save` 出来的 tar 里 index 引用了那些说明层，但没把它们的 blob 写进去，import 逐项去找就报错——这种情况加 `--all-platforms`、`--digests` 全都没用。②的解法是别再走 save/import，改用 `k3s ctr images pull`，`import.sh` 对 nginx 就是这么做的 |
| nginx 已经在 containerd 里，但 Pod 还是 `ImagePullBackOff` | 名字不一样。清单要的是 `nginx:1.27-alpine`（= `docker.io/library/nginx:1.27-alpine`），镜像源拉下来的叫 `docker.m.daocloud.io/library/nginx:1.27-alpine`。`k3s ctr images tag 旧名 docker.io/library/nginx:1.27-alpine` 即可，不用重新拉 |
| Pod 起不来，日志 `bad interpreter: bash\r` | 脚本在 Windows 编辑过，CRLF 行尾。镜像里已经用 `sed -i 's/\r$//'` 兜住了 |
| 网页 403（首页打不开） | nginx 在跑，但 `/data/www` 里没有 `index.html`——就是网页没传上去。传见上面第 3 步（注意 `cp` 只认 Pod 名、要 `-c api`） |
| 网页 404 | nginx 的 root 路径不对。查 ConfigMap 里的 `root /data/www`，以及部署里挂的是 `subPath: default.conf` |
| 网页 502 / 504 | nginx 通了但连不上 api 容器。`log` 看 `-c api`（是不是崩了）、`BIND` 是不是 `0.0.0.0` |
| 改了 ConfigMap，nginx 还是用旧配置 | Pod 不会自动重读。改完把 Deployment 注解 `configmap-rev` 换个值再 `apply`，或 `rollout restart` |
| 健康检查一直失败，Pod 反复重启 | `BIND` 写成 `127.0.0.1` 了。kubelet 是从节点打 **Pod IP**，必须 `0.0.0.0` |
| CronJob 卡在 `ContainerCreating` | 多节点 + RWO 卷，见上面「三个注意点」 |
| 网页能开、点同步报 `Failed to fetch` | 页面不是从 `http://IP:30080` 打开的。用本地双击的 html 去连这个接口，要跨域，虽然接口带了 CORS 头，但混合内容（https 页面请求 http）会被浏览器挡掉 |
| `kubectl cp` 报 `pods "todo-app" not found` | `cp` 只认 Pod 名，不认 `deploy/todo-app` 这种简写（`exec`/`logs` 才认）。先 `POD=$($K -n todo get pod -l app=todo-app -o jsonpath='{.items[0].metadata.name}')` 再传 |
| `kubectl cp` 报 `Read-only file system` | 传到 `web` 容器了，它的 `/data` 是 `readOnly: true`。加 `-c api` |
| `kubectl cp` 报 `tar: not found` | 容器里缺 tar。走节点直拷：`cp 文件 /var/lib/rancher/k3s/storage/*_todo_todo-data/www/index.html`，再 `chown 1000:1000` |
| 往 `/data/www` 写报 `Permission denied` | initContainer 没把 `/data/www` 的属主给到 1000。当前清单已修；老清单要 `apply` 一遍并让 Pod 重建 |
| CronJob 一个都没跑 | 看 `k3s kubectl -n todo get cronjob -o yaml` 的 `lastScheduleTime`，再用 `create job --from=cronjob` 手动触发一次看日志 |
| CronJob 在跑、`push.log` 里只有 `TICK 处理0 失败0`，一条都不推 | 脚本扫的是空目录。数据目录 `BASE` 和脚本目录被混成了一个（老版本 `push-all.sh` 用脚本目录覆盖了 `BASE`），去扫 `/opt/todo-push/users` 了。新版本已拆成 `SELF` / `BASE`；改完必须**重新 build 镜像**才生效，光 `cp` 脚本进 Pod 没用（CronJob 每次都是新 Pod） |
| 日志里 `FAIL 数据目录 /xxx 不存在或不可写` | `BASE` 指错了，或容器 uid 写不进那个目录。k8s 里必须是 `/data` |
| 推送时间不对（8 点没推、下午才推） | `date` 拿不到 tzdata，退化成 UTC。镜像里装了 `tzdata`、CronJob 也设了 `TZ=Asia/Shanghai`；自己改镜像的话别把这层删了 |

---

## 七、这套东西占多少资源

| 项 | 实际 |
|---|---|
| web 容器（nginx） | 常驻约 10MB |
| api 容器 | 常驻约 30MB（sqlite 库都在磁盘，只有请求时读） |
| CronJob | 每天 96 次，每次存活 1～2 秒 |
| 镜像 | 约 200MB（python:3.11-slim + sqlite3/curl） |
| 卷 | 实际用不到 5MB |

一台 1C2G 的 k3s 跑这个完全没压力。

---

## 八、标准 k8s（kubeadm / k0s / RKE2）从零走一遍

前面二～七节的动作完全一样，这里只补差异部分。前提：`kubectl get nodes` 正常，
节点上跑的是 containerd（kubeadm 默认就是）。

### 1. 存储：有没有默认 StorageClass

```bash
kubectl get sc
```

- 输出里有带 `(default)` 的 → **这一步跳过**，什么都不用做
- 一个都没有 → PVC 会永远 Pending，Pod 一直 `ContainerCreating`

补一个最简单的（单节点够用，多节点请上 Longhorn / NFS）：

```yaml
# todo-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: todo-data-pv
spec:
  capacity:
    storage: 2Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain    # 删 PVC 不删数据
  storageClassName: todo-local
  hostPath:
    path: /opt/data/todo
    type: DirectoryOrCreate
```

```bash
kubectl apply -f todo-pv.yaml
./deploy.sh --storage-class todo-local --html ../www/index.html
```

注意 `storageClassName` 那两个地方必须是**同一个名字**（PV 里叫 `todo-local`，
`--storage-class` 也传 `todo-local`），否则 PVC 绑不上。

### 2. 镜像：单节点直接导，多节点走仓库

**单节点**（和 k3s 一样，一条命令）：

```bash
./deploy.sh --html ../www/index.html
```

脚本会用 `ctr -n k8s.io` 把镜像导进 containerd。想手动做就是这三条：

```bash
ctr -n k8s.io images import /tmp/todo-push.tar          # 自己 build 的那个
ctr -n k8s.io images pull --platform linux/amd64 \
    docker.m.daocloud.io/library/nginx:1.27-alpine
ctr -n k8s.io images tag \
    docker.m.daocloud.io/library/nginx:1.27-alpine \
    docker.io/library/nginx:1.27-alpine
```

`-n k8s.io` 不能省。用 `ctr images import`（默认 `default` 命名空间）导进去，
`ctr images ls` 看得到、`crictl images` 看不到、Pod 起来还是 `ImagePullBackOff`——
这个坑花的时间足够你把整份文档读三遍。

**多节点**：镜像必须推到仓库，否则 Pod 调度到没导镜像的节点就拉不到。

```bash
docker login registry.example.com
./deploy.sh --registry registry.example.com/todo --html ../www/index.html
```

私有仓库还要让节点能拉，二选一：

```bash
# A. 只给这个命名空间用（推荐，最小权限）
kubectl -n todo create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot --docker-password='***'
```

然后给 Pod 加上（`deploy.sh` 不会自动加，一处 Deployment 一处说明）：

```yaml
    spec:
      imagePullSecrets:
        - name: regcred
```

```bash
# B. 挂在 default ServiceAccount 上（影响整个命名空间）
kubectl -n todo patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

顺手提醒：清单里是 `imagePullPolicy: IfNotPresent`，**同名 tag 重复推不会自动
更新**。要发新版本请改 tag（`todo-push:1.1`），别指望 push 完节点就会换。

### 3. 想用域名 / 80 端口

清单默认 NodePort 30080，不依赖任何 Ingress。集群里有 ingress-nginx 的话可以加：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: todo
  namespace: todo
spec:
  ingressClassName: nginx          # kubectl get ingressclass 看一眼你的叫什么
  rules:
    - host: todo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: todo-web
                port:
                  number: 80
```

### 4. 自检

```bash
./check.sh                        # 在节点上，走 127.0.0.1:30080
./check.sh --host 10.0.0.5        # 从别的机器，换成节点 IP
```

### 5. 报错对照

| 现象 | 原因 |
|---|---|
| Pod `ContainerCreating`，`describe` 里 `pod has unbound immediate PersistentVolumeClaims` | 没有可用 StorageClass，做上面第 1 步 |
| PVC `Pending`，`describe pvc` 里 `no persistent volumes available` | 写了 `storageClassName` 但没有对应的 PV/供应器，名字对不上 |
| `ImagePullBackOff`，Events 里 `failed to pull` | 镜像不在该节点（多节点）；或私有仓库没配 `imagePullSecrets` |
| Events 里 `forbidden: violates PodSecurity "restricted:latest"` | 命名空间开了 restricted，nginx 要 root 起 master。给这个命名空间打 `baseline`：`kubectl label ns todo pod-security.kubernetes.io/enforce=baseline` |
| 首页 403，其余都正常 | 网页没传进卷：`./deploy.sh --skip-build --html ../www/index.html` |
| 首页 000 / 连不上 | 云安全组没放行 30080；或 `kubectl get svc todo-web` 的 nodePort 不是 30080 |

---

## 九、脚本是怎么判断"这是 k3s 还是标准 k8s"的

不想读代码就看这三行结论：

| 判断 | 顺序 |
|---|---|
| kubectl | 有 `kubectl` 用 `kubectl` → 只有 `k3s` 用 `k3s kubectl` → 只有 `microk8s` 用 `microk8s kubectl` |
| 镜像后端 | `k3s ctr` → `ctr -n k8s.io` → `nerdctl -n k8s.io` → `crictl` |
| 数据目录 | 先读 PV 的 `hostPath.path`，再试 `/var/lib/rancher/k3s/storage/*_todo_todo-data`、`/opt/local-path-provisioner/*` |

全部在 `runtime.sh` 里，四个脚本共用。想强制指定可以临时改这个文件，或者在
`deploy.sh` 里传 `--registry`（这样就完全不走本地导入，用不到运行时探测）。

---

## 十、千万别 `kubectl delete -f todo-push.yaml`

这个文件第一段是 **Namespace**。`delete -f` 会把整个命名空间删掉：

```
Namespace todo ──┬── Deployment / Service / CronJob   （删了没事，重新 apply 就有）
                 └── PVC todo-data ──── 用户全部待办数据   ← 这个删了就真没了
```

`local-path` 这类本地供应器的回收策略是 Delete，PVC 一删，节点上那个目录
（`/var/lib/rancher/k3s/storage/pvc-xxx_todo_todo-data/`）跟着被清掉，**没有回收站**。

**只改配置就用 apply**，apply 是幂等的，改多少遍都不会删数据。
真要重来：先 `./backup.sh`，然后只删应用层：

```bash
kubectl -n todo delete deploy todo-app
kubectl -n todo delete cronjob todo-push
kubectl -n todo delete cm todo-nginx
kubectl -n todo delete svc todo-web
kubectl -n todo delete pvc todo-data      # ← 只有这句会毁数据，想清楚再敲
```

### 命名空间卡在 Terminating 怎么救

删掉命名空间后它会先进入 `Terminating`，期间**任何新建资源的请求都会被拒**：

```
unable to create new content in namespace todo because it is being terminated
```

正常情况几十秒自己消失。卡住通常是这两件事：

**1. Pod 还没退干净**（有 Pod 在用 PVC，PVC 就删不掉，命名空间就结束不了）

```bash
kubectl -n todo get pod
kubectl -n todo delete pod --all --force --grace-period=0
```

**2. PVC 的 finalizer 没被摘掉**

```bash
kubectl -n todo get pvc todo-data -o jsonpath='{.metadata.finalizers}{"\n"}'
# 通常剩 kubernetes.io/pvc-protection
```

Pod 清光后它一般会自己掉；还不掉就手动摘：

```bash
kubectl -n todo patch pvc todo-data -p '{"metadata":{"finalizers":null}}' --type=merge
```

**3. 还不动，说明命名空间本身有 finalizer 卡着**，直接改它的 finalize 接口：

```bash
kubectl get ns todo -o json > /tmp/ns.json
python3 - <<'PY'
import json
d = json.load(open("/tmp/ns.json"))
d["spec"]["finalizers"] = []
json.dump(d, open("/tmp/ns-final.json", "w"))
PY
kubectl replace --raw "/api/v1/namespaces/todo/finalize" -f /tmp/ns-final.json
kubectl get ns todo          # 没输出 = 已经彻底没了
```

清完 `./deploy.sh --html ../www/index.html` 会重新建命名空间、PVC、把网页传上去。
注意：**数据是新的空库**，除非你有 `backup.sh` 的备份。
