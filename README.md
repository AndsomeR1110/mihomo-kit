# mihomo-kit · 校园网代理套件（Windows）

一套开箱即用的 mihomo 独立内核：Windows 服务开机自启 + TUN 全局接管 + 本地面板（zashboard）。
节点来自分享者的自建 VPS（香港 / 美国双出口）：默认流量走香港，**AI 网站固定走美国**，国内流量直连、不耗 VPS 流量。

> **Mac 用户**：请看 [macos/README.md](macos/README.md)（launchd 守护进程 + 菜单栏图标，配置与节点和 Windows 版通用）。

## 你需要准备

- Windows 10/11（64 位），有管理员权限
- 分享者给你的两个文件：`nodes.yaml` 和 `infra-direct.yaml`（**这是凭据，别外传**）
- 电脑上已有的代理软件（Clash Verge 等）需先退出——两者不能同时用，安装器会检测

## 安装（三选一）

### 方式 A：拿到离线压缩包（最简单，推荐）

1. 解压到**没有空格的英文路径**，比如 `C:\mihomo` 或 `D:\mihomo`
2. 把 `nodes.yaml`、`infra-direct.yaml` 放进 `config\private\`
3. 双击 `install.cmd`，按提示走（会弹 UAC 提权）
4. 完成——桌面会有「mihomo 面板」快捷方式（安装时选 Y 即可，免密直达）

> - Windows 安全提示：ZIP 解压出的脚本可能触发「Windows 已保护你的电脑」→ 点「更多信息 → 仍要运行」
> - 360 / 火绒拦截时选「允许」，必要时把整个文件夹加入信任区

### 方式 B：让 AI 帮你装

会用 AI 编程助手（ZCode / Cursor / Claude Code 等）的同学：把仓库里
[AGENT-PROMPT.txt](AGENT-PROMPT.txt) 的内容原样发给它，照做即可。详细规程见
[AGENT-INSTALL.md](AGENT-INSTALL.md)。

### 方式 C：手动（Git 用户）

```bat
git clone https://github.com/AndsomeR1110/mihomo-kit C:\mihomo
:: GitHub 连不上就在地址前加镜像前缀：
:: git clone https://gh-proxy.com/https://github.com/AndsomeR1110/mihomo-kit C:\mihomo
:: 然后放好 config\private\ 的两个文件，双击 install.cmd（首次会自动下载内核/面板/规则集）
```

## 日常使用（双击）

| 文件 | 作用 | 需要管理员 |
| --- | --- | --- |
| `status.cmd` | 服务状态、内存、当前出口、节点延迟、出口实测、最近日志 | 否 |
| `panel.cmd` | 打开面板（自动带密钥，免登录） | 否 |
| `logs.cmd` | 实时看内核日志（Ctrl+C 退出） | 否 |
| `start.cmd` / `stop.cmd` / `restart.cmd` | 启动 / 停止 / 重启服务 | 是 |
| `rescue.cmd` | **断网急救**：停服务、关残留系统代理、刷新 DNS、测直连 | 是 |

## 改配置

| 文件 | 作用 | 需要管理员 |
| --- | --- | --- |
| `test-config.cmd` | 检查占位符、证书指纹格式和配置语法 | 否 |
| `apply-config.cmd` | 检查 → 存档 → 重启 → 健康检查；起不来自动退回 | 是 |
| `mark-good.cmd` | 把当前配置存为「已知可用」版本 | 否 |
| `rollback.cmd` | 退回「已知可用」版本 | 是 |

## 面板（zashboard）

- 免密入口：桌面快捷方式 或 `panel.cmd`
- 手动填：后端 `http://127.0.0.1:9097`，密钥是 `config\config.yaml` 里的 `secret`
  （注意 zashboard 设置页默认预填 9090，**实际端口是 9097**，连不上先查这个）
- 常用操作：切默认出口（香港组/美国组/直连）、看节点延迟、看每条连接走了哪个规则
- 面板里的手动选择会被记住，重启不变；**美国组是 AI 专用的，一般不用动**

## 系统调整（可选）

| 文件 | 作用 |
| --- | --- |
| `system-tweaks-apply.cmd` | 关闭网卡 IPv6 与 Teredo，防止流量绕过代理（会记录原状态） |
| `system-tweaks-revert.cmd` | 恢复到调整前 |

校园网环境建议开启（安装时问过一次，忘了就现在双击 apply）。另建议手动关闭浏览器的「使用安全 DNS」。

## 托盘管家（可选，推荐）

装完后跑一次，右下角常驻小环图标，右键即可 启动/停止/重启代理、打开面板、看状态，双击图标直开面板；启停**不弹 UAC**（安装时会向系统申请一次该服务的用户启停权限）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <套件目录>\tray\build.ps1
```

- 用 Windows 自带的 csc 现场编译，无需装任何东西；开机随当前用户自启，内存占用约 85 MB
- 运行中=彩色环，停止=灰色环；详细说明见 `tray\README.md`
- 高 DPI（125%/150%/175%）下文字锐利，暗色菜单
- 卸载：托盘右键「退出托盘」→ 删除 `tray\MihomoTray.exe`，再把启动文件夹里的 `mihomo 托盘管家.lnk` 删掉即可

## 卸载

1. 双击 `uninstall-service.cmd`（注销服务）
2. 若做过系统调整，双击 `system-tweaks-revert.cmd`
3. 删除整个文件夹（桌面快捷方式一并删掉）

## 故障排查

| 症状 | 处理 |
| --- | --- |
| 完全断网 | 双击 `rescue.cmd` 恢复直连，再排查 |
| 面板「后端连不上」 | 后端端口应为 **9097**（不是 9090）；确认 `status.cmd` 里服务在 Running |
| AI 网站打不开 | `status.cmd` 看「AI 出口」是否 loc=US；美国组两个节点都挂时会按设计直接断（不回落） |
| 下载失败（首次安装） | 重跑 `install.cmd`，已下载的不会重复；GitHub 不通会自动走 gh-proxy.com 镜像 |
| 日志 | `logs.cmd` 实时；历史在 `logs\mihomo-service.out.log` 与 `logs\scripts\` |

## 安全提醒

`config\private\nodes.yaml` / `infra-direct.yaml` 是节点凭据：不要发群、不要截图、不要提交到任何 git 仓库。
本套件所有脚本和 `config.yaml` 都不含凭据，可以放心交给 AI 看。
