# AGENT-INSTALL（macOS）· 给 AI 助手的安装规程

你在帮用户把本仓库（mihomo-kit）装到一台 macOS 12+ 的 Mac 上（Apple 芯片或 Intel）：mihomo 内核以
launchd 系统守护进程常驻（TUN 模式接管流量），配本地 zashboard 面板，并按用户意愿在桌面创建免密面板快捷方式、
安装菜单栏图标。按本文档执行，不要自由发挥。Windows 电脑请看根目录的 [AGENT-INSTALL.md](../AGENT-INSTALL.md)。

## 硬性边界（必须遵守）

1. `config/private/nodes.yaml` 与 `config/private/infra-direct.yaml` 是**凭据**：
   不读取、不修改、不复制到别处、不打印内容。你只确认它们「存在且无 `__XXX__` 占位符」。
2. 不要卸载/修改用户电脑上其他代理软件；检测到 Clash Verge / ClashX 在运行，让用户自己退出。
3. 需要 root 的脚本会在终端里要开机密码——**密码由用户本人输入**，不要索要、不要代填、不要改 sudoers 绕过。
   你负责代跑命令、盯输出、验收。
4. 一切结论以 `macos/status.command` 的实际输出为准；守护进程没 Running 就不算装好。

## 步骤

### 1. 获取本仓库

- 首选 `git clone https://github.com/AndsomeR1110/mihomo-kit ~/mihomo`
- 用户网络连不上 GitHub 时：`git clone https://gh-proxy.com/https://github.com/AndsomeR1110/mihomo-kit ~/mihomo`
- 目标目录必须在**个人文件夹下、无空格的英文路径**（推荐 `~/mihomo`）。
  **不能**放在 `~/Desktop`、`~/Documents`、`~/Downloads` 或 iCloud 里（受 macOS 隐私保护，root 守护进程读不到）。
- 从 ZIP 解压的话先执行 `xattr -dr com.apple.quarantine ~/mihomo`，避免 Gatekeeper 拦截。

### 2. 私有节点文件

问用户要分享者发的 `nodes.yaml` 和 `infra-direct.yaml`，放进 `config/private/`。
用户拿不到就**停下**，提醒他找分享者要；不要用 example 模板编造内容。

### 3. 安装

运行 `bash ~/mihomo/macos/scripts/install.sh`（等价于双击 `macos/install.command`）。它会用 sudo 要开机密码，
是幂等的：已完成的步骤自动跳过，失败重跑即可。首次运行自动下载内核 v1.19.32（按芯片选 arm64 / amd64）、
zashboard 面板、规则集（GitHub 直连失败自动走 gh-proxy.com 镜像）。

用户要回答的两个问题：

1. 桌面「mihomo 面板」快捷方式（免密自动登录）——默认 Y
2. 关闭各网络服务的 IPv6——校园网建议 Y（随时可 `system-tweaks-revert.command` 恢复）

只想做检查不装守护进程：`install.sh --dry-run`。

### 4. 菜单栏图标（可选）

用户想要时运行 `bash ~/mihomo/macos/menubar/build.sh`（**不要加 sudo**）。需要 Xcode 命令行工具：
没装时脚本会弹系统安装窗口并退出，请用户点「安装」，装完重跑。脚本会请用户输入一次密码登记免密启停。

### 5. 验收（全部满足才算完成）

- `status.command`（或 `bash macos/scripts/status.sh --no-pause`）：状态 **Running**、启动方式「开机自启」
- 面板可打开（桌面快捷方式或 `panel.command`），节点延迟非 0
- 出口实测：默认出口 ip/loc 有值；AI 出口（claude.ai）**loc=US**
- 装了菜单栏的话：图标显示运行中，点「停止代理」不弹密码框且图标变淡，再点「启动代理」恢复
- 提醒用户：正常用几天后双击 `mark-good.command` 存「已知可用」版本

### 6. 交付给用户的口头说明

日常入口：菜单栏图标（或 `status.command` 看状态、`panel.command` 开面板）、`rescue.command` 断网急救。
改配置流程：改 `config/config.yaml` → `test-config.command` → `apply-config.command`。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 下载中途失败 | 重跑 `install.sh`（断点式，不重复下载） |
| 端口 7897/9097 被占用 | 让用户退出其他代理软件后重跑 |
| 安装器提示“受隐私保护的目录” | 把整个套件移到 `~/mihomo` 后重跑 |
| 守护进程起不来 | `logs.command` 看日志；必要时 `rescue.command` 恢复直连后告诉用户卡在哪一步 |
| 菜单栏编译失败 | 确认 `xcode-select -p` 有输出；macOS 版本 ≥ 12 |
