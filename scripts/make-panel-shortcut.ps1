# 在桌面创建「mihomo 面板」快捷方式（.url 免密自动登录 + 套件自带图标）
# 面板密钥从 config.yaml 的 secret 读取；-DestinationDir 供测试用
param([string]$DestinationDir = '', [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'make-panel-shortcut'

try {
    if (-not $DestinationDir) { $DestinationDir = [Environment]::GetFolderPath('Desktop') }
    $secret = Get-ApiSecret
    if (-not $secret) { throw 'config.yaml 里没有 secret，请先运行 prepare.cmd' }
    $base = Get-ApiBase                                   # 例如 http://127.0.0.1:9097
    $port = [int](($base -split ':')[2])
    $url  = "$base/ui/?hostname=127.0.0.1&port=$port&secret=$secret"
    $icon = Join-Path $Root 'panel-icon.ico'
    if (-not (Test-Path $icon)) { Write-Warn2 '没找到 panel-icon.ico，快捷方式将没有自定义图标' }
    $lnk   = Join-Path $DestinationDir 'mihomo 面板.url'
    $lines = @(
        '[InternetShortcut]',
        "URL=$url",
        "IconFile=$icon",
        'IconIndex=0'
    )
    [IO.File]::WriteAllLines($lnk, $lines, (New-Object Text.UTF8Encoding($false)))
    Write-Ok "已创建 $lnk"
    Write-Info "双击即可免密进入面板（地址 $base/ui ）"
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
