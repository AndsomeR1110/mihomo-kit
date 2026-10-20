# mihomo-kit · 校园网代理套件（Windows）

一套开箱即用的 mihomo 独立内核：Windows 服务开机自启 + TUN 全局接管 + 本地面板（zashboard）。
节点来自分享者的自建 VPS（香港 / 美国双出口）：默认流量走香港，**AI 网站固定走美国**，国内流量直连、不耗 VPS 流量。

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
| `clean-stray.cmd` | **清残留内核**：结束占着端口却不是当前服务子进程的 mihomo 进程，然后重启服务 | 是 |
| `proxy-mode.cmd -Mode rule\|global\|direct` | 切换代理模式（等同托盘右键里的那三项） | 否 |
| `dns-override.cmd -State on\|off\|toggle\|get` | 开关 DNS 覆写（全量防 DNS 泄露 + 严格路由） | 是（要重启内核） |

托盘右键里也能切这两项：**代理模式**（规则 / 全局 / 直连，热切换）和 **DNS 覆写**（开 / 关）。
详见 [tray/README.md](tray/README.md)。

## DNS 覆写（全量防 DNS 泄露）

`config.yaml` 的 `dns:` 段被夹在 `# >>> dns-override >>>` 与 `# <<< dns-override <<<` 之间，
内容来自 `config\dns\on.yaml`（开）或 `config\dns\off.yaml`（关，出厂默认）。
**同一个开关还负责顶层 `tun.strict-route`**，两处一起改、一起校验、一起回滚：

| | `dns:` 段 | `tun.strict-route` |
| --- | --- | --- |
| **关（基线）** | 全部域名用国内公共 DNS（阿里 / DNSPod） | `false` |
| **开** | 全部域名（含国内、校园网、自有服务器）用 `1.1.1.1` / `8.8.8.8` 解析，查询本身经「美国组」的代理隧道发出 | `true` |

开启时**不再保留任何例外**：没有 `nameserver-policy`，没有指向大陆 DNS 的 `fallback`，
也没有「校园网用系统 DNS」这类条目。代价是只能由校园网内部 DNS 解析的域名会无法访问
（包括登录门户 `xjtlu.edu.cn`）；需要登录前就能解析校园网门户时，请把开关关掉。

DNS 出口固定用「美国组」而不是「默认出口」：默认出口可以被手动选成 `DIRECT`，
那样 DNS 查询会变成直连（泄露）。美国组只装 `US-` 节点、`empty-fallback: REJECT`，
不会选择也不会回落到 `DIRECT`。

> ⚠️ `dns:` 段与 `tun.strict-route` 都只能在启动时装载，所以开关 DNS 覆写会**重启一次内核**
> （需要管理员权限）。若新方案下内核没起来，脚本/托盘会把**整份配置**退回原样再重启，
> 不会把你留在断网状态，也不会留下「DNS 是新的、路由开关是旧的」这种半成品。

想调整两种模式的策略，直接改 `config\dns\on.yaml` / `off.yaml`（改完不用管 `config.yaml`，
下次切换时会自动带入）。只改注释不影响状态判断；改了实质字段后状态会显示为「配置与方案不一致」，
重新运行一次开关即可对齐。

> **从旧版升级过来的注意**：旧版的 `on.yaml` 只把境外域名送出去、国内域名仍用国内 DNS，
> 而且开关不管 `tun.strict-route`。升级后 `config.yaml` 里的旧内容与新的两份方案都对不上，
> 所以状态会显示「配置与方案不一致」——这是预期行为，运行一次
> `dns-override.cmd -State on`（或点一次托盘开关）就会写成新方案。

### 这套东西管不到的地方

`dns-hijack: any:53` 只截获发往 53 端口的明文 DNS，`strict-route` 只补一条抑制多网卡 DNS 泄露的
防火墙规则。两者都**不能**把任意应用的 HTTPS 加密 DNS（DoH / DoT）自动改写成指定上游。

所以要覆盖整台电脑，还需要：

- 浏览器关闭「使用安全 DNS / Secure DNS / DoH」；
- 其他带自定义 DNS 的应用（安全软件、下载器、游戏启动器、Docker、WSL 等）移除大陆 DNS 设置；
- 确认真实路径要看内核连接记录或抓包，不能只看检测网站的一次结果。

代理节点自身的地址是 IP 字面量，所以 `proxy-server-nameserver` 不会形成
「要连代理得先解析代理域名」的死锁。**以后若加入域名形式的节点**（例如 `hk.example.com`），
必须重新设计这一项，不能直接沿用 `on.yaml`，也不能恢复国内 DNS。


## 改配置

| 文件 | 作用 | 需要管理员 |
| --- | --- | --- |
| `test-config.cmd` | 检查占位符、证书指纹格式和配置语法 | 否 |
| `apply-config.cmd` | 检查 → 存档 → 重启 → 健康检查；起不来自动退回 | 是 |
| `mark-good.cmd` | 把当前配置存为「已知可用」版本 | 否 |
| `rollback.cmd` | 退回「已知可用」版本 | 是 |

