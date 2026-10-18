# 把当前配置保存为“已知可用”版本（rollback.cmd 会退回到这里）。不需要管理员权限。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'mark-good'

try {
    Write-Title '保存为已知可用版本'
    $t = Test-MihomoConfig
    if (-not $t.Ok) { throw '当前配置检查未通过，不能标记为可用' }
    $ver = $null
    try { $ver = (Invoke-Api '/version').version } catch { }
    if (-not $ver) { throw '内核没有运行，无法确认当前配置可用' }
    if (Test-Path $LastGoodDir) {
        $old = Join-Path $HistoryDir ('last-good-before-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $HistoryDir -Force | Out-Null
        Move-Item -Path $LastGoodDir -Destination $old
        Write-Info "旧的已知可用版本移到：$old"
    }
    Save-Snapshot $LastGoodDir
    Set-Content -Path (Join-Path $LastGoodDir 'marked-at.txt') -Value (Get-Date).ToString('s') -Encoding UTF8
    Write-Ok "已保存到 $LastGoodDir"
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
