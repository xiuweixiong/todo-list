#!/usr/bin/env bash
# 一键部署。在解压出来的目录里执行：
#   sudo ./install.sh                       # 用包里自带的 www/index.html
#   sudo ./install.sh /path/to/待办清单.html  # 或者手动指定网页文件（更新版本时用）
#
# 重复执行是安全的：目录不会删，用户数据不动，只覆盖程序文件和网页。

set -euo pipefail

BASE=/opt/todo-push
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 在 Windows 上编辑过的话文件会带 CRLF，bash 会报 "bad interpreter: bash\r"。
# 先就地修一遍，省得排查半天。
for f in "$SRC"/*.sh "$SRC"/*.py "$SRC"/*.conf "$SRC"/*.service; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

# 网页文件：命令行参数优先，其次是包里自带的 www/index.html，最后看根目录
HTML="${1:-}"
if [ -z "$HTML" ]; then
  for c in "$SRC/www/index.html" "$SRC/index.html"; do
    [ -f "$c" ] && { HTML="$c"; break; }
  done
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '    \033[33m[注意]\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 检查 ----------
[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo ./install.sh"

MISSING=""
for c in python3 sqlite3 curl flock; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  echo "缺少命令：$MISSING"
  echo "Ubuntu/Debian: apt update && apt install -y python3 sqlite3 curl util-linux nginx"
  echo "CentOS/RHEL:   yum install -y python3 sqlite curl util-linux nginx"
  die "装完再跑一次"
fi

HAS_NGINX=0
command -v nginx >/dev/null 2>&1 && HAS_NGINX=1

# ---------- 1. 目录 ----------
say "1/8 建目录"
# 注意：$BASE 必须是 755，否则 nginx 的 worker（www-data）进不去，网页打不开。
# 真正要挡人的是 users/ 那一层，设 700。
install -d -m 755 "$BASE"
install -d -m 700 "$BASE/users"
install -d -m 755 "$BASE/www"
# 老数据不动，只确保存在

# ---------- 2. 程序 ----------
say "2/8 放程序文件"
for f in env.sh push-one.sh push-all.sh api.py backup.sh; do
  [ -f "$SRC/$f" ] || die "包里缺文件：$f"
  install -m 755 "$SRC/$f" "$BASE/$f"
done

# ---------- 3. 网页 ----------
say "3/8 放网页"
if [ -n "$HTML" ]; then
  [ -f "$HTML" ] || die "找不到网页文件：$HTML"
  install -m 644 "$HTML" "$BASE/www/index.html"
  echo "    index.html  $(du -h "$BASE/www/index.html" | cut -f1)"
else
  warn "没提供网页文件，稍后手动放：cp 待办清单.html $BASE/www/index.html"
fi

# ---------- 4. 账号 ----------
say "4/8 建服务账号"
if ! id todopush >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -d "$BASE" todopush
  echo "    已创建系统账号 todopush"
else
  echo "    账号 todopush 已存在"
fi
chown -R todopush:todopush "$BASE/users" "$BASE"/*.sh "$BASE"/*.py
chown todopush:todopush "$BASE"
chmod 700 "$BASE/users"

# ---------- 5. 接口服务 ----------
say "5/8 安装接口服务"
install -m 644 "$SRC/todo-push-api.service" /etc/systemd/system/todo-push-api.service
systemctl daemon-reload
systemctl enable todo-push-api >/dev/null 2>&1 || true
systemctl restart todo-push-api
sleep 1
if curl -fsS --max-time 3 http://127.0.0.1:8099/healthz >/dev/null 2>&1; then
  echo "    接口已启动（127.0.0.1:8099）"
else
  warn "接口没起来，看日志：journalctl -u todo-push-api -n 30 --no-pager"
fi

# ---------- 6. 定时任务 ----------
say "6/8 安装定时任务（每 15 分钟检查一次）"
cat > /etc/cron.d/todo-push <<EOF
# 待办清单推送。每 15 分钟醒一次，谁到点推谁，没到点什么都不做。
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * todopush $BASE/push-all.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/todo-push
echo "    /etc/cron.d/todo-push 已写入"

# ---------- 7. 反向代理 ----------
say "7/8 配置网页入口"
if [ "$HAS_NGINX" -eq 1 ]; then
  install -m 644 "$SRC/nginx-todo-push.conf" /etc/nginx/conf.d/todo-push.conf
  # Debian/Ubuntu 的默认站点会抢占 80 端口的 default_server，冲突时自动让路
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    echo "    nginx 已加载 todo-push 配置"
  else
    warn "nginx 配置冲突，多半是默认站点占着 80。执行下面这条再试："
    warn "  rm -f /etc/nginx/sites-enabled/default && systemctl reload nginx"
  fi
else
  warn "没装 nginx，接口只监听 127.0.0.1，网页打不开。二选一："
  warn "  A) apt install -y nginx && ./install.sh   （推荐）"
  warn "  B) 改 /etc/systemd/system/todo-push-api.service 里 BIND=0.0.0.0 PORT=80，"
  warn "     再 systemctl daemon-reload && systemctl restart todo-push-api"
fi

# ---------- 8. 自检 ----------
say "8/8 自检"
IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
IP=${IP:-你的服务器IP}

echo "    接口      $(curl -s --max-time 3 http://127.0.0.1:8099/healthz || echo '不通')"
[ -f "$BASE/www/index.html" ] && echo "    网页      $(du -h "$BASE/www/index.html" | cut -f1)" \
                              || echo "    网页      缺失"

cat <<EOF

────────────────────────────────────────
部署完成。把下面这个地址发给用的人：

    http://$IP/

他们打开就能用，同样的待办数据存在各自浏览器里，互不影响。

第一次用要做的三件事：
  1. 点页面底部「云同步」展开面板
  2. 填自己的 SendKey（怎么拿见「用户引导.md」）
  3. 点「立即上传」，看到"已同步"就成了

剩下的活在这台机器上：
  看谁同步了   ls -l $BASE/users/
  看推送记录   tail -f $BASE/push.log
  加人/删人    见 README.md 第三节
  改推送时间   见 README.md 第四节

安全提醒：现在是 HTTP，设备码在链路上是明文。只把这台机器的 80 端口
开放给这几个人用，别往公开地方贴地址。有条件就按 README 第六节加 HTTPS。
────────────────────────────────────────
EOF
