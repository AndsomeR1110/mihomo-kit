<#
.SYNOPSIS
  mihomo 托盘管家 v3：编译 MihomoTray.exe 并接管旧的 PowerShell 托盘。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1            # 编译 + 部署
  powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1 -Commit    # 部署后提交本地 git
  powershell -NoProfile -ExecutionPolicy Bypass -File D:\mihomo\tray\build.ps1 -Rollback  # 回滚到 tray.ps1
.NOTES
  本文件含中文，必须保存为 UTF-8 with BOM。
#>
param(
    [switch]$Commit,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
$trayDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $trayDir
$src     = Join-Path $trayDir 'MihomoTray.cs'
$mani    = Join-Path $trayDir 'MihomoTray.manifest'
$exe     = Join-Path $trayDir 'MihomoTray.exe'
$tmpExe  = Join-Path $trayDir 'MihomoTray.new.exe'
$oldPs1  = Join-Path $trayDir 'tray.ps1'
$ico     = Join-Path $rootDir 'panel-icon.ico'
$lnkName = 'mihomo 托盘管家.lnk'
$lnkDirs = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop'))

function Write-Step([string]$msg) { Write-Host "» $msg" -ForegroundColor Cyan }

function Stop-TrayProcesses {
    # 新版 exe
    Get-Process -Name MihomoTray -ErrorAction SilentlyContinue | Stop-Process -Force
    # 旧版 PowerShell 托盘（wmic 已移除，用 CIM 查命令行）
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -like '*\tray\tray.ps1*' } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
    Start-Sleep -Milliseconds 400
}

function Set-TrayShortcuts([string]$target, [string]$arguments) {
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($dir in $lnkDirs) {
        $path = Join-Path $dir $lnkName
        $s = $wsh.CreateShortcut($path)
        $s.TargetPath = $target
        $s.Arguments = $arguments
        $s.WorkingDirectory = $trayDir
        if (Test-Path $ico) { $s.IconLocation = "$ico,0" }
        $s.Description = 'mihomo 托盘管家'
        $s.Save()
        Write-Host "   $path"
    }
}

# ── 回滚：快捷方式指回 tray.ps1 ─────────────────────────────
if ($Rollback) {
    if (-not (Test-Path $oldPs1)) { throw "找不到 $oldPs1，无法回滚" }
    Write-Step '结束新版托盘'
    Stop-TrayProcesses
    Write-Step '快捷方式指回 tray.ps1'
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$oldPs1`""
    Set-TrayShortcuts 'powershell.exe' $psArgs
    Start-Process powershell.exe -ArgumentList $psArgs -WindowStyle Hidden
    Write-Host '已回滚。' -ForegroundColor Green
    return
}

# ── 1. 编译（先出到临时文件，失败不影响正在运行的托盘）─────────
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '找不到 .NET Framework 自带的 csc.exe' }

Write-Step '编译 MihomoTray.exe'
$cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+', '/codepage:65001',
    "/out:$tmpExe", "/win32manifest:$mani",
    '/reference:System.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll',
    '/reference:System.ServiceProcess.dll', '/reference:System.Web.Extensions.dll'
)
if (Test-Path $ico) { $cscArgs += "/win32icon:$ico" }
$cscArgs += $src
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) {
    Remove-Item $tmpExe -ErrorAction SilentlyContinue
    throw '编译失败（见上方错误），旧托盘未受影响'
}

# ── 2. 接管：结束旧托盘 → 替换 exe ──────────────────────────
Write-Step '结束旧托盘进程（PowerShell 版 / 旧 exe）'
Stop-TrayProcesses
Move-Item -Force $tmpExe $exe

# ── 3. 快捷方式 ─────────────────────────────────────────────
Write-Step '更新快捷方式（开机自启 + 桌面）'
Set-TrayShortcuts $exe ''

# ── 4. 启动 ─────────────────────────────────────────────────
Write-Step '启动新托盘'
Start-Process -FilePath $exe -WorkingDirectory $trayDir

# ── 5. 可选：提交本地 git ───────────────────────────────────
if ($Commit) {
    Write-Step '提交本地 git'
    Push-Location $rootDir
    try {
        git add -- tray/MihomoTray.cs tray/MihomoTray.manifest tray/build.ps1 tray/README.md tray/.gitignore
        git commit -m 'tray v3: compiled C# tray (PerMonitorV2 DPI, compact dark menu, exit node)'
    }
    finally { Pop-Location }
}

Write-Host '完成。旧托盘若在任务栏残留空图标，鼠标划过即消失。' -ForegroundColor Green
