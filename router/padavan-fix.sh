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
# 家庭公网 IP 上报（精简版：无 jq、无 CA 也可用，-k 跳过证书校验）
GIST_ID="b9eef32f878cf1829591bc338bf2a26c"
GH_TOKEN="REPLACE_ME_TOKEN"
IP=""
for u in https://api-ipv4.ip.sb/ip https://ipv4.icanhazip.com https://checkip.amazonaws.com; do
  IP=$(curl -k -4 -fsS -m 10 "$u" 2>/dev/null | tr -d '[:space:]')
  case "$IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) IP="" ;;
  esac
done
if [ -z "$IP" ]; then echo "[ip-report] 取 IP 失败"; exit 1; fi
NOW=$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')
TMP=/tmp/ipr.$$
printf '{"files":{"ip.json":{"content":"{\\"latest\\":{\\"ip\\":\\"%s\\",\\"time\\":\\"%s\\"},\\"history\\":[{\\"ip\\":\\"%s\\",\\"time\\":\\"%s\\"}]}"},"ip.txt":{"content":"%s"}}}' \
  "$IP" "$NOW" "$IP" "$NOW" "$IP" > "$TMP"
R=$(curl -k -sS -m 20 -X PATCH -H "Authorization: Bearer $GH_TOKEN" \
    -H "Content-Type: application/json" -d @"$TMP" -w '\n%{http_code}' \
    "https://api.github.com/gists/$GIST_ID")
rm -f "$TMP"
CODE=$(printf '%s' "$R" | tail -n 1)
case "$CODE" in
  200) echo "[ip-report] 上报成功: $IP @ $NOW" ;;
  401) echo "[ip-report] 失败 401: Token 无效或已过期" ;;
  403) echo "[ip-report] 失败 403: Token 缺少 gist 权限" ;;
  404) echo "[ip-report] 失败 404: Gist ID 不对或无权限" ;;
  *)   echo "[ip-report] 失败 HTTP ${CODE:-无响应}: $(printf '%s' "$R" | head -c 120)" ;;
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
