# mihomo-kit · 校园网代理套件（macOS）

Windows 版的 Mac 移植：mihomo 独立内核以 **launchd 系统守护进程**开机自启 + TUN 全局接管 + 本地面板（zashboard），
可选**菜单栏图标**（相当于 Windows 的托盘管家）。节点、分流规则、面板与 Windows 版完全一致，共用同一份 `config/`。

## 你需要准备

- macOS 12 Monterey 或更新（Apple 芯片 / Intel 都支持），能输入开机密码的管理员账户
- 分享者给你的两个文件：`nodes.yaml` 和 `infra-direct.yaml`（**这是凭据，别外传**）
- 电脑上已有的代理软件（Clash Verge、ClashX 等）需先退出——两者不能同时用，安装器会检测

## 安装

1. 把套件放到 **个人文件夹下、没有空格的英文路径**，推荐 `~/mihomo`
   - **不要**放在「桌面 / 文稿 / 下载」或 iCloud 里：macOS 不允许后台服务读这些目录，内核会起不来（安装器会拦下）
   - Git 用户：`git clone https://github.com/AndsomeR1110/mihomo-kit ~/mihomo`
     （GitHub 连不上就在地址前加 `https://gh-proxy.com/`）
2. 把 `nodes.yaml`、`infra-direct.yaml` 放进 `config/private/`
3. 打开 `macos` 文件夹，双击 `install.command`，按提示输入开机密码、回答两个问题
4. 完成——桌面会有「mihomo 面板」快捷方式（安装时选 Y 即可，免密直达）

> **第一次双击 `.command` 被拦**（“无法打开，因为无法验证开发者”）：在文件上 **右键 → 打开 → 打开**，之后就不会再问；
> 或在「终端」里执行一次 `xattr -dr com.apple.quarantine ~/mihomo`。安装器之后会自动给整个目录解除隔离。
>
> 双击没反应 / 提示没有权限：在终端执行 `chmod +x ~/mihomo/macos/*.command ~/mihomo/macos/menubar/*.command`。
>
> macOS 13 及以上会弹「已添加后台项目」通知，属正常；**不要**在「系统设置 → 通用 → 登录项」里把 mihomo 关掉。

## 日常使用（`macos` 文件夹里双击）

| 文件 | 作用 | 要密码 |
| --- | --- | --- |
| `status.command` | 守护进程状态、内存、当前出口、节点延迟、出口实测、最近日志 | 否 |
| `panel.command` | 打开面板（自动带密钥，免登录） | 否 |
| `logs.command` | 实时看内核日志（Ctrl+C 退出） | 否 |
| `start.command` / `stop.command` / `restart.command` | 启动 / 停止 / 重启内核 | 是 |
| `rescue.command` | **断网急救**：停内核并取消自启、关残留系统代理、刷新 DNS、测直连 | 是 |

装了菜单栏图标后，启停直接在菜单栏点，不用输密码。

## 菜单栏图标（可选，推荐）

双击 `macos/menubar/install.command`：用系统的 Swift 编译器现场编译、部署并设为登录自启。菜单栏右上角出现小环图标：

- **点击**展开菜单：状态行（运行中 + 当前出口节点）/ 启动 / 停止 / 重启代理 / 打开面板 / 详细状态报告 / 退出
- **⌥ Option + 点击**直接打开面板
- 运行中 = 完整图标，停止 = 淡色空环；启停后发系统通知
- 启停**免密**：安装时会输入一次开机密码，向系统登记“这个用户可以不输密码启停 mihomo”（只放行三条固定命令）

前提：需要 **Xcode 命令行工具**（几百 MB）。没装的话安装脚本会弹出系统的安装窗口，装完再双击一次即可；
不想装也完全没关系，上面的 `.command` 照常可用。详细说明见 [menubar/README.md](menubar/README.md)。

卸载：双击 `macos/menubar/uninstall.command`（内核不受影响）。

## 改配置

