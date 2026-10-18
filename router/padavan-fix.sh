#!/bin/sh
# ============================================================
# Padavan 精简安装（适配：无 jq / 无 cru / 无 CA 证书 / 老 busybox）
# 用法：sh padavan-fix.sh ghp_你的token
#   注意 b9eef32f878cf1829591bc338bf2a26c 是 Gist ID，不是 Token
# ============================================================
T=$(printf '%s' "$1" | tr -d '[:space:]')
case "$T" in
  ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) ;;
  *) echo "!! Token 应以 ghp_ 开头（classic token），b9eef32f... 是 Gist ID"; exit 1 ;;
esac
if [ $(printf '%s' "$T" | wc -c) -lt 38 ]; then
  echo "!! Token 长度只有 $(printf '%s' "$T" | wc -c) 位，标准 token 是 40 位，看起来填的是 Gist ID"
  exit 1
fi

curl --version >/dev/null 2>&1 || { echo "!! 本机无 curl，无法上报"; exit 1; }

echo "---- 验证 Token ----"
WHO=$(curl -k -sS -m 20 -w '\n%{http_code}' -H "Authorization: Bearer $T" \
      -H "User-Agent: ip-report-setup" https://api.github.com/user 2>/dev/null)
WCODE=$(printf '%s' "$WHO" | tail -n 1)
if [ "$WCODE" != "200" ]; then
  echo "!! Token 验证失败（HTTP $WCODE），GitHub 不接受这个 Token"
  echo "   常见原因：没复制完整、已过期/被撤销、或复制成了别的字符串"
  echo "   请重新生成：Settings -> Developer settings -> Tokens (classic) -> Generate new token"
  exit 1
fi
echo "Token 有效，账号: $(printf '%s' "$WHO" | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)"

echo "---- 环境自检 ----"
echo "curl  : $(curl --version 2>/dev/null | head -1)"
if ps 2>/dev/null | grep -q '[c]rond'; then echo "crond : 运行中"; else echo "crond : 未运行"; fi
if cru l >/dev/null 2>&1; then echo "cru   : 有"; else echo "cru   : 无"; fi
for d in /etc/storage/cron/crontabs /var/spool/cron/crontabs /etc/crontabs /etc/spool/cron/crontabs; do
  [ -d "$d" ] && echo "crontab 目录: $d -> $(ls "$d" 2>/dev/null | tr '\n' ' ')"
done

echo "---- 写入 /etc/storage/report-ip.sh ----"
mkdir -p /etc/storage
cat > /etc/storage/report-ip.sh <<'EOS'
#!/bin/sh
# ============================================================
# 家庭公网 IP 上报脚本（OpenWrt / Padavan 通用，jq 可选）
#   - 有 jq：保留最近 100 条历史
#   - 无 jq：只保留最新一条（页面显示同样正常）
#   - 同时更新 ip.json（页面用）与 ip.txt（命令行查询用）
#
# 兼容性要点（Padavan / RT-N14U 等老固件实测）：
#   1) 不用 command -v：老 busybox ash 没这个内建，会误判成"没装 curl"
#   2) CA 证书缺失时自动加 -k 重试（mbedTLS 版 curl 常见 error 77）
# ============================================================

GIST_ID="b9eef32f878cf1829591bc338bf2a26c"
GH_TOKEN="REPLACE_ME_TOKEN"
API="https://api.github.com/gists/$GIST_ID"
SOURCES="https://api-ipv4.ip.sb/ip https://ipv4.icanhazip.com https://checkip.amazonaws.com"
V6SOURCES="https://api-ipv6.ip.sb/ip https://ipv6.icanhazip.com"

# ---------- 0. 依赖与 Token 检查 ----------
curl --version >/dev/null 2>&1 || {
  echo "[ip-report] 缺少 curl，无法上报（该固件请改用 wget 方案或换 OpenWrt）"
  exit 1
}

case "$GH_TOKEN" in
  ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) ;;
  *)
    echo "[ip-report] GH_TOKEN 无效：应以 ghp_ 开头（classic token）"
    echo "[ip-report] 注意 b9eef32f878cf1829591bc338bf2a26c 是 Gist ID，不是 Token"
    exit 1
    ;;
