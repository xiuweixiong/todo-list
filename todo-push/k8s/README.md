# k3s 部署说明

Debian 11 + k3s。和前面那套 `install.sh`（裸机 systemd + nginx + cron）**二选一**，
数据格式完全一样，以后想换回来直接拷 `users/` 目录就行。

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

k3s 自带 `local-path` 这个 StorageClass，PVC 绑定后，真实目录在**节点的磁盘**上：

```bash
k3s kubectl -n todo get pvc todo-data
# 拿到 pvc-xxxxxxxx 这个名字后
ls -l /var/lib/rancher/k3s/storage/pvc-xxxxxxxx_todo_todo-data/
#   ├── www/index.html
#   └── users/a3f9c1d2e7b40f58/{todos.sqlite,conf,.sent}
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

然后把 PVC 里的 `storageClassName` 改成 `todo-local` 再 apply。之后备份就是熟悉的：

```bash
tar -czf /opt/backup/todo-$(date +%F).tar.gz -C /opt/data/todo users
```

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
