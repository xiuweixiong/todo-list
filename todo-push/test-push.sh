#!/usr/bin/env bash
# Server酱 推送连通性测试。不动任何用户配置，不读待办数据。
#
#   bash test-push.sh SCTxxxxxxxx            发一条最简测试消息
#   bash test-push.sh SCTxxxxxxxx --dry      只显示地址，不真发（省额度）
#   bash test-push.sh SCTxxxxxxxx --title "标题" --body "**正文**"
#
# 成功判据是响应体里的 "code":0，不是 HTTP 状态码。
# 因为 key 错的时候，sctapi 返回 HTTP 400，而 ft07 反而返回 HTTP 200 + code 10003，
# 只看 HTTP 会把失败当成成功。

set -uo pipefail

KEY=""; DRY=0
TITLE="待办清单推送测试"
BODY="**收到这条，说明 SendKey 是通的。**

发件时间：$(TZ=Asia/Shanghai date '+%F %T')
脚本：test-push.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry)   DRY=1; shift ;;
    --title) TITLE="${2:?--title 后面要跟标题}"; shift 2 ;;
    --body)  BODY="${2:?--body 后面要跟正文}"; shift 2 ;;
    -h|--help)
      echo "用法: bash test-push.sh <SendKey> [--dry] [--title 标题] [--body 正文]"
      exit 0 ;;
    -*) echo "不认识的参数: $1"; exit 1 ;;
    *)  KEY="$1"; shift ;;
  esac
done

if [ -z "$KEY" ]; then
  echo "用法: bash test-push.sh <SendKey> [--dry] [--title 标题] [--body 正文]"
  exit 1
fi

# 接口域名按 key 前缀分两套，认错就是 404 / not found。
# 这段逻辑和 push-one.sh 里完全一致，故意重复：这里要独立可跑，不 source 别的文件。
case "$KEY" in
  SCT*)
    URL="https://sctapi.ftqq.com/$KEY.send"
    KIND="Server酱 Turbo（sctapi）"
    ;;
  sctp*)
    UID_N="$(printf '%s' "$KEY" | sed -n 's/^sctp\([0-9]\{1,\}\)t.*/\1/p')"
    if [ -z "$UID_N" ]; then
      echo "✗ SendKey 格式不对：sctp 开头但中间取不到 uid"
      echo "  正确形态：sctp12345tAbCdEfGh..."
      exit 1
    fi
    URL="https://$UID_N.push.ft07.com/send/$KEY.send"
    KIND="Server酱³（ft07，uid=$UID_N）"
    ;;
  *)
    echo "✗ SendKey 前缀不认识，应该是 SCT 或 sctp 开头"
    echo "  你给的前 8 个字符：${KEY:0:8}..."
    echo "  去 https://sct.ftqq.com 微信扫码登录，在 SendKey 页面复制"
    exit 1
    ;;
esac

echo "接口：$KIND"
echo "地址：$URL"
echo "标题：$TITLE"
echo

if [ "$DRY" = "1" ]; then
  echo "[dry] 没有发送。去掉 --dry 就会真发一条（消耗 1 条额度）。"
  exit 0
fi

RESP=$(curl -sS --max-time 20 -X POST "$URL" \
  --data-urlencode "title=$TITLE" \
  --data-urlencode "desp=$BODY" 2>&1)
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "✗ curl 自己失败了（rc=$RC），请求没到 Server酱："
  printf '%s\n' "$RESP" | head -3
  echo
  case "$RC" in
    6)    echo "  rc=6   DNS 解析不了 → 看 /etc/resolv.conf；或 curl -v 看解析到哪个 IP" ;;
    7)    echo "  rc=7   连不上 → 出站被拦？试 curl -I https://sctapi.ftqq.com" ;;
    28)   echo "  rc=28  超时 → 网络慢，重试一次；一直这样换台机器发" ;;
    35|60) echo "  rc=$RC  TLS 握手失败 → 多半是系统时间不对，date 看一眼，校时后再试" ;;
  esac
  exit 1
fi

echo "响应原文："
printf '%s\n' "$RESP" | head -5
echo

code=$(printf '%s' "$RESP" | grep -o '"code":[[:space:]]*-\?[0-9]*' | head -1 | grep -o '\-\?[0-9]*$')

case "${code:-无}" in
  0)
    echo "✓ 发送成功（code=0）。手机微信找「Server酱」服务号，几秒内到。"
    exit 0 ;;
  40001)
    echo "✗ key 不对（code=40001 错误的Key）"
    echo "  常见：多复制了空格、复制成了别处的 key、这个 key 已经被重置过"
    exit 1 ;;
  10003)
    echo "✗ Server酱³ 找不到这个 sendkey（code=10003）"
    echo "  常见：key 属于旧版 Server酱、或 uid 与 key 不匹配"
    exit 1 ;;
  无)
    echo "✗ 响应里没有 code 字段，判断不了。把这行原文贴给我。"
    exit 1 ;;
  *)
    echo "✗ 发送失败，code=$code"
    echo "  这个码不在我预置的说明里，把上面响应原文贴给我。"
    exit 1 ;;
esac
