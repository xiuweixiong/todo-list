#!/usr/bin/env python3
"""把 todo-push/ 打成 zip，供上传到服务器解开即用。

两个必须做的事：
1. 文本文件统一转成 LF。Windows 上编辑过的 .sh 带 CRLF，解压到 Linux 会报
   "bash\\r: No such file or directory"，这个坑已经踩过三次了。
2. www/index.html 原样不动。里面是 base64 的 wasm/模型，如果连它的 \\r\\n 也一起
   改掉，字节数变了，内嵌的数据就对不上。

用法：
    python _build/pack_push.py
"""

import datetime
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "todo-push")

# 这些后缀按文本处理，转 LF；其余一律二进制原样塞进去
TEXT_EXT = {
    ".sh", ".py", ".md", ".conf", ".yaml", ".yml", ".service",
    ".txt", ".env", ".json", ".list",
}
TEXT_NAME = {"Dockerfile"}
# 这两个目录/文件里有内嵌的二进制数据，绝不能做行尾转换
BINARY_SKIP = {os.path.join("www", "index.html")}


def is_text(rel_path):
    name = os.path.basename(rel_path)
    ext = os.path.splitext(name)[1].lower()
    return ext in TEXT_EXT or name in TEXT_NAME


def main():
    if not os.path.isdir(SRC):
        sys.exit(f"找不到目录：{SRC}")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    out = os.path.join(ROOT, f"todo-push-{stamp}.zip")

    n_text = n_bin = 0
    fixed_crlf = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for base, dirs, files in os.walk(SRC):
            dirs[:] = sorted(d for d in dirs if d not in (".git", "__pycache__"))
            for fn in sorted(files):
                full = os.path.join(base, fn)
                rel = os.path.relpath(full, SRC).replace("\\", "/")
                with open(full, "rb") as f:
                    data = f.read()

                if is_text(rel) and rel not in BINARY_SKIP:
                    if b"\r\n" in data:
                        fixed_crlf.append(rel)
                    data = data.replace(b"\r\n", b"\n")
                    n_text += 1
                else:
                    n_bin += 1

                # 权限位：.sh 保持可执行
                mode = 0o755 if rel.endswith(".sh") else 0o644
                info = zipfile.ZipInfo(rel, date_time=(2026, 11, 17, 0, 0, 0))
                info.external_attr = (mode & 0xFFFF) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data)

    size = os.path.getsize(out) / 1024 / 1024
    print(f"已生成 {os.path.basename(out)}  {size:.1f} MB")
    print(f"  文本 {n_text} 个（已转 LF），二进制 {n_bin} 个（原样）")
    if fixed_crlf:
        print(f"  修掉 CRLF 的文件：{', '.join(fixed_crlf)}")
    else:
        print("  没有文件带 CRLF，干净")


if __name__ == "__main__":
    main()
