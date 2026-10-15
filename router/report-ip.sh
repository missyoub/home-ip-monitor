#!/bin/sh
# ============================================================
# 家庭公网 IP 上报脚本（推荐版，需 jq：opkg install jq / ipkg install jq）
# 原理：获取本机出口 IPv4 -> 写入 GitHub Gist（保留最近 100 条历史）
# 用法：修改下方 GIST_ID / GH_TOKEN 后，加入 crontab 定时执行
# ============================================================

# ====== 配置区 ======
GIST_ID="REPLACE_WITH_GIST_ID"
GH_TOKEN="REPLACE_WITH_GIST_ONLY_TOKEN"   # 仅需 gist 权限的 classic token
MAX_HISTORY=100
IP_SOURCES="https://api-ipv4.ip.sb/ip https://ipv4.icanhazip.com https://ifconfig.me/ip"
# ===================

API="https://api.github.com/gists/$GIST_ID"

# 1. 获取公网 IPv4（依次尝试多个源，全是 IPv4-only 端点）
IP=""
for url in $IP_SOURCES; do
  IP=$(curl -4 -s --max-time 10 "$url" | tr -d '[:space:]')
  case "$IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) IP="" ;;
  esac
done
if [ -z "$IP" ]; then
  echo "[report-ip] 获取公网 IP 失败"
  exit 1
fi

# 2. 当前时间（北京时间）
NOW=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

# 3. 读取 Gist 当前内容
CUR=$(curl -s --max-time 15 -H "Authorization: Bearer $GH_TOKEN" "$API" \
  | jq -r '.files["ip.json"].content // "{}"')

# 4. 组装新内容：latest 置顶，历史 prepend 并截断
NEW_ENTRY=$(jq -nc --arg ip "$IP" --arg t "$NOW" '{ip:$ip, time:$t}')
NEW_CONTENT=$(printf '%s' "$CUR" | jq -c --argjson e "$NEW_ENTRY" --argjson m "$MAX_HISTORY" \
  '(.history // []) as $h | {latest: $e, history: ([$e] + $h)[0:$m]}')

# 5. 写回 Gist（同时更新 ip.json 结构化数据 + ip.txt 纯文本供命令行查询）
TMP=$(mktemp)
jq -n --arg c "$NEW_CONTENT" --arg ip "$IP" \
  '{files:{"ip.json":{content:$c},"ip.txt":{content:$ip}}}' > "$TMP"
RESULT=$(curl -s --max-time 20 -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TMP" "$API")
rm -f "$TMP"

if echo "$RESULT" | jq -e '.id' >/dev/null 2>&1; then
  echo "[report-ip] 上报成功: $IP @ $NOW"
else
  echo "[report-ip] 上报失败: $RESULT"
  exit 1
fi