| 文件 | 作用 | 要密码 |
| --- | --- | --- |
| `test-config.command` | 检查占位符、证书指纹格式和配置语法 | 否 |
| `apply-config.command` | 检查 → 存档 → 重启 → 健康检查；起不来自动退回 | 是 |
| `mark-good.command` | 把当前配置存为「已知可用」版本 | 否 |
| `rollback.command` | 退回「已知可用」版本 | 是 |

配置文件就是套件根目录的 `config/config.yaml`，与 Windows 版通用。

## 面板（zashboard）

- 免密入口：桌面「mihomo 面板」、`panel.command`，或菜单栏 ⌥ + 点击
- 手动填：后端 `http://127.0.0.1:9097`，密钥是 `config/config.yaml` 里的 `secret`
  （zashboard 设置页默认预填 9090，**实际端口是 9097**）
- 面板里的手动选择会被记住，重启不变；**美国组是 AI 专用的，一般不用动**

## 系统调整（可选）

| 文件 | 作用 |
| --- | --- |
| `system-tweaks-apply.command` | 关闭各网络服务（Wi-Fi、有线等）的 IPv6，防止流量绕过代理（会记录原状态） |
| `system-tweaks-revert.command` | 恢复到调整前 |

校园网环境建议开启（安装时问过一次）。另建议手动关闭浏览器的「使用安全 DNS」。

## 卸载

1. 装过菜单栏图标：双击 `macos/menubar/uninstall.command`
2. 双击 `macos/uninstall-service.command`（注销守护进程，同时撤销免密授权）
3. 做过系统调整：双击 `macos/system-tweaks-revert.command`
4. 删除整个套件文件夹和桌面快捷方式

## 故障排查

| 症状 | 处理 |
| --- | --- |
| 完全断网 | 双击 `rescue.command` 恢复直连，再排查 |
| 内核起不来、日志里有 `operation not permitted` / 读不到配置 | 套件在桌面 / 文稿 / 下载 / iCloud 里：移到 `~/mihomo` 后重跑 `install.command` |
| 重启电脑后代理没自动开 | 「系统设置 → 通用 → 登录项 → 允许在后台」里确认 mihomo 是打开的；`rescue` 之后需要 `start.command` 恢复自启 |
| 面板「后端连不上」 | 后端端口应为 **9097**（不是 9090）；`status.command` 里守护进程应为 Running |
| AI 网站打不开 | `status.command` 看「AI 出口」是否 loc=US；美国组两个节点都挂时会按设计直接断（不回落） |
| 校园网登录页不弹 | 先 `stop.command` 登录，再 `start.command`；或在浏览器手动打开校园网登录地址 |
| 菜单栏启停仍要密码 | 重新双击 `menubar/install.command`（会重新登记免密授权） |
| 下载失败（首次安装） | 重跑 `install.command`，已下载的不会重复；GitHub 不通会自动走 gh-proxy.com 镜像 |
| 日志 | `logs.command` 实时；历史在 `logs/mihomo.out.log*` 与 `logs/scripts/`；菜单栏程序的错误在 `~/Library/Logs/mihomo-menubar.log` |

## 和 Windows 版的对应关系

| Windows | macOS |
| --- | --- |
| `xxx.cmd`（根目录） | `macos/xxx.command` |
| `scripts/*.ps1` | `macos/scripts/*.sh`（macOS 自带 bash 3.2，无需安装任何东西） |
| WinSW 服务 `mihomo` | launchd 守护进程 `com.mihomo-kit.mihomo`（`/Library/LaunchDaemons/`） |
| UAC 提权 | 终端里输入开机密码（sudo） |
| 托盘管家 `tray/` | 菜单栏图标 `macos/menubar/` |
| 关闭 IPv6 + Teredo | 关闭 IPv6（macOS 没有 Teredo） |
| `mihomo 面板.url` | `mihomo 面板.webloc` |

## 安全提醒

`config/private/nodes.yaml` / `infra-direct.yaml` 是节点凭据：不要发群、不要截图、不要提交到任何 git 仓库。
本套件所有脚本和 `config.yaml` 都不含凭据，可以放心交给 AI 看。

内核以 root 运行套件目录里的 `bin/mihomo`（TUN 需要），所以套件目录请保持只有你自己能写——放在个人文件夹下即可。
