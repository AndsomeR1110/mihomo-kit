# mihomo 托盘管家 v3 · 部署说明

## 文件（全部放进 `D:\mihomo\tray\`，与 tray.ps1 并存）

| 文件 | 作用 |
|---|---|
| `MihomoTray.cs` | 托盘程序源码（C# 5，单文件，UTF-8 with BOM） |
| `MihomoTray.manifest` | PerMonitorV2 DPI 感知 + 通用控件 v6，编译时嵌入 exe |
| `build.ps1` | 编译 → 结束旧托盘 → 替换 exe → 更新两个 .lnk → 启动；`-Commit` 提交 git，`-Rollback` 回滚 |
| `.gitignore` | 忽略编译产物 `MihomoTray.exe` |

`tray.ps1` 保留不动，作为回滚兜底。

## 部署（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1 -Commit
```

脚本会：用系统自带的 `csc.exe` 编译（先出临时文件，编译失败不影响正在运行的旧托盘）→ 通过 CIM 找到并结束 `tray.ps1` 的 PowerShell 进程 → 把「启动」文件夹和桌面的 `mihomo 托盘管家.lnk` 都改指向 `MihomoTray.exe` → 启动新托盘 → 提交本地 git。

旧托盘被强制结束后，任务栏可能残留一个空图标，鼠标划过即消失（Windows 机制，与新程序无关）。

## 验收自查

1. 175% 缩放下右键托盘图标：文字锐利，菜单比旧版明显紧凑（行高 24px × 1.75 = 42 物理像素）。
2. 暗色菜单、Win11 圆角；状态行：青绿圆点「运行中」+ 右侧出口节点 / 灰点「已停止（直连）」。
3. 启动 / 停止 / 重启不弹 UAC；停止后气泡提示「已切换为完全直连」，图标变灰。
4. 双击图标打开面板；「详细状态报告」打开控制台窗口；「退出托盘」后内核仍在运行。
5. 注销重登后托盘自动出现（开机自启 .lnk 生效）。

## 可调参数（`MihomoTray.cs` 顶部 `Config`，改完重跑 build.ps1）

- `Theme`：`dark`（默认）/ `light` / `auto`（跟随任务栏深浅色）
- `ExitGroup`：出口显示从哪个策略组开始解析；留空 = 自动取 MATCH 规则指向的组
- `PollMs`、`ExitRefreshSec`、`ServiceTimeoutSec`：轮询与超时
- 尺寸与配色：`PopupMenu` 顶部的 96dpi 基准常量、`Palette.Dark()`

## 回滚

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1 -Rollback
```

## 排错

- 运行时异常记录在 `%TEMP%\mihomo-tray.log`。
- 状态行没有出口名：检查桌面 `mihomo 面板.url` 的 URL 是否含 `secret=`，以及 `http://127.0.0.1:9097/configs` 是否可访问。
- 「详细状态报告」以 `powershell -NoExit -File status.ps1 -NoPause` 打开新窗口；若想换展示方式，改 `OpenReport()` 一处即可。
