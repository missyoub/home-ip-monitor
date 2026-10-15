#!/bin/sh
# ============================================================
# 家庭公网 IP 上报脚本（精简版，无需 jq，仅保留最新一条记录）
# 适合不便安装 jq 的固件；如需历史记录请使用 report-ip.sh
# 用法：修改下方 GIST_ID / GH_TOKEN 后，加入 crontab 定时执行
# ============================================================

# ====== 配置区 ======
GIST_ID="REPLACE_WITH_GIST_ID"
GH_TOKEN="REPLACE_WITH_GIST_ONLY_TOKEN"   # 仅需 gist 权限的 classic token
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

# 3. 构造请求体（同时更新 ip.json 结构化数据 + ip.txt 纯文本供命令行查询；JSON 内嵌 JSON，用 printf 转义）
TMP=$(mktemp)
printf '{"files":{"ip.json":{"content":"{\\"latest\\":{\\"ip\\":\\"%s\\",\\"time\\":\\"%s\\"}}"},"ip.txt":{"content":"%s"}}}' \
  "$IP" "$NOW" "$IP" > "$TMP"

# 4. 写回 Gist
RESULT=$(curl -s --max-time 20 -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TMP" "$API")
rm -f "$TMP"

if echo "$RESULT" | grep -q '"id"'; then
  echo "[report-ip] 上报成功: $IP @ $NOW"
else
  echo "[report-ip] 上报失败: $RESULT"
  exit 1
fi
