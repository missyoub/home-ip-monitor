#!/bin/sh
# ============================================================
# OpenWrt 一键安装：家庭公网 IP 上报（Zbtlink ZBT-WE1326 等）
# 用法：sh install-openwrt.sh <你的 gist-only token>
#   Token 创建：GitHub -> Settings -> Developer settings ->
#   Personal access tokens (classic) -> Generate new token，只勾选 gist
# ============================================================
GH_TOKEN="$1"
if [ -z "$GH_TOKEN" ]; then
  echo "用法: sh install-openwrt.sh <gist-only-token>"
  exit 1
fi

echo "== [1/5] 安装依赖 curl / ca-bundle / jq =="
opkg update >/dev/null 2>&1
opkg install curl ca-bundle jq 2>&1 | grep -Ei "installing|already|upgrading" || true
command -v curl >/dev/null 2>&1 || { echo "  !! curl 安装失败，检查 opkg 源网络后重试"; exit 1; }

echo "== [2/5] 写入 /root/report-ip.sh =="
cat > /root/report-ip.sh <<'EOS'
#!/bin/sh
# ============================================================
# 家庭公网 IP 上报脚本（OpenWrt / Padavan 通用，jq 可选）
#   - 有 jq：保留最近 100 条历史
#   - 无 jq：只保留最新一条（页面显示同样正常）
#   - 同时更新 ip.json（页面用）与 ip.txt（命令行查询用）
# GIST_ID 已预置，只有 GH_TOKEN 需要在安装时替换
# ============================================================

GIST_ID="b9eef32f878cf1829591bc338bf2a26c"
GH_TOKEN="REPLACE_ME_TOKEN"
API="https://api.github.com/gists/$GIST_ID"
SOURCES="https://api-ipv4.ip.sb/ip https://ipv4.icanhazip.com https://checkip.amazonaws.com"

# 0. 依赖检查
if ! command -v curl >/dev/null 2>&1; then
  echo "[ip-report] 缺少 curl，无法上报（请安装 curl 或用 OpenWrt 那台）"
  exit 1
fi

# 1. 获取公网 IPv4（三源自动切换，均为 IPv4-only 端点）
IP=""
for u in $SOURCES; do
  IP=$(curl -4 -fsS --max-time 10 "$u" 2>/dev/null | tr -d '[:space:]')
  case "$IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) IP="" ;;
  esac
done
if [ -z "$IP" ]; then
  echo "[ip-report] 获取公网 IP 失败"
  logger -t ip-report "获取公网 IP 失败" 2>/dev/null
  exit 1
fi

# 2. 北京时间（TZ=UTC-8 不依赖 tzdata，各固件通用）
NOW=$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')
TMP="/tmp/ip-report.$$"

# 3. 组装请求体
if command -v jq >/dev/null 2>&1; then
  CUR=$(curl -fsS --max-time 15 -H "Authorization: Bearer $GH_TOKEN" "$API" 2>/dev/null \
        | jq -r '.files["ip.json"].content // "{}"' 2>/dev/null)
  NEW=$(printf '%s' "$CUR" | jq -c --arg ip "$IP" --arg t "$NOW" \
        '(.history // []) as $h | {latest:{ip:$ip,time:$t}, history:([{ip:$ip,time:$t}] + $h)[0:100]}' 2>/dev/null)
  [ -z "$NEW" ] && NEW="{\"latest\":{\"ip\":\"$IP\",\"time\":\"$NOW\"},\"history\":[{\"ip\":\"$IP\",\"time\":\"$NOW\"}]}"
  jq -n --arg c "$NEW" --arg ip "$IP" '{files:{"ip.json":{content:$c},"ip.txt":{content:$ip}}}' > "$TMP"
else
  printf '{"files":{"ip.json":{"content":"{\\"latest\\":{\\"ip\\":\\"%s\\",\\"time\\":\\"%s\\"},\\"history\\":[{\\"ip\\":\\"%s\\",\\"time\\":\\"%s\\"}]}"},"ip.txt":{"content":"%s"}}}' \
    "$IP" "$NOW" "$IP" "$NOW" "$IP" > "$TMP"
fi

# 4. 写回 Gist
RESULT=$(curl -fsS --max-time 20 -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TMP" "$API" 2>/dev/null)
rm -f "$TMP"

case "$RESULT" in
  *'"id"'*)
    echo "[ip-report] 上报成功: $IP @ $NOW"
    logger -t ip-report "上报成功: $IP" 2>/dev/null || true
    exit 0
    ;;
  *)
    echo "[ip-report] 上报失败，响应: $RESULT"
    logger -t ip-report "上报失败" 2>/dev/null || true
    exit 1
    ;;
esac
EOS
sed -i "s|REPLACE_ME_TOKEN|$GH_TOKEN|" /root/report-ip.sh
chmod +x /root/report-ip.sh
echo "  OK"

echo "== [3/5] 检查本机出口 IP（应等于你家宽带的公网 IP） =="
curl -4 -fsS -m 10 https://api-ipv4.ip.sb/ip || echo "  !! 取 IP 失败：检查 WAN 是否为 4G/SIM 或缺少 ca-bundle"

echo "== [4/5] 试跑一次 =="
/root/report-ip.sh

echo "== [5/5] 配置每 10 分钟定时上报 =="
grep -q "report-ip.sh" /etc/crontabs/root 2>/dev/null || \
  echo '*/10 * * * * /root/report-ip.sh >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true
echo "--- 当前 crontab ---"
crontab -l 2>/dev/null || cat /etc/crontabs/root

echo ""
echo "安装完成。约 1 分钟后打开查看：https://missyoub.github.io/home-ip-monitor/"
echo "查看运行日志：logread -e ip-report"
