# AGENT-INSTALL · 给 AI 助手的安装规程

你在帮用户把本仓库（mihomo-kit）装到一台 Windows 10/11 x64 电脑上：mihomo 内核以
Windows 服务方式常驻（TUN 模式接管流量），配本地 zashboard 面板，并按用户意愿在桌面
创建免密面板快捷方式。按本文档执行，不要自由发挥。

## 硬性边界（必须遵守）

1. `config\private\nodes.yaml` 与 `config\private\infra-direct.yaml` 是**凭据**：
   不读取、不修改、不复制到别处、不打印内容。你只确认它们「存在且无 `__XXX__` 占位符」。
2. 不要卸载/修改用户电脑上其他代理软件；检测到 Clash Verge 在运行，让用户自己退出。
3. `install.cmd` 会弹 UAC 并向用户提两个问题——提权和答问由用户本人完成，你负责代跑
   命令、盯输出、验收。
4. 一切结论以 `status.cmd` 的实际输出为准；服务没 Running 就不算装好。

## 步骤

### 1. 获取本仓库

- 首选 `git clone https://github.com/AndsomeR1110/mihomo-kit <目录>`
- 用户网络连不上 GitHub 时：`git clone https://gh-proxy.com/https://github.com/AndsomeR1110/mihomo-kit <目录>`
- 目标目录必须是**无空格的纯英文路径**（如 `C:\mihomo`、`D:\mihomo`）。
  从 ZIP 解压的话先 `Unblock-File` 整个目录，避免 SmartScreen 干扰。

### 2. 私有节点文件

问用户要分享者发的 `nodes.yaml` 和 `infra-direct.yaml`，放进 `config\private\`。
用户拿不到就**停下**，提醒他找分享者要；不要用 example 模板编造内容。

### 3. 安装

运行 `install.cmd`（等价 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1`）。
它是幂等的：已完成的步骤自动跳过，失败重跑即可。首次运行自动下载内核 v1.19.32、
WinSW v2.12.0、zashboard 面板、规则集（GitHub 直连失败自动走 gh-proxy.com 镜像）。

用户要回答的两个问题：

1. 桌面「mihomo 面板」快捷方式（免密自动登录）——默认 Y
2. 关闭网卡 IPv6 与 Teredo——校园网建议 Y（随时可 `system-tweaks-revert.cmd` 恢复）

只想做检查不装服务：`install.cmd -DryRun`。

### 4. 验收（全部满足才算完成）

- `status.cmd`：服务状态 **Running**、启动类型 Automatic
- 面板可打开（桌面快捷方式或 `panel.cmd`），节点延迟非 0
- `status.cmd` 出口实测：默认出口 ip/loc 有值；AI 出口（claude.ai）**loc=US**
- 提醒用户：正常用几天后双击 `mark-good.cmd` 存「已知可用」版本

### 5. 交付给用户的口头说明

日常入口三个：`status.cmd` 看状态、`panel.cmd` 开面板、`rescue.cmd` 断网急救。
改配置流程：改 `config\config.yaml` → `test-config.cmd` → `apply-config.cmd`。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 下载中途失败 | 重跑 `install.cmd`（断点式，不重复下载） |
| 端口 7897/9097 被占用 | 让用户退出其他代理软件后重跑 |
| 服务注册被 360 拦 | 用户在弹窗选「允许」并把目录加信任区，重跑 |
| 安装后断网 | `rescue.cmd` 恢复直连，看 `logs\mihomo-service.out.log` |
| 面板连不上 | 后端端口是 **9097**（zashboard 预填 9090 是坑），密钥在 config.yaml 的 secret |
