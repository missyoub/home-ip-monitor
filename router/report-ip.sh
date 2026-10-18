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

# 用法1（安装器内嵌）: /root/report-ip.sh            （token 已写在下面）
# 用法2（任意机器立即上报）: sh report-ip.sh ghp_你的token
#   也可用管道: curl -kfsSL <raw地址> | sh -s ghp_你的token
#   Windows Git Bash 需加 CURL_EXTRA: CURL_EXTRA=--ssl-no-revoke sh -s ghp_你的token
GH_TOKEN="${1:-REPLACE_ME_TOKEN}"
CURL_EXTRA="${CURL_EXTRA:-}"   # schannel 版 curl（Windows）需传 --ssl-no-revoke
GIST_ID="b9eef32f878cf1829591bc338bf2a26c"
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
  _out=$(curl $TLS_OPT $CURL_EXTRA "$@" -fsS --max-time 12 "$_u" 2>/dev/null)
  if [ -z "$_out" ]; then
    _out=$(curl -k $CURL_EXTRA "$@" -fsS --max-time 12 "$_u" 2>/dev/null)
  fi
  printf '%s' "$_out"
}

# ---------- 1b. GitHub API 直连兜底（国内 DNS 污染 / TCP 阻断） ----------
# 注意：不能用 command -v（老 busybox ash 没这个内建，会误判），直接尝试 nslookup
# 流程：阿里 DNS 解析出候选 IP + 内置备选 IP -> 逐个探测 /zen（6 秒超时）-> 用第一个通的
GH_RESOLVE_OPT=""
GHIPS=$(nslookup api.github.com 223.5.5.5 2>/dev/null \
      | sed -n 's/.*Address[ 0-9]*: \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' \
      | grep -v '^223\.5\.5\.5$')
GHIPS="$GHIPS 20.205.243.168 140.82.121.6 140.82.116.3"
for g in $GHIPS; do
  _code=$(curl -k -4 $CURL_EXTRA -s --max-time 6 --resolve "api.github.com:443:$g" \
          -o /dev/null -w '%{http_code}' https://api.github.com/zen 2>/dev/null)
  if [ "$_code" = "200" ]; then
    GH_RESOLVE_OPT="--resolve api.github.com:443:$g"
    echo "[ip-report] api.github.com 可达节点: $g"
    break
  fi
done
if [ -z "$GH_RESOLVE_OPT" ]; then
  echo "[ip-report] !! 所有 api.github.com 候选节点均不可达（TCP 层被阻断），本次上报将失败"
fi

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
  CUR=$(fetch "$API" $GH_RESOLVE_OPT -H "Authorization: Bearer $GH_TOKEN" \
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
RAW=$(curl $TLS_OPT $CURL_EXTRA $GH_RESOLVE_OPT -sS --max-time 20 -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Content-Type: application/json" \
  -d @"$TMP" -w '\n%{http_code}' "$API" 2>/dev/null)
if [ -z "$RAW" ]; then
  RAW=$(curl -k $CURL_EXTRA $GH_RESOLVE_OPT -sS --max-time 20 -X PATCH \
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
    if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
      echo "[ip-report] 000 = 未能连接 api.github.com（DNS 污染或链路阻断）"
      echo "[ip-report] 可手动测试: nslookup api.github.com 223.5.5.5"
    fi
    [ -n "$BODY" ] && echo "[ip-report] 响应: $(printf '%s' "$BODY" | cut -c1-160)"
    logger -t ip-report "上报失败 HTTP $CODE" 2>/dev/null || true
    exit 1
    ;;
esac