改 `config.yaml` 时注意：`# >>> dns-override >>>` 与 `# <<< dns-override <<<` 之间那一段
由托盘 / `dns-override.cmd` 托管，手改会被下次切换覆盖（要改就改 `config\dns\` 下的两份方案）。
其余部分随便改，改完照旧 `test-config.cmd` → `apply-config.cmd`。


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

校园网环境建议开启（安装时问过一次，忘了就现在双击 apply）。
另外，**开启 DNS 覆写时要手动关掉浏览器和各类应用自带的「安全 DNS / DoH」**，否则它们会绕过内核
直接向自己的上游查询，内核配置得再严也管不到（详见上一节的「这套东西管不到的地方」）。

### 验收：怎么确认 DNS 真的没泄露

1. `dns-override.cmd -State on`，确认最后打印「DNS 覆写与严格路由都已按新方案生效」。
2. `status.cmd`：运行时 TUN = True、`tun.strict-route` = True、配置内容 = 开启方案。
3. 在面板（或 `curl` 内核 API `/connections`）里找 `1.1.1.1:443` / `8.8.8.8:443` 的内部连接，
   它们的 `chains` 应包含 `美国组`，绝不能出现 `DIRECT`。
4. 浏览器打开 [Net.Coffee DNS 深度测试](https://ip.net.coffee/dns/)，结果里不应出现大陆解析器。
5. 把「美国组」两个节点都停掉（或临时把 `on.yaml` 的上游改成一个不可达地址）后重试解析：
   查询应当**失败**，而不是自动改用国内 DNS —— 这是「不回落」设计是否成立的关键验证。
6. 关掉开关、再打开、重启电脑后各核对一次（脚本每次切换都会自动打印核对结果）。

> 出口地区（`loc=US`）只说明业务流量走了哪条隧道，**不能证明 DNS 没有泄露**，两者要分开验证。

## 卸载

1. 双击 `uninstall-service.cmd`（注销服务）
2. 若做过系统调整，双击 `system-tweaks-revert.cmd`
3. 删除整个文件夹（桌面快捷方式一并删掉）

## 故障排查

| 症状 | 处理 |
| --- | --- |
| 完全断网 | 双击 `rescue.cmd` 恢复直连，再排查 |
| **服务显示 Running，但面板连不上、代理完全不通** | 多半是残留（孤儿）内核占着 7897/9097。跑 `clean-stray.cmd`（管理员），它会清掉残留并重启服务。`status.cmd` 的「残留内核检查」一节会直接指出 pid 和端口 |
| 面板「后端连不上」 | 后端端口应为 **9097**（不是 9090）；确认 `status.cmd` 里服务在 Running、且「残留内核检查」干净 |
| 重启内核后偶发不通 | mihomo 重启会先拉起新进程再退出旧的，WinSW 同时判定子进程退出时可能留下孤儿。重跑一次 `clean-stray.cmd` 即可；平时 `start.cmd` / `dns-override.cmd` 也会在动作前自动清一次 |
| AI 网站打不开 | `status.cmd` 看「AI 出口」是否 loc=US；美国组两个节点都挂时会按设计直接断（不回落） |
| 开了 DNS 覆写后国内域名/校园网也变慢或解析失败 | 正常：开启时所有域名（含国内、校园网）都经代理 DNS 解析。要登录校园网门户就先把开关关掉 |
| 开了 DNS 覆写后所有域名都解析失败 | 美国组节点全挂：解析路径没有回退设计。先在面板换/修节点，或关掉 DNS 覆写 |
| 托盘里 DNS 覆写开关点了没反应 | 检查 `config\config.yaml` 是否还有那两个标记、`config\dns\on.yaml` 与 `off.yaml` 是否都在 |
| 托盘显示「配置与方案不一致」 | `config\dns\*.yaml` 改过但还没应用（或 `tun.strict-route` 被手改）。点一次开关重新对齐 |
| 托盘显示「已写入 · 待应用」 | 文件写好了但内核没重启（或没起来）。运行 `restart.cmd`，或再点一次开关 |
| 托盘显示「端口被其他代理占用」/ status 报 TUN stack 不符 | 有别的代理软件（Clash Verge / Clash Party 等）先占了 9097 端口，读到的运行时状态不是本套件的。先彻底退出它们（含后台服务），再重跑 |
| 下载失败（首次安装） | 重跑 `install.cmd`，已下载的不会重复；GitHub 不通会自动走 gh-proxy.com 镜像 |
| 日志 | `logs.cmd` 实时；历史在 `logs\mihomo-service.out.log` 与 `logs\scripts\` |

## 安全提醒

`config\private\nodes.yaml` / `infra-direct.yaml` 是节点凭据：不要发群、不要截图、不要提交到任何 git 仓库。
本套件所有脚本和 `config.yaml` 都不含凭据，可以放心交给 AI 看。
