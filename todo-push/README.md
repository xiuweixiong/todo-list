# 待办清单 · 多用户推送服务

一台云服务器，同时干两件事：

- 提供网页（`http://你的IP:30080/`），谁打开谁用自己的待办
- 每天定时把「今天到期 / 已逾期」推到各自微信

技术栈只有你本来就熟的东西：**nginx + python3 标准库 + sqlite3 + curl + cron**，  
没有 Node、没有 Docker（k8s 部署时才有镜像）、没有数据库服务。

> **两种部署方式，二选一：**
>
> - **k3s（推荐，目前在生产用的就是这个）**：见 `k8s/README.md`，  
>   `Deployment + PVC + CronJob + NodePort` 一套清单，`deploy.sh` 一条命令装完。
> - **裸机**（本文件）：systemd + 宿主机 nginx + cron，`install.sh` 一键装。  
>   **这条路已经不再维护**，脚本还在、能跑，但新改动只在 k8s 上验证过。
>
> 仓库里的 `www/index.html` 是构建产物、不入库：先 `python _build/build.py`  
> 生成，再 `deploy.sh --html ../todo-app/待办清单.html`。
>
> 两边用的是同一份 `api.py` 和 `push-*.sh`，数据目录格式完全一样（`users/<设备码>/`），  
> 想换随时把 `users/` 拷过去就行。



---

## 一、长什么样

```
浏览器（用户 A）─┐
                 ├─ nginx:80 ─┬─ /          → www/index.html（网页本体）
浏览器（用户 B）─┘            └─ /api/todos → api.py:8099（收 sqlite）

cron 每 15 分钟 → push-all.sh → 遍历 users/*/ → push-one.sh → Server酱 → 各自微信
```

一个人的数据 = 一个目录：

```
/opt/todo-push/
├── users/
│   └── a3f9c1d2e7b40f58/     ← 设备码的 sha256 前 16 位，不是设备码本身
│       ├── todos.sqlite      ← 他上传的库，600 权限
│       ├── conf              ← SENDKEY / PUSH_AT / NICK
│       ├── .sent             ← 今天是否已推（存日期）
│       ├── .tries            ← 「日期 次数」，今天失败了几次（跨天自动归零）
│       └── last.log          ← 最近一次推送的请求与响应
├── www/index.html
├── api.py  push-all.sh  push-one.sh  env.sh  backup.sh
├── push.log                  ← 全局日志，一行一个人一天
└── .lock
```

为什么要一人一文件，而不是一个库加 user_id：备份是一个 `rsync`，删人是一个  
`rm -rf`，排障是 `tail 某个人的 last.log`。三件事都不用写 SQL，也不会误伤别人。

---

## 二、部署（三步）

```bash
# 1. 传上去（网页已经打在包里，就这一个 zip）
scp todo-push-20261117.zip root@你的IP:/root/

# 2. 装依赖（Ubuntu/Debian）
ssh root@你的IP
apt update && apt install -y unzip nginx python3 sqlite3 curl

# 3. 解压并安装
cd /root && unzip -o todo-push-20261117.zip && cd todo-push
chmod +x *.sh k8s/*.sh
sudo ./install.sh
```

包里自带 `www/index.html`，`install.sh` 会直接用它，不用再单独传网页。  
以后网页有新版（应用那边重新导出的单文件），两种更新法二选一：

```bash
# A. 只换网页，不动其他（最快）
sudo cp 待办清单.html /opt/todo-push/www/index.html

# B. 走一遍安装脚本，顺便把脚本也更新
sudo ./install.sh /root/待办清单.html
```

装完会打印 `http://IP/`，直接发给用的人。每个用户的操作见  
**`用户引导.md`**，可以直接转发。

开放端口别忘了：云厂商控制台的**安全组**放行 80，机器上如果开了 ufw/firewalld  
也要放行。

---

## 三、加人、删人、看状态

**加人不需要你做任何事。** 用户打开网页点「立即上传」，服务器自动建目录，  
`conf` 里的 SendKey 也由他填的上传带过来。

```bash
# 谁在用、各自最后同步时间
ls -lt /opt/todo-push/users/

# 一个人的配置
cat /opt/todo-push/users/a3f9c1d2e7b40f58/conf

# 一个人的库有几条
sqlite3 /opt/todo-push/users/a3f9c1d2e7b40f58/todos.sqlite "select count(*) from todos"

# 试着给某个人手动推一次（验证他的 SendKey 对不对）
/opt/todo-push/push-one.sh /opt/todo-push/users/a3f9c1d2e7b40f58
cat /opt/todo-push/users/a3f9c1d2e7b40f58/last.log
```

**踢人**：

```bash
rm -rf /opt/todo-push/users/a3f9c1d2e7b40f58
```

服务端数据立刻没了，但**那个人浏览器里的待办还在**（数据本来就在他本地），  
他只是没法再上传和收推送。要彻底断掉，让他清浏览器数据，或者你自己换 IP。

---

## 四、改推送时间 / 改内容口径

**单个人**：改 `conf` 里的 `PUSH_AT`，不用重启任何东西。

```bash
sed -i 's/^PUSH_AT=.*/PUSH_AT=07:30/' /opt/todo-push/users/<目录>/conf
```

**所有人**：因为 `push-all.sh` 是从 `conf` 逐个读的，批量改一遍就行：

```bash
sed -i 's/^PUSH_AT=.*/PUSH_AT=07:30/' /opt/todo-push/users/*/conf
```

时间必须写 `HH:MM` 两位数。cron 每 15 分钟醒一次，所以**只有 15 分钟整数倍的  
时间才是准的**（07:30 准，07:31 会变成 07:45 才发）。

**想改成"只在有逾期时才推"**：编辑 `push-one.sh`，把这段的判断条件

