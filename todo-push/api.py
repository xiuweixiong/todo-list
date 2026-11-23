#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""待办清单：同步接口 + 网页托管。只用 Python 标准库，不需要 pip install 任何东西。

接口
  GET  /            返回 www/index.html（整个网页就是这一个文件）
  PUT  /api/todos   请求头 X-Token: 32 位十六进制设备码
                    可选 X-Sendkey / X-Push-At / X-Nick
                    请求体 = sqlite 文件的原始字节
  GET  /api/todos   请求头 X-Token，返回这个设备码对应的 sqlite
  GET  /healthz     返回 ok，给监控和安装脚本用

网页托管：k8s 部署里由同 Pod 的 nginx 负责发 `/data/www/index.html`，本进程只处理
`/api/todos` 和 `/healthz`。但下面这套也留着，是刻意的兜底：
  - nginx 起不来 / 配置改坏时，直接 `kubectl port-forward` 到 8099 就能打开网页排障
  - 单机跑（裸机 install.sh）时根本不装 nginx，就靠它
  - 支持 gzip（7.8MB 的网页压完约 3.8MB，手机加载快很多）
  - 带 ETag，第二次打开走 304，几乎不耗流量
  - 网页更新（kubectl cp 进去）后按 mtime 自动重新加载，不用重启

三条硬规矩
  1. 先写 todos.sqlite.tmp，校验通过后 os.replace 原子替换。
     cron 读的时候永远读不到写了一半的文件。
  2. 落盘前校验文件头 + PRAGMA integrity_check + todos 表结构。
     校验不过就丢弃、保留旧文件，用户不会因为一次上传失败丢掉待办。
  3. 设备码只记前 8 位，请求正文一个字都不进日志。

配置（环境变量）
  BASE  数据目录，默认 /opt/todo-push
  PORT  监听端口，默认 8099
  BIND  监听地址，默认 127.0.0.1（给同机的 nginx 反代用）。
        k8s 里必须设 0.0.0.0：探针是 kubelet 从节点打 Pod IP 过来的，
        只听 127.0.0.1 的话健康检查永远失败，Pod 会一直重启
