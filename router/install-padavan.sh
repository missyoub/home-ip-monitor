#!/bin/sh
# ============================================================
# Padavan 一键安装（适配：无 cru、CA 证书缺失、老 busybox 无 command -v）
# 用法：sh install-padavan.sh ghp_你的token
#   Token 必须 ghp_ 开头；b9eef32f... 是 Gist ID，不是 Token
# ============================================================
GH_TOKEN="$1"
case "$GH_TOKEN" in
  ghp_*|github_pat_*) ;;
  *)
    echo "!! Token 格式不对"
    echo "   用法：sh install-padavan.sh ghp_xxxxxxxxxxxxxxxx"
    echo "   注意：b9eef32f878cf1829591bc338bf2a26c 是 Gist ID，不是 Token"
    echo "   创建：GitHub -> Settings -> Developer settings -> Tokens (classic)，只勾 gist"
    exit 1
    ;;
esac

echo "== [1/6] 环境自检 =="
if curl --version >/dev/null 2>&1; then
  echo "  curl: 可用"
else
  echo "  curl: 缺失 -> 该固件无法上报，请改用 OpenWrt 那台"
  exit 1
fi
if [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ]; then
  echo "  CA 证书: 有"
else
  echo "  CA 证书: 缺失（脚本会自动用 -k 兜底，不影响使用）"
fi
if jq --version >/dev/null 2>&1; then
  echo "  jq: 可用（保留最近 100 条历史）"
else
  echo "  jq: 无（只保留最新一条，页面显示同样正常）"
fi
if cru l >/dev/null 2>&1; then
  echo "  cru: 可用"
else
  echo "  cru: 缺失（将尝试直接写 crontab 文件）"
fi
if ps 2>/dev/null | grep -q '[c]rond'; then
  echo "  crond: 运行中"
else
  echo "  crond: 未运行"
fi
for d in /etc/storage/cron/crontabs /var/spool/cron/crontabs /etc/crontabs /etc/spool/cron/crontabs; do
  if [ -d "$d" ]; then
    echo "  crontab 目录: $d -> $(ls "$d" 2>/dev/null | tr '\n' ' ')"
  fi
done

echo "== [2/6] 写入 /etc/storage/report-ip.sh（重启不丢失） =="
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
sed -i "s|REPLACE_ME_TOKEN|$GH_TOKEN|" /etc/storage/report-ip.sh
chmod +x /etc/storage/report-ip.sh
echo "  已写入：/etc/storage/report-ip.sh"

echo "== [3/6] 检查出口 IP（应等于你家宽带的公网 IP） =="
IPCHK=$(curl -fsS -m 10 https://api-ipv4.ip.sb/ip 2>/dev/null)
[ -z "$IPCHK" ] && IPCHK=$(curl -k -fsS -m 10 https://api-ipv4.ip.sb/ip 2>/dev/null)
[ -z "$IPCHK" ] && IPCHK=$(curl -k -fsS -m 10 https://ipv4.icanhazip.com 2>/dev/null)
if [ -n "$IPCHK" ]; then
  echo "  出口 IP: $IPCHK"
else
  echo "  !! 取 IP 失败（网络/DNS 问题）"
fi

echo "== [4/6] 试跑一次 =="
if /etc/storage/report-ip.sh; then
  echo "  试跑成功"
else
  echo "  !! 试跑失败，请把上面输出发我"
fi

echo "== [5/6] 配置定时任务（每 10 分钟） =="
CRON_LINE="*/10 * * * * /etc/storage/report-ip.sh >/dev/null 2>&1"
SCHEDULED=0
if cru l >/dev/null 2>&1; then
  cru d reportip >/dev/null 2>&1
  cru a reportip "$CRON_LINE" && SCHEDULED=1 && echo "  已通过 cru 添加"
  cru l 2>/dev/null
fi
if [ "$SCHEDULED" = "0" ]; then
  CDIR=""
  for d in /etc/storage/cron/crontabs /var/spool/cron/crontabs /etc/crontabs /etc/spool/cron/crontabs; do
    [ -d "$d" ] && CDIR="$d" && break
  done
  if [ -n "$CDIR" ]; then
    CF="$CDIR/root"
    [ -f "$CDIR/admin" ] && CF="$CDIR/admin"
    touch "$CF" 2>/dev/null
    if grep -q "report-ip.sh" "$CF" 2>/dev/null; then
      echo "  $CF 中已有任务，跳过"
    else
      echo "$CRON_LINE" >> "$CF" && echo "  已写入 $CF"
    fi
    if ps 2>/dev/null | grep -q '[c]rond'; then
      killall -HUP crond 2>/dev/null || kill -HUP $(pidof crond) 2>/dev/null
      echo "  已通知 crond 重新加载"
    else
      crond -c "$CDIR" -l 5 2>/dev/null && echo "  已启动 crond -c $CDIR"
    fi
    SCHEDULED=1
  fi
fi
if [ "$SCHEDULED" = "0" ]; then
  echo "  !! 该固件既无 cru 也无 crontab 目录，无法自动定时"
  echo "     请到 Web UI「系统管理」找『定时任务 / Crontab』标签，粘贴下面这一行："
  echo "     $CRON_LINE"
  echo "     若没有该标签，则本机无法定时上报，建议改用 OpenWrt 那台"
fi

echo "== [6/6] 保存到 flash =="
if [ -x /sbin/mtd_storage.sh ]; then
  /sbin/mtd_storage.sh save >/dev/null 2>&1 && echo "  已保存"
elif [ -x /usr/sbin/mtd_storage.sh ]; then
  /usr/sbin/mtd_storage.sh save >/dev/null 2>&1 && echo "  已保存"
elif [ -x /sbin/nvram ] && [ -x /usr/sbin/mtd_storage.sh ]; then
  /usr/sbin/mtd_storage.sh save >/dev/null 2>&1 && echo "  已保存"
else
  echo "  未找到 mtd_storage.sh，请在 Web UI 点『保存到闪存』"
fi

cat <<'TIP'

------------------------------------------------------------
完成。验证：
  页面   https://missyoub.github.io/home-ip-monitor/
  命令行 curl -s https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.txt
  （Gist raw 有约 5 分钟 CDN 缓存）

查看定时任务是否生效（10 分钟后再跑一次，看时间的分钟数是否变化）：
  cat /etc/storage/cron/crontabs/root 2>/dev/null || cru l 2>/dev/null
------------------------------------------------------------
TIP