esac
if [ $(printf '%s' "$GH_TOKEN" | wc -c) -lt 38 ]; then
  echo "[ip-report] GH_TOKEN 长度不足（$(printf '%s' "$GH_TOKEN" | wc -c) 字符），看起来是 Gist ID 而非 Token"
  echo "[ip-report] 真正的 classic token 是 ghp_ + 36 位，共 40 字符"
  exit 1
fi

# ---------- 1. TLS：优先用系统 CA，缺失则回退 -k ----------
TLS_OPT=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem \
         /etc/ssl/certs/cert.pem /etc/ca-certificates.crt; do
  if [ -s "$f" ]; then TLS_OPT="--cacert $f"; break; fi
done

# fetch <url> [curl 额外参数]：先按系统 CA 取，失败则 -k 重试（兼容 mbedTLS 无证书）
fetch() {
  _u="$1"; shift
  _out=$(curl $TLS_OPT "$@" -fsS --max-time 12 "$_u" 2>/dev/null)
  if [ -z "$_out" ]; then
    _out=$(curl -k "$@" -fsS --max-time 12 "$_u" 2>/dev/null)
  fi
  printf '%s' "$_out"
}

# ---------- 2. 获取公网 IPv4（三源自动切换） ----------
IP=""
for u in $SOURCES; do
  IP=$(fetch "$u" -4 | tr -d '[:space:]')
  case "$IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) IP="" ;;
  esac
done
if [ -z "$IP" ]; then
  echo "[ip-report] 获取公网 IP 失败（网络不通或 DNS 异常）"
  logger -t ip-report "获取公网 IP 失败" 2>/dev/null || true
  exit 1
fi

# ---------- 2b. 获取公网 IPv6（可能没有，不阻塞上报） ----------
IP6=""
for u in $V6SOURCES; do
  IP6=$(fetch "$u" -6 | tr -d '[:space:]')
  case "$IP6" in
    *:*) break ;;
    *) IP6="" ;;
  esac
done

# ---------- 3. 北京时间（TZ=UTC-8 不依赖 tzdata） ----------
NOW=$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')
TMP="/tmp/ip-report.$$"

# ---------- 4. 组装请求体 ----------
if jq --version >/dev/null 2>&1; then
  CUR=$(fetch "$API" -H "Authorization: Bearer $GH_TOKEN" \
        | jq -r '.files["ip.json"].content // "{}"' 2>/dev/null)
  NEW=$(printf '%s' "$CUR" | jq -c --arg ip "$IP" --arg ip6 "$IP6" --arg t "$NOW" \
        '(.history // []) as $h | {latest:{ip:$ip,ip6:$ip6,time:$t}, history:([{ip:$ip,ip6:$ip6,time:$t}] + $h)[0:100]}' 2>/dev/null)
  [ -z "$NEW" ] && NEW="{\"latest\":{\"ip\":\"$IP\",\"ip6\":\"$IP6\",\"time\":\"$NOW\"},\"history\":[{\"ip\":\"$IP\",\"ip6\":\"$IP6\",\"time\":\"$NOW\"}]}"
  jq -n --arg c "$NEW" --arg ip "$IP" --arg ip6 "${IP6:-none}" \
    '{files:{"ip.json":{content:$c},"ip.txt":{content:$ip},"ip6.txt":{content:$ip6}}}' > "$TMP"
else
  printf '{"files":{"ip.json":{"content":"{\\"latest\\":{\\"ip\\":\\"%s\\",\\"ip6\\":\\"%s\\",\\"time\\":\\"%s\\"},\\"history\\":[{\\"ip\\":\\"%s\\",\\"ip6\\":\\"%s\\",\\"time\\":\\"%s\\"}]}"},"ip.txt":{"content":"%s"},"ip6.txt":{"content":"%s"}}}' \
    "$IP" "$IP6" "$NOW" "$IP" "$IP6" "$NOW" "$IP" "${IP6:-none}" > "$TMP"
fi

