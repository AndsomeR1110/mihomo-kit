# 更新日志

版本号写在套件根目录 `VERSION` 文件里（单行，如 `1.1.0`）。
`status.cmd` 会显示当前版本；`update.cmd` 会对比 GitHub 上的最新版本并升级。

## 1.1.0 - 2026-10-30

- 修复：`status.cmd`「详细状态」中文乱码（控制台代码页统一 UTF-8 + PowerShell 5.1 JSON 响应按 UTF-8 解码）
- 新增：**订阅安装模式**——`config\private\subscription.txt` 里放一行订阅链接，安装器自动改为在线订阅拉取节点，不再需要 `nodes.yaml`（面板分发的 token 订阅即用此模式）
- 新增：`update.cmd` 一键升级脚本/文档（保留你的 config、节点与日志；支持 git 安装与离线包安装两种来源）
- 新增：`doctor.cmd` 一键诊断——把版本/服务/端口/分组选择/节点延迟/三条出口实测/系统代理/最近错误汇总成一份文本报告，发给分享者即可远程排障
- 新增：版本体系（`VERSION` / `CHANGELOG.md` / status 显示版本）

## 1.0.1 - 2026-10-19

- 托盘管家升级包配套：`tray\install.cmd` 校验套件根目录后调 build.ps1

## 1.0.0 - 2026-10-18

- 首个分享版：Windows 服务 + TUN + zashboard 面板 + 断网急救 + 配置回滚体系
