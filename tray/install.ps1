# mihomo-kit 托盘升级安装器：定位套件根目录 → 校验 → 调 build.ps1 编译部署
# 用法（用户）：双击 install.cmd；高级：powershell -File install.ps1 [-TestOnly]
param([switch]$TestOnly)
$ErrorActionPreference = 'Stop'
$trayDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent $trayDir

function Fail([string]$msg) {
    Write-Host ''
    Write-Host $msg -ForegroundColor Red
    Write-Host '  正确做法：把升级包解压/复制到你的 mihomo 套件目录（能看到 panel.cmd、config 文件夹的那一层），' -ForegroundColor Yellow
    Write-Host '  选择「替换同名文件」，然后再双击 tray\install.cmd。' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path (Join-Path $trayDir 'MihomoTray.cs'))) { Fail '当前目录结构不对：找不到 MihomoTray.cs。' }
if (-not (Test-Path (Join-Path $root 'config\config.yaml'))) { Fail "上级目录($root) 不是套件根目录：没有 config\config.yaml。" }
if (-not (Test-Path (Join-Path $root 'panel-icon.ico'))) { Fail "套件根目录缺少 panel-icon.ico（升级包里的两个 .ico 要放在和 panel.cmd 同级）。" }
if (-not (Test-Path (Join-Path $root 'panel-icon-off.ico'))) { Fail '套件根目录缺少 panel-icon-off.ico（升级包里的两个 .ico 要放在和 panel.cmd 同级）。' }

Write-Host "[OK] 已识别套件目录：$root" -ForegroundColor Green
if ($TestOnly) {
    Write-Host '[TestOnly] 校验通过，未执行编译部署。' -ForegroundColor Cyan
    exit 0
}
Write-Host '开始编译并部署托盘……' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $trayDir 'build.ps1')
