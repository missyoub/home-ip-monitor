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
├── website/index.html              # 监控页面（部署到 GitHub Pages）
├── router/report-ip.sh             # 路由器上报脚本（推荐，需 jq，含 100 条历史）
├── router/report-ip-simple.sh      # 路由器上报脚本（精简版，无依赖，仅最新一条）
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
6. 编辑 `router/report-ip.sh`（或 simple 版），填入 `GIST_ID` 和 `GH_TOKEN`，上传到路由器（如 `/root/report-ip.sh`）并 `chmod +x`。
7. 路由器 crontab 添加（每 10 分钟上报一次）：
   ```
   */10 * * * * /root/report-ip.sh >/dev/null 2>&1
   ```

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
