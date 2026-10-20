# mihomo 菜单栏管家 · macOS

Windows 托盘管家（`tray/`）的 Mac 版：菜单栏常驻小环图标，点开即可启停代理、看当前出口、开面板。可选组件，不装不影响内核。

## 文件

| 文件 | 作用 |
|---|---|
| `MihomoBar.swift` | 菜单栏程序源码（Swift + AppKit，单文件，兼容 Swift 5.5 / macOS 12+） |
| `Info.plist` | 程序包信息模板（不显示程序坞图标；`__KIT_ROOT__` 由 build.sh 填入套件目录） |
| `build.sh` | 编译 → 免密授权 → 替换 `MihomoBar.app` → 登录自启 → 启动；`--uninstall` 卸载 |
| `install.command` / `uninstall.command` | 双击入口 |
| `.gitignore` | 忽略编译产物 `MihomoBar.app`、`build/` |

## 安装 / 升级（一条命令）

双击 `install.command`，或：

```bash
bash ~/mihomo/macos/menubar/build.sh
```

脚本会：检查 macOS 版本与 Swift 编译器 → 编译到 `build/`（失败不影响正在运行的旧版）→ 本机签名 →
登记免密启停（输入一次开机密码；已登记则跳过）→ 结束旧进程并替换 `MihomoBar.app` →
写入 `~/Library/LaunchAgents/com.mihomo-kit.menubar.plist`（登录自启）→ 启动。

没有 Swift 编译器时会弹出「Xcode 命令行工具」的系统安装窗口，装完重跑即可。

## 免密启停是怎么做的

`build.sh` 写入 `/etc/sudoers.d/mihomo-kit`（写入前用 `visudo` 校验），只允许当前用户免密执行三条固定命令：

```
/bin/launchctl enable    system/com.mihomo-kit.mihomo
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.mihomo-kit.mihomo.plist
/bin/launchctl bootout   system/com.mihomo-kit.mihomo
```

菜单栏程序用 `sudo -n` 调这几条；没有授权（或 `--no-sudoers` 安装）时自动改为弹系统密码框，一次操作只问一次。
撤销：`build.sh --uninstall` 或 `uninstall-service.command` 都会删除该文件。

## 验收自查

1. 菜单栏出现小环图标；深色 / 浅色菜单栏下都清晰（模板图，系统自动着色）。
2. 点击展开：状态行「● 运行中」+ 右侧出口节点 / 灰点「已停止（直连）」。
3. 启动 / 停止 / 重启不弹密码框；停止后通知「已切换为完全直连」，图标变成淡色空环。
4. ⌥ + 点击图标直接打开面板；「详细状态报告」在终端里打开 `status.command`；「退出菜单栏图标」后内核仍在运行。
5. 注销重登后图标自动出现。

## 可调参数（`MihomoBar.swift` 顶部 `Config`，改完重跑 build.sh）

- `exitGroup`：出口显示从哪个策略组开始解析；留空 = 自动取 MATCH 规则指向的组
- `pollInterval`、`exitRefreshSec`、`serviceTimeoutSec`：轮询与超时
- 菜单尺寸：`Layout`

## 卸载

双击 `uninstall.command`（或 `build.sh --uninstall`）：结束程序、删除登录自启与 `MihomoBar.app`、撤销免密授权。内核不受影响。

## 排错

- 运行时错误记录在 `~/Library/Logs/mihomo-menubar.log`。
- 状态行一直「未安装」：内核守护进程还没装，先运行 `macos/install.command`。
- 状态行没有出口名：检查 `config/config.yaml` 的 `secret` 是否已生成，以及 `http://127.0.0.1:9097/configs` 是否可访问。
- 通知显示为「脚本编辑器」：首次运行时没有允许 mihomo 菜单栏发通知；到「系统设置 → 通知」里打开即可。
