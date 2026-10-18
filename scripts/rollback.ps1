# 退回“已知可用”版本（mark-good.cmd 保存的那一份）并重启。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'rollback'

try {
    if (-not (Test-Path (Join-Path $LastGoodDir 'config.yaml'))) {
        throw '还没有“已知可用”版本（验收通过后运行 mark-good.cmd 才会有）'
    }
    Write-Title '1/3 存档当前配置'
    $snap = Join-Path $HistoryDir ('before-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Save-Snapshot $snap
    Write-Ok $snap

    Write-Title '2/3 恢复已知可用版本'
    Restore-Snapshot $LastGoodDir
    $marked = Join-Path $LastGoodDir 'marked-at.txt'
    if (Test-Path $marked) { Write-Ok ("已恢复（该版本标记于 {0}）" -f (Get-Content $marked -Encoding UTF8)) }

    Write-Title '3/3 重启'
    Stop-MihomoService
    Start-MihomoService
    $ver = Wait-Api 30
    if ($ver) {
        Save-Snapshot $AppliedDir
        Write-Ok "内核已就绪：$ver"
    } else {
        Write-Fail '恢复后内核仍无法启动，请运行 rescue.cmd 恢复直连'
        Show-RecentLog 20
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