# ---------- 5. 写回 Gist（同时取 HTTP 状态码，便于定位问题） ----------
RAW=$(curl $TLS_OPT -sS --max-time 20 -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TMP" -w '\n%{http_code}' "$API" 2>/dev/null)
if [ -z "$RAW" ]; then
  RAW=$(curl -k -sS --max-time 20 -X PATCH \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$TMP" -w '\n%{http_code}' "$API" 2>/dev/null)
fi
rm -f "$TMP"
CODE=$(printf '%s' "$RAW" | tail -n 1)
BODY=$(printf '%s' "$RAW" | sed '$d')

case "$CODE" in
  200)
    echo "[ip-report] 上报成功: $IP @ $NOW"
    if [ -n "$IP6" ]; then
      echo "[ip-report] IPv6: $IP6"
    else
      echo "[ip-report] IPv6: 未获取到（路由器当前无 IPv6 网络，不影响上报）"
    fi
    logger -t ip-report "上报成功: $IP" 2>/dev/null || true
    exit 0
    ;;
  401)
    echo "[ip-report] 上报失败 401：Token 无效、已过期或被撤销"
    exit 1
    ;;
  403)
    echo "[ip-report] 上报失败 403：Token 缺少 gist 权限"
    echo "[ip-report] 响应: $(printf '%s' "$BODY" | cut -c1-160)"
    exit 1
    ;;
  404)
    echo "[ip-report] 上报失败 404：Gist 不存在，或 Token 无权访问该 Gist"
    exit 1
    ;;
  *)
    echo "[ip-report] 上报失败 (HTTP ${CODE:-无响应})"
    [ -n "$BODY" ] && echo "[ip-report] 响应: $(printf '%s' "$BODY" | cut -c1-160)"
    logger -t ip-report "上报失败 HTTP $CODE" 2>/dev/null || true
    exit 1
    ;;
esac
EOS
sed -i "s|REPLACE_ME_TOKEN|$T|" /etc/storage/report-ip.sh
chmod +x /etc/storage/report-ip.sh

echo "---- 试跑 ----"
/etc/storage/report-ip.sh

echo "---- 配置每 10 分钟定时 ----"
LINE="*/10 * * * * /etc/storage/report-ip.sh >/dev/null 2>&1"
DONE=0
if cru l >/dev/null 2>&1; then
  cru d reportip >/dev/null 2>&1
  cru a reportip "$LINE" && DONE=1 && echo "已用 cru 添加"
fi
if [ "$DONE" = "0" ]; then
  CDIR=""
  for d in /etc/storage/cron/crontabs /var/spool/cron/crontabs /etc/crontabs /etc/spool/cron/crontabs; do
    [ -d "$d" ] && CDIR="$d" && break
  done
  if [ -n "$CDIR" ]; then
    CF="$CDIR/root"
    [ -f "$CDIR/admin" ] && CF="$CDIR/admin"
    touch "$CF" 2>/dev/null
    grep -q "report-ip.sh" "$CF" 2>/dev/null || echo "$LINE" >> "$CF"
    echo "已写入 $CF"
    if ps 2>/dev/null | grep -q '[c]rond'; then
      killall -HUP crond 2>/dev/null || kill -HUP $(pidof crond) 2>/dev/null
      echo "已通知 crond 重载"
    else
      crond -c "$CDIR" -l 5 2>/dev/null && echo "已启动 crond"
    fi
    DONE=1
  fi
fi
if [ "$DONE" = "0" ]; then
  echo "!! 本机没有 cru、也没有 crontab 目录，无法定时。"
  echo "   请到 Web UI「系统管理」找『定时任务 / Crontab』粘贴："
  echo "   $LINE"
fi

if [ -x /sbin/mtd_storage.sh ]; then
  /sbin/mtd_storage.sh save >/dev/null 2>&1 && echo "已保存到 flash"
elif [ -x /usr/sbin/mtd_storage.sh ]; then
  /usr/sbin/mtd_storage.sh save >/dev/null 2>&1 && echo "已保存到 flash"
else
  echo "请在 Web UI 点『保存到闪存』"
fi
echo "---- 完成 ----"