"""

import base64
import hashlib
import os
import re
import sqlite3
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("BASE", "/opt/todo-push")
USERS = os.path.join(BASE, "users")
STATIC = os.path.join(BASE, "www")
PORT = int(os.environ.get("PORT", "8099"))
BIND = os.environ.get("BIND", "127.0.0.1")
MAX_BYTES = 8 * 1024 * 1024

TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")
SENDKEY_RE = re.compile(r"^(SCT[A-Za-z0-9]{8,64}|sctp[0-9]{1,10}t[A-Za-z0-9]{4,64})$")
HHMM_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
# 昵称会写进 conf 并被 bash source，必须卡死字符集，只允许字母数字下划线横杠和汉字
NICK_RE = re.compile(u"^[A-Za-z0-9_\\-\u4e00-\u9fa5]{1,16}$")


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def udir(token):
    return os.path.join(USERS, hashlib.sha256(token.encode("utf-8")).hexdigest()[:16])


def verify(path):
    """返回 None 表示合格，否则返回错误原因。"""
    try:
        with open(path, "rb") as f:
            if f.read(16) != b"SQLite format 3\x00":
                return "not sqlite"
    except OSError as e:
        return "read error: %s" % e

    try:
        con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
        try:
            row = con.execute("PRAGMA integrity_check").fetchone()
            if not row or row[0] != "ok":
                return "integrity_check: %s" % (row[0] if row else "?")
            names = {r[0] for r in con.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            if "todos" not in names:
                return "no todos table"
            cols = {r[1] for r in con.execute("PRAGMA table_info(todos)")}
            if not {"id", "content", "done"} <= cols:
                return "todos columns incomplete"
        finally:
            con.close()
    except sqlite3.Error as e:
        return "sqlite error: %s" % e
    return None


def write_conf(d, hdrs):
    """只认 SENDKEY / PUSH_AT / NICK 三个字段，其它一律忽略。"""
    path = os.path.join(d, "conf")
    cur = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        k, v = line.split("=", 1)
                        v = v.strip()
                        # 老版本写的是 NICK='老王'，读回来得把引号剥掉，
                        # 否则每次上传都会多套一层引号，最后把 conf 写坏
                        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                            v = v[1:-1]
                        cur[k.strip()] = v
        except OSError:
            pass

    sk = (hdrs.get("X-Sendkey") or "").strip()
    if sk and SENDKEY_RE.match(sk):
        cur["SENDKEY"] = sk

    at = (hdrs.get("X-Push-At") or "").strip()
    if at and HHMM_RE.match(at):
        cur["PUSH_AT"] = at

    nick = ""
    # 昵称可能是中文。HTTP 头理论上只允许 ASCII，浏览器会按 UTF-8 塞进来、
    # 服务端按 latin-1 解出来就成了乱码。所以优先用 base64 那一版，最干净。
    raw_b64 = (hdrs.get("X-Nick-B64") or "").strip()
    if raw_b64:
        try:
            nick = base64.b64decode(raw_b64).decode("utf-8")
        except Exception:
            nick = ""
    if not nick:
        raw = (hdrs.get("X-Nick") or "").strip()
        try:
            nick = raw.encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            nick = raw
    if nick and NICK_RE.match(nick):
        cur["NICK"] = nick

    if not cur:
        return
    cur.setdefault("PUSH_AT", "08:00")
    cur.setdefault("SENDKEY", "")
    cur.setdefault("NICK", "")

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# 由 api.py 自动生成，改完需要重启 api 服务才不影响下次上传\n")
        # 三个值都经过上面的正则白名单，不含空格、引号、$、反引号，
        # 因此不加引号直接写，bash source 也不会出问题
        f.write("SENDKEY=%s\n" % cur.get("SENDKEY", ""))
        f.write("PUSH_AT=%s\n" % cur.get("PUSH_AT", "08:00"))
        f.write("NICK=%s\n" % cur.get("NICK", ""))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# 网页只有 index.html 一个文件，读进内存后常驻，省掉每次请求都读 7.8MB 磁盘。
# 用 mtime 判断要不要重新加载：kubectl cp 换了新网页，下一次请求就自动生效。
_STATIC = {"mtime": None, "raw": b"", "gz": b"", "etag": '""'}


def load_static():
    """返回 (原始字节, gzip 字节, etag)；文件不存在返回 None。"""
    path = os.path.join(STATIC, "index.html")
    try:
        st = os.stat(path)
    except OSError:
        return None

    if _STATIC["mtime"] == st.st_mtime_ns and _STATIC["raw"]:
        return _STATIC["raw"], _STATIC["gz"], _STATIC["etag"]

    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return None

    # 31 = 带 gzip 头（不是裸 deflate），这样浏览器直接认，不用额外处理
    co = zlib.compressobj(6, zlib.DEFLATED, 31)
    gz = co.compress(raw) + co.flush()
    etag = '"%x-%x"' % (int(st.st_mtime), len(raw))

    _STATIC.update(mtime=st.st_mtime_ns, raw=raw, gz=gz, etag=etag)
    log("STATIC %d bytes (gzip %d) mtime=%s" % (len(raw), len(gz), int(st.st_mtime)))
    return raw, gz, etag


class Handler(BaseHTTPRequestHandler):
    server_version = "todo-push/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # ---------- 基础设施 ----------
    def _cors(self):
        # 页面和接口同源时用不到；但用户直接双击本地 html 来同步时要靠它
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers",
                         "X-Token, X-Sendkey, X-Push-At, X-Nick, X-Nick-B64, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, POST, OPTIONS")

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _token(self):
        t = (self.headers.get("X-Token") or "").strip().lower()
        return t if TOKEN_RE.match(t) else None

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Max-Age", "86400")
        self._cors()
        self.end_headers()

    # ---------- 上传 ----------
    def do_PUT(self):
        tok = self._token()
        if not tok:
            return self._send(400, b"bad token")

        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0:
            return self._send(411, b"need content-length")
        if n > MAX_BYTES:
            return self._send(413, b"too large")

        d = udir(tok)
        os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = os.path.join(d, "todos.sqlite.tmp")

        got = 0
        with open(tmp, "wb") as f:
            while got < n:
                chunk = self.rfile.read(min(65536, n - got))
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)

        if got != n:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return self._send(400, b"short body")

        err = verify(tmp)
        if err:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            log("REJECT %s %s" % (os.path.basename(d), err))
            return self._send(400, ("bad db: " + err).encode("utf-8"))

        final = os.path.join(d, "todos.sqlite")
        os.replace(tmp, final)
        os.chmod(final, 0o600)
        write_conf(d, self.headers)

        # 注意：故意不动 .sent。今天已经推过就不再补推一次，
        # 否则每同步一次就多消耗一条额度。新数据明天生效。

        log("SYNC %s… %d bytes" % (os.path.basename(d)[:8], n))
        self._send(200, b"ok")

    do_POST = do_PUT

    # ---------- 网页 ----------
    def _serve_index(self):
        got = load_static()
        if got is None:
            # 网页还没传上来。给一句能照着敲的提示，比 404 好排查。
            msg = (
                "网页还没上传。在服务器上执行：\n"
                "  POD=$(k3s kubectl -n todo get pod -l app=todo-app"
                " -o jsonpath='{.items[0].metadata.name}')\n"
                "  k3s kubectl -n todo cp ../www/index.html $POD:/data/www/index.html -c api\n"
            )
            return self._send(503, msg.encode("utf-8"))

        raw, gz, etag = got

        # 第二次打开直接 304，7.8MB 一个字节都不重下
        if (self.headers.get("If-None-Match") or "").strip() == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", "0")
            self._cors()
            self.end_headers()
            return

        use_gz = "gzip" in (self.headers.get("Accept-Encoding") or "").lower()
        body = gz if use_gz else raw

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        # no-cache 不是不缓存，而是每次都用 ETag 问一句「变了没」
        self.send_header("Cache-Control", "no-cache")
        if use_gz:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self._cors()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # ---------- 下载 ----------
    def do_GET(self):
        p = self.path.split("?", 1)[0]

        if p == "/healthz":
            return self._send(200, b"ok")

        if p in ("/", "/index.html"):
            return self._serve_index()

        if p != "/api/todos":
            return self._send(404, b"not found")

        tok = self._token()
        if not tok:
            return self._send(400, b"bad token")

        f = os.path.join(udir(tok), "todos.sqlite")
        if not os.path.isfile(f):
            return self._send(404, b"no data")
        try:
            with open(f, "rb") as fh:
                data = fh.read()
        except OSError as e:
            return self._send(500, ("read error: %s" % e).encode("utf-8"))
        self._send(200, data, "application/vnd.sqlite3")

    do_HEAD = do_GET


def main():
    os.makedirs(USERS, mode=0o700, exist_ok=True)
    # 多线程：一个人在下载网页（几 MB）时，别人点「立即上传」不会被堵住
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    log("todo-push api listening on %s:%d, data=%s, www=%s" % (BIND, PORT, USERS, STATIC))
    if load_static() is None:
        log("WARN 网页还没上传到 %s/index.html" % STATIC)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
