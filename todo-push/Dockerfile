# 一个镜像两种用途：Deployment 里跑 api.py，CronJob 里跑 push-all.sh
#
# 构建：
#   docker build -t todo-push:1.0 .
#
# 默认基础镜像走国内的 docker.m.daocloud.io，因为这台服务器直连 Docker Hub 会被
# DNS 污染（报 dial tcp 128.242.x.x:443: i/o timeout，那个 IP 是假的）。
# 如果你在能直连 Docker Hub 的机器上构建，可以换回官方名字：
#   docker build --build-arg BASE_IMAGE=python:3.11-slim -t todo-push:1.0 .
#
# 换别家镜像源也行（1ms.run、1panel.live 实测也能用）：
#   docker build --build-arg BASE_IMAGE=docker.1ms.run/library/python:3.11-slim -t todo-push:1.0 .
#
# deploy.sh 会自动传这个参数，一般不用手敲。
ARG BASE_IMAGE=docker.m.daocloud.io/library/python:3.11-slim
FROM ${BASE_IMAGE}

# ---------------------------------------------------------------------------
# apt 源
# 官方基础镜像的 sources 指向 deb.debian.org，国内拉这个域名经常是几十秒不动、
# 或者干脆 Failed to fetch。下面按顺序逐个试，第一个通的就用，全都不通才报错。
# 想指定某一个：--build-arg APT_MIRROR=mirrors.cloud.tencent.com
# ---------------------------------------------------------------------------
ARG APT_MIRROR=auto
ARG APT_CANDIDATES="mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.cloud.tencent.com deb.debian.org"

# push-one.sh 要用 curl 调 Server酱、用 sqlite3 查库、用 flock 防重入，
# 官方 slim 镜像里都没有，这里一并补上。
#
# 顺带说明两处必要细节：
#   ForceIPv4  服务器上没有 IPv6 时，apt 会先试 IPv6 白等一轮，这才是"卡住"的常见原因
#   备份/还原  每试一个源前先把原始 sources 拷回来，避免上一个源改花了字面量
RUN set -eux; \
    mkdir -p /tmp/aptsrc; \
    cp -a /etc/apt/sources.list /tmp/aptsrc/ 2>/dev/null || true; \
    cp -a /etc/apt/sources.list.d /tmp/aptsrc/ 2>/dev/null || true; \
    cands="$APT_CANDIDATES"; \
    if [ "$APT_MIRROR" != "auto" ]; then cands="$APT_MIRROR"; fi; \
    ok=0; \
    for m in $cands; do \
        echo "==> 试 apt 源: $m"; \
        rm -rf /etc/apt/sources.list.d; \
        cp -a /tmp/aptsrc/sources.list /etc/apt/sources.list 2>/dev/null || true; \
        cp -a /tmp/aptsrc/sources.list.d /etc/apt/sources.list.d 2>/dev/null || true; \
        sed -i "s|deb.debian.org|$m|g; s|security.debian.org|$m|g" \
            /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true; \
        if apt-get -o Acquire::ForceIPv4=true \
                   -o Acquire::http::Timeout=20 \
                   -o Acquire::https::Timeout=20 \
                   -o Acquire::Retries=0 update; then \
            ok=1; break; \
        fi; \
        echo "==> $m 不通，换下一个"; \
    done; \
    if [ "$ok" != "1" ]; then echo "所有 apt 源都不通，见 k8s/README.md 的排查表"; exit 1; fi; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash curl sqlite3 util-linux ca-certificates tzdata; \
    rm -rf /var/lib/apt/lists/* /tmp/aptsrc

WORKDIR /opt/todo-push
COPY env.sh push-one.sh push-all.sh api.py ./

# 在 Windows 上编辑过的文件带 CRLF，进容器会报 "bad interpreter: bash\r"。
# 这条 sed 是必须的，不是洁癖。
RUN sed -i 's/\r$//' /opt/todo-push/*.sh /opt/todo-push/*.py \
 && chmod +x /opt/todo-push/*.sh

ENV BASE=/data \
    PORT=8099 \
    BIND=0.0.0.0 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai

EXPOSE 8099
CMD ["python3", "/opt/todo-push/api.py"]
