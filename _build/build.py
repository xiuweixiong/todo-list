#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 sql.js 引擎、wasm 和应用模板打包成单个 HTML。"""

import base64
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(BASE), "todo-app")
OUT_FILE = os.path.join(OUT_DIR, "待办清单.html")

# 发布目录：只放网页本体，绝不放测试数据/备份库（那些会是可公开下载的链接）
DEPLOY_DIR = os.path.join(os.path.dirname(BASE), "_deploy")
DEPLOY_FILE = os.path.join(DEPLOY_DIR, "index.html")


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def main():
    tpl = read_text(os.path.join(BASE, "template.html"))
    sqljs = read_text(os.path.join(BASE, "sql-wasm.js"))
    wasm_b64 = base64.b64encode(
        read_bytes(os.path.join(BASE, "sql-wasm.wasm"))
    ).decode("ascii")

    # 防止引擎里意外出现 </script 提前闭合
    sqljs = sqljs.replace("</script", "<\\/script")

    l2d_dir = os.path.join(BASE, "live2d")
    l2d_files = {
        "@@L2D_DATA@@": "live2d_embed.js",
        "@@L2D_CORE@@": "live2dcubismcore.min.js",
        "@@L2D_PIXI@@": "pixi.min.js",
        "@@L2D_ENGINE@@": "cubism4.min.js",
    }
    l2d = {}
    for token, name in l2d_files.items():
        path = os.path.join(l2d_dir, name)
        if not os.path.isfile(path):
            print(f"缺少 Live2D 资源：{path}（先跑 mkembed.py）", file=sys.stderr)
            sys.exit(1)
        l2d[token] = read_text(path).replace("</script", "<\\/script")

    tokens = ["@@SQLJS@@", "@@WASM_B64@@"] + list(l2d_files)
    missing = [t for t in tokens if t not in tpl]
    if missing:
        print("模板缺少占位符：" + " ".join(missing), file=sys.stderr)
        sys.exit(1)

    html = tpl.replace("@@SQLJS@@", sqljs).replace("@@WASM_B64@@", wasm_b64)
    for token, body in l2d.items():
        html = html.replace(token, body)

    # 占位符残留检查：漏替换会让页面白屏，宁可构建失败
    if "@@L2D_" in html or "@@SQLJS@@" in html:
        print("构建结果里仍有未替换的占位符", file=sys.stderr)
        sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_FILE, "w", encoding="utf-8") as f:
        f.write(html)

    # 同步到发布目录（index.html 是静态托管的默认入口，访问根路径就能打开）
    os.makedirs(DEPLOY_DIR, exist_ok=True)
    with open(DEPLOY_FILE, "w", encoding="utf-8") as f:
        f.write(html)

    size = os.path.getsize(OUT_FILE)
    print(f"已生成：{OUT_FILE}")
    print(f"大小：{size/1024:.1f} KB")
    print(f"发布副本：{DEPLOY_FILE}")


if __name__ == "__main__":
    main()
