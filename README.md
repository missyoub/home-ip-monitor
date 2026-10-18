# 家庭公网 IP 监控（Home IP Monitor）

路由器定时上报家庭宽带公网 IP，GitHub Pages 页面随时查看，**全程无需自建服务器**。

## 架构

```
┌─────────────┐  ① curl 获取出口 IP     ┌──────────────────┐
│ 家庭路由器    │ ──────────────────────► │ 公网 IP 服务       │
│ (cron+curl) │                         │ api-ipv4.ip.sb 等 │
│             │  ② PATCH 写入 ip.json   └──────────────────┘
│             │ ──────────────────────► GitHub Gist (秘密可见)
└─────────────┘                                │
                                               │ ③ GET raw (CORS *)
                                    ┌──────────▼─────────┐
                                    │ GitHub Pages 静态页 │
                                    │ 展示 IP / 历史/状态 │
                                    └────────────────────┘
```

## 目录结构

```
├── website/index.html                  # 监控页面（部署到 GitHub Pages）
├── router/report-ip.sh                 # 上报脚本（OpenWrt/Padavan 通用，jq 可选）
├── router/install-openwrt.sh           # OpenWrt 一键安装
├── router/install-padavan.sh           # Padavan 一键安装
└── .github/workflows/deploy-pages.yml  # GitHub Actions 自动部署
```

## 部署步骤

1. **创建 GitHub 仓库**并推送本目录代码（公开仓库）。
2. 仓库 **Settings → Pages → Source 选择 GitHub Actions**。
3. 推送后 Actions 自动部署，1-2 分钟后访问 `https://<用户名>.github.io/<仓库名>/`。
4. 数据 Gist（已创建，秘密可见）：
   - Gist ID：`b9eef32f878cf1829591bc338bf2a26c`
   - 结构化数据（页面用）：`https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.json`
   - 纯文本（命令行用）：`https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.txt`
5. **创建路由器专用 Token**：GitHub → Settings → Developer settings → Personal access tokens (classic)，仅勾选 `gist` 权限。
6. 路由器上执行一键安装（把 `ghp_xxx` 换成上一步的 Token）：
   ```sh
   # OpenWrt
   sh install-openwrt.sh ghp_xxx
   # Padavan
   sh install-padavan.sh ghp_xxx
   ```
   OpenWrt 脚本会自动装 curl/ca-bundle/jq、写入 `/root/report-ip.sh`、试跑一次并配置每 10 分钟 cron；
   Padavan 脚本写入 `/etc/storage/report-ip.sh`（重启不丢），定时任务按 `cru` → crontab 文件 → Web UI 三级自动降级。

   > Token 是 `ghp_` 开头的 40 位字符串。**Gist ID（`b9eef32f...`，32 位十六进制）不是 Token**，脚本会直接拒绝。

## 常见问题（Padavan / 老固件）

| 现象 | 原因 | 处理 |
|------|------|------|
| 提示"本固件没有 curl"，但直接敲 `curl` 又能用 | 老 busybox 的 `ash` 没有 `command -v` 内建，检测恒为失败 | 脚本已改用 `curl --version` 检测 |
| `curl: (77) Error reading ca cert file ... mbedTLS` | 固件缺 CA 证书，curl 无法校验证书 | 脚本自动回退 `-k`（跳过校验）重试，业务可用 |
| `cru: not found` | 该固件裁掉了 cron 的 `cru` 封装 | 脚本改为直接写 `/etc/storage/cron/crontabs/` 并 `killall -HUP crond`；若系统管理里有「定时任务 / Crontab」标签，也可手动粘贴一行 |
| 三项都没有 | 固件既无 cron 也无 crontab 目录 | 无法定时上报，改用 OpenWrt 那台（推荐主业） |
| 上报失败 401 / 403 | Token 错误、过期或缺 `gist` 权限 | 重新生成 classic token，只勾 `gist` |

## 命令行查询

路由器每次上报会同时更新 Gist 中的 `ip.txt`（纯文本，仅含 IP），在任何机器上：

```bash
# Linux / macOS / Git Bash
curl -s https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.txt

# Windows PowerShell（效果同 iwr ifconfig.me/ip）
iwr https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.txt
```

返回纯文本 IP，可直接赋值给脚本变量，例如：
```bash
HOME_IP=$(curl -s https://gist.githubusercontent.com/missyoub/b9eef32f878cf1829591bc338bf2a26c/raw/ip.txt)
```

### 查询访问者自己的公网 IP

GitHub Pages 为纯静态托管，无法自建「回显访问者 IP」的接口，因此直接使用公共 IP 回显服务：

```bash
curl -s https://api-ipv4.ip.sb/ip        # 备选: ifconfig.me/ip、checkip.amazonaws.com、ipv4.icanhazip.com
```

返回「执行命令的设备」当前出口 IP（手机流量/公司宽带等），可与上面的家庭 IP 对比，判断自己当前是否在家庭网络内。如需自有域名的回显服务，可参考 [mpolden/echoip](https://github.com/mpolden/echoip)（ifconfig.co 同款开源实现）或部署一个 Cloudflare Worker。

## 相关开源项目

| 项目 | 星标 | 说明 |
|------|------|------|
| [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go) | 17.4k | Go 编写，路由器/NAS 上运行，自动把新 IP 更新到阿里/腾讯/Cloudflare 等 DNS，带 Web UI |
| [NewFuture/DDNS](https://github.com/NewFuture/DDNS) | 4.7k | 轻量 Python/跨平台 DDNS，适合 OpenWrt 定时任务，与本项目路由端思路最接近 |
| [mpolden/echoip](https://github.com/mpolden/echoip) | 4.4k | 自建「访问者 IP 回显」服务（ifconfig.co 同款），Go 单二进制 |
| [qdm12/ddns-updater](https://github.com/qdm12/ddns-updater) | 3.2k | 容器化 DDNS 更新器，支持 40+ DNS 服务商 |
| [ddclient/ddclient](https://github.com/ddclient/ddclient) | 3.6k | 经典 Perl DDNS 客户端 |
| [TimothyYe/godns](https://github.com/TimothyYe/godns) | 1.8k | Go DDNS 客户端，支持 DNSPod/阿里/华为云等 |

**本项目与它们的差异**：上述 DDNS 工具是「IP → DNS 解析」思路（需要持有域名）；本项目是「IP → 可随时查看的页面/接口」思路（零域名、零后端、纯 GitHub 托管）。两者可互补：如果你有域名，推荐叠加 ddns-go 实现自动解析；无域名时本项目即可满足随时查看 IP 的需求。

## 页面功能

- 大字号展示当前家庭公网 IP，点击即复制
- 上报状态实时判定：正常上报 / 未按时上报（超过 30 分钟）/ 长时间无上报
- 上报历史（最近 100 条），IP 变更自动标红
- 显示访问者当前出口 IP，便于对比确认
- 每 60 秒自动刷新

## 安全说明

- 路由器脚本中的 Token **只勾选 gist 权限**，即使泄露也无法操作仓库。
- Gist 为「秘密可见」，仅知道 ID 的人可访问；如介意 IP 暴露，不要向他人透露页面地址。
- 页面为纯静态，不收集任何数据，无 Cookie、无统计。
