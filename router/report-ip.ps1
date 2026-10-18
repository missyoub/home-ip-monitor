# ============================================================
# Windows 一键上报家庭公网 IP（IPv4 + IPv6）
# 用法1（推荐，自动从 Windows 凭据管理器取 GitHub 凭据，免传 token）:
#   powershell -ExecutionPolicy Bypass -File report-ip.ps1
# 用法2（手动传 token）:
#   powershell -ExecutionPolicy Bypass -File report-ip.ps1 -Token ghp_xxxx
# 远程一行执行（不需要下载文件）:
#   powershell -c "irm https://cdn.jsdelivr.net/gh/missyoub/home-ip-monitor@<SHA>/router/report-ip.ps1 | iex"
# ============================================================
param([string]$Token = "")
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$GistId = "b9eef32f878cf1829591bc338bf2a26c"
$Api    = "https://api.github.com/gists/$GistId"
$Curl   = "curl.exe"
$Common = @("--ssl-no-revoke", "-s", "--max-time", "15")

# ---- 0. Token：参数优先，否则从 git credential fill 取 ----
if (-not $Token) {
  try {
    $out = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $line = $out | Where-Object { $_ -like "password=*" } | Select-Object -First 1
    if ($line) { $Token = $line.Substring("password=".Length) }
  } catch {}
}
if (-not $Token -or $Token.Length -lt 38) {
  Write-Host "[ip-report] 未取到有效 Token。请用: report-ip.ps1 -Token ghp_xxxx" -ForegroundColor Red
  exit 1
}

# ---- 1. 取当前公网 IPv4 / IPv6 ----
function Get-PubIp([string[]]$Urls, [scriptblock]$Valid) {
  foreach ($u in $Urls) {
    try {
      $ip = (& $Curl @Common $u 2>$null)
      if ($ip) { $ip = ($ip -join "").Trim(); if (& $Valid $ip) { return $ip } }
    } catch {}
  }
  return ""
}
$v4 = Get-PubIp @("https://api-ipv4.ip.sb/ip","https://ipv4.icanhazip.com","https://checkip.amazonaws.com") { param($x) $x -match "^\d{1,3}(\.\d{1,3}){3}$" }
$v6 = Get-PubIp @("https://api-ipv6.ip.sb/ip","https://ipv6.icanhazip.com") { param($x) $x -match ":" -and $x -notmatch "\s" }
if (-not $v4) { Write-Host "[ip-report] 获取公网 IPv4 失败（检查网络/代理）" -ForegroundColor Red; exit 1 }

# ---- 2. 北京时间 ----
$now = [TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")).ToString("yyyy-MM-dd HH:mm:ss")

# ---- 3. 读现有 ip.json，保留完整历史 ----
$cur = "{}"
try { $cur = (& $Curl @Common -H "Authorization: Bearer $Token" $Api 2>$null | ConvertFrom-Json).files."ip.json".content } catch {}
try { $obj = $cur | ConvertFrom-Json } catch { $obj = $null }
$history = @()
if ($obj -and $obj.history) { $history = @($obj.history) }
$entry = [pscustomobject]@{ ip = $v4; ip6 = $v6; time = $now }
$history = @($entry) + $history
if ($history.Count -gt 100) { $history = $history[0..99] }
$payload = [pscustomobject]@{
  files = [pscustomobject]@{
    "ip.json" = [pscustomobject]@{ content = ([pscustomobject]@{ latest = $entry; history = $history } | ConvertTo-Json -Depth 6 -Compress) }
    "ip.txt"  = [pscustomobject]@{ content = $v4 }
    "ip6.txt" = [pscustomobject]@{ content = $(if ($v6) { $v6 } else { "none" }) }
  }
} | ConvertTo-Json -Depth 6 -Compress

# ---- 4. PATCH 上报 ----
$tmp = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllText($tmp, $payload)
$code = (& $Curl @Common --max-time 20 -X PATCH -H "Authorization: Bearer $Token" -H "Content-Type: application/json" -d "@$tmp" -w "%{http_code}" -o "$tmp.resp" $Api 2>$null)
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($code -eq "200") {
  Write-Host "[ip-report] 上报成功: $v4 @ $now" -ForegroundColor Green
  if ($v6) { Write-Host "[ip-report] IPv6: $v6" -ForegroundColor Cyan }
  else     { Write-Host "[ip-report] IPv6: 未获取到（本机无 IPv6 网络，不影响上报）" }
} else {
  Write-Host "[ip-report] 上报失败 HTTP $code" -ForegroundColor Red
  if (Test-Path "$tmp.resp") { Get-Content "$tmp.resp" -Raw | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) }; Remove-Item "$tmp.resp" -ErrorAction SilentlyContinue }
  exit 1
}