```bash
if [ "$N_OVER" -eq 0 ] && [ "$N_TDAY" -eq 0 ]; then
```

改成

```bash
if [ "$N_OVER" -eq 0 ]; then
```

改完不用重启，下次 cron 自动生效。

**想加"今天已完成 N 件"做收尾**：在 `push-one.sh` 里 `BODY+=` 最后那行之前插：

```bash
N_DONE=$(q "SELECT count(*) FROM todos WHERE done=1 AND substr(created_at,1,10)='$TODAY'")
BODY+="> 今天已完成 ${N_DONE} 件"$'\n\n'
```

---

## 五、备份与恢复

```bash
# 手动备份（保留 30 天）
/opt/todo-push/backup.sh

# 挂成每天凌晨 3 点自动备份
echo '0 3 * * * root /opt/todo-push/backup.sh >/dev/null 2>&1' > /etc/cron.d/todo-push-backup
```

包在 `/var/backups/todo-push/users-YYYY-MM-DD.tar.gz`。

**恢复**：

```bash
tar -xzf /var/backups/todo-push/users-2026-11-17.tar.gz -C /opt/todo-push
chown -R todopush:todopush /opt/todo-push/users
```

注意：备份的是**服务器上的副本**，最新数据可能在用户浏览器里还没同步。  
真正的数据源永远是用户本机的 localStorage，让他点一下「立即上传」再备份才准。

---

## 六、升级到 HTTPS（强烈建议，约 10 元/年）

现在的问题是：设备码在 HTTP 链路上是**明文**。同一个 WiFi 下有人抓包，  
就能拿到别人的设备码，读走他的待办。

一个最便宜的域名（`.top`/`.xyz` 首年常年在 10 元上下），配 Let's Encrypt  
免费证书，20 分钟能搞定：

```bash
# 1. 域名 A 记录指向这个 IP，等生效
apt install -y certbot python3-certbot-nginx
certbot --nginx -d todo.example.com     # 自动改 nginx 配置并配好跳转

# 2. 把 80 改成只允许 HTTPS（certbot 通常已经帮你加了跳转）
```

改完之后，**用户访问的地址**从 `http://IP/` 变成 `https://域名/`，  
页面里「服务器」那一格也要跟着改（面板里可以手动改）。

证书自动续期：`systemctl status certbot.timer` 确认一下。

另外：**域名还能让你以后换服务器不换链接**，IP 换了就得挨个通知 30 个人。

---

## 七、排障速查

| 现象                                    | 先看这里                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `docker build` 报 `connection refused` | 拉不到 Docker Hub。跑 `sudo ./set-mirror.sh`，或 `cd k8s && ./deploy.sh --base <国内镜像地址>`    |
| 网页打不开                                 | `curl -I http://127.0.0.1/` ；`systemctl status nginx` ；安全组 80 有没有放行                  |
| 网页能开，点上传报错                            | `journalctl -u todo-push-api -n 50 --no-pager` ；`curl http://127.0.0.1:8099/healthz` |
| 上传返回 `bad db`                         | 用户传的不是 sqlite 或文件损坏；`last.log`/api 日志里会写原因                                           |
| 上传返回 `too large`                      | 库超过 8MB，改 `api.py` 的 `MAX_BYTES` 和 nginx 的 `client_max_body_size`                    |
| 一切正常但微信没收到                            | 那人**没关注「方糖」服务号**（九成）；看 `users/<目录>/last.log` 的 api_code，0 才是成功                       |
| 某人一直没被推                               | `ls users/*/.sent` 看是不是标了今天；`cat conf` 看 `PUSH_AT` 写没写错                              |
| 推送重复了                                 | 检查 cron 是不是被加了第二条：`ls /etc/cron.d/`                                                  |
| 日志里一堆 FAIL                            | `grep FAIL /opt/todo-push/push.log \| tail -20`，通常是 SendKey 填错或额度用超                  |
| 时间不对                                  | `date` 看服务器时区。脚本里所有取时间的地方都套了 `TZ=Asia/Shanghai`，不受系统时区影响                             |

服务端命令：

```bash
systemctl restart todo-push-api     # 改了 api.py 之后
systemctl status todo-push-api
journalctl -u todo-push-api -f
tail -f /opt/todo-push/push.log     # 推送流水
```

---

## 八、三条必须知道的安全边界

1. **你作为运维方，能看到所有人的待办原文。** 一人一库意味着 `sqlite3` 谁都能查。  
   这个必须提前跟人讲清楚，或者只给信得过的人用。想做端到端加密就别做推送了——  
   服务器解不开内容就生成不了提醒。
2. **HTTP 下设备码是明文的。** 拿到设备码 = 能读能覆盖那一个人的全部待办。  
   所以：别把地址贴到公开场合、别在公共 WiFi 下批量指导别人操作、有条件就上 HTTPS。
3. **网页本身没有任何登录。** 任何人拿到 `http://IP/` 都能打开它（打开的是一份空的、  
   自己的待办）。真正的门是设备码，不是网址。要挡人就在 nginx 加 IP 白名单或 basic auth。

---

## 九、应用侧需要什么版本

网页必须带「云同步」面板（**v1.11 起**）。这个面板做四件事：

- 生成并显示设备码（首次打开自动生成，存 localStorage）
- 上传：`PUT /api/todos`，请求体是 `db.export()` 出来的 sqlite 原始字节
- 拉回：`GET /api/todos`，拿到字节覆盖本地库后刷新
- 把 SendKey / 推送时间一起带上（请求头 `X-Sendkey` / `X-Push-At`）

v1.10 及更早的版本没有这个面板，传上去的网页只能手动导出 `.sqlite` 再 `scp`。
