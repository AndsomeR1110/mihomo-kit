# mihomo 托盘管家 v4 · 部署说明

## 文件（全部放进 `D:\mihomo\tray\`）

| 文件 | 作用 |
|---|---|
| `MihomoTray.cs` | 托盘程序源码（C# 5，单文件，UTF-8 with BOM） |
| `MihomoTray.manifest` | PerMonitorV2 DPI 感知 + 通用控件 v6，编译时嵌入 exe |
| `build.ps1` | 编译 → 结束旧托盘 → 替换 exe → 更新两个 .lnk → 启动；`-Commit` 提交 git，`-Rollback` 回滚 |
| `.gitignore` | 忽略编译产物 `MihomoTray.exe` |

## 部署（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1 -Commit
```

脚本会：用系统自带的 `csc.exe` 编译（先出临时文件，编译失败不影响正在运行的旧托盘）→ 结束旧托盘进程 → 把「启动」文件夹和桌面的 `mihomo 托盘管家.lnk` 都改指向 `MihomoTray.exe` → 启动新托盘 → 提交本地 git。

旧托盘被强制结束后，任务栏可能残留一个空图标，鼠标划过即消失（Windows 机制，与新程序无关）。

## 菜单结构

```
● 运行中                              HK-Reality     ← 状态 + 当前出口
─────────────────────────────────────
▶ 启动代理
■ 停止代理                            完全直连
↻ 重启代理
─────────────────────────────────────
代理模式                                              ← 分组标题
◉ 规则模式                            按规则分流
○ 全局模式                            全部走默认出口
○ 直连模式                            全部直连
─────────────────────────────────────
DNS
☑ DNS 覆写                            全量防泄露 · 已生效
─────────────────────────────────────
◈ 打开面板                            双击图标
☰ 详细状态报告
─────────────────────────────────────
✕ 退出托盘                            内核不受影响
```

双击托盘图标 = 打开面板。

## 两个新开关怎么工作

### 代理模式（规则 / 全局 / 直连）

调 `PATCH /configs {"mode":…}` **立即生效**（内核不用重启），同时把 `config.yaml` 的 `mode:` 一行改掉，
这样重启内核 / 重启电脑后保持你选的模式。不需要管理员权限。

| 模式 | 含义 |
|---|---|
| 规则模式 | 按 `config.yaml` 的规则分流（日常用这个） |
| 全局模式 | 所有流量走「默认出口」指向的策略组；AI 域名不再单独走美国组 |
| 直连模式 | 所有流量直连（等于临时关掉分流，内核仍在跑） |

命令行等价：`proxy-mode.cmd -Mode global`

### DNS 覆写（开 / 关）

`config.yaml` 里 `dns:` 整段被夹在 `# >>> dns-override >>>` 与 `# <<< dns-override <<<`
两个标记之间，内容来自 `config\dns\on.yaml` 或 `config\dns\off.yaml`。
**同一个开关还会改顶层 `tun.strict-route`**，两处一起改、一起校验、一起回滚：

| | `dns:` 段 | `tun.strict-route` |
| --- | --- | --- |
| **关（基线）** | 全部域名用国内公共 DNS（阿里 / DNSPod） | `false` |
| **开** | 全部域名（含国内、校园网、自有服务器）用 `1.1.1.1` / `8.8.8.8` 解析，查询经「美国组」的代理隧道发出 | `true` |

开启时不再保留任何例外（没有 `nameserver-policy`、没有大陆 DNS 回退、没有 `system` 条目）；
代价是只能由校园网内部 DNS 解析的域名会无法访问，包括登录门户 `xjtlu.edu.cn`。
DNS 出口固定用「美国组」而不是「默认出口」，因为默认出口可能被手动选成 `DIRECT`。

状态显示（`dnsRow.Hint`）分四种，避免把「文件写好了」当成「保护已生效」：

| 显示 | 含义 |
| --- | --- |
| `全量防泄露 · 已生效` | 配置内容 = on 方案，且运行时 TUN 开、`strict-route` = true |
| `已写入 · 待应用` | 文件已是目标方案，但运行时状态不符（未重启内核 / 内核没起来） |
| `已关闭` | 配置内容 = off 方案，且运行时 `strict-route` = false |
| `配置与方案不一致` | `config\dns\*.yaml` 改过还没应用，或 `tun.strict-route` 被手改成不配套的值 |
| `端口被其他代理占用` | 9097 端口由别的代理软件（Clash Verge / Clash Party 等）回答，运行时状态不可信 |

> 从旧版升级后，`config.yaml` 里的旧 DNS 内容与新的两份方案都对不上，会显示「配置与方案不一致」；
> 点一次开关就会写成新方案（同时把 `tun.strict-route` 对齐）。

> ⚠️ **`dns:` 段与 `tun.strict-route` 都只能在启动时装载**：改完必须重启内核才生效，
> 所以这个开关会自动重启服务（需要管理员权限，会弹一次 UAC）。
> 切换前会先存下整份 `config.yaml`；重启后若内核没起来、或运行时 TUN / `strict-route` 与目标不符，
> 就把整份配置写回去再重启一次，不会把你留在断网状态，也不会留下「DNS 是新的、路由开关是旧的」半成品。

命令行等价：`dns-override.cmd -State on|off|toggle|get`
（`-NoRestart` 只改文件不重启，此时会明确提示「保护尚未生效」；`-State get` 只打印当前状态）

> 托盘只约束系统与内核的 DNS。浏览器/其他应用自带的「安全 DNS(DoH)」会绕过内核直接查询，
> 要覆盖全机必须同时关掉它们 —— 详见根目录 README 的「这套东西管不到的地方」。

## 验收自查

1. 175% 缩放下右键托盘图标：文字锐利，菜单紧凑（行高 24px × 1.75 = 42 物理像素）。
2. 暗色菜单、Win11 圆角；状态行：青绿圆点「运行中」+ 右侧出口节点 / 灰点「已停止（直连）」。
3. 「代理模式」三行是单选圈，点一下立刻切换并弹气泡；再开菜单时选中项正确。
4. 「DNS 覆写」是勾选框，点一下会提权重启内核，气泡提示「已开启 / 已关闭」；
   状态行要能区分「全量防泄露 · 已生效」「已写入 · 待应用」「配置与方案不一致」三种情况
   （手动把 `config.yaml` 的 `tun.strict-route` 改成与 `dns:` 段不配套的值，应显示「配置与方案不一致」）。
5. 启动 / 停止 / 重启不弹 UAC；停止后气泡「已切换为完全直连」，图标变灰。
6. 双击图标打开面板；「详细状态报告」打开控制台窗口；「退出托盘」后内核仍在运行。
7. 注销重登后托盘自动出现（开机自启 .lnk 生效）。

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
- 「DNS 覆写」点了没反应 / 反复弹 UAC：检查 `config\config.yaml` 里是否还有那两个标记，
  以及 `config\dns\on.yaml`、`off.yaml` 是否都在，还有 `tun:` 段里是否有 `strict-route` 这一行
  （缺了会直接报错，不会静默写坏配置）。
- 开关状态显示不对：菜单每次打开都会重读 `config.yaml` 和内核运行时状态，手动改过文件的话
  关掉菜单再打开即可；显示「配置与方案不一致」说明 `config\dns\*.yaml` 与 `config.yaml` 已经不同步，
  点一次开关就会重新对齐。
