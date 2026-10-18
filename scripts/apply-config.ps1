# 应用修改后的配置：检查 → 留快照 → 重启 → 健康检查；内核起不来就自动退回上一次成功的配置。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'apply-config'

try {
    if (-not (Get-MihomoService)) { throw '服务未注册，请先运行 install-service.cmd' }

    Write-Title '1/4 检查新配置'
    $t = Test-MihomoConfig
    if (-not $t.Ok) {
        $t.Lines | Select-Object -Last 8 | ForEach-Object { Write-Info $_ }
        throw '新配置检查未通过，未做任何改动，服务继续使用原配置'
    }
    Write-Ok '检查通过'

    Write-Title '2/4 留快照'
    $snap = Join-Path $HistoryDir (Get-Date -Format 'yyyyMMdd-HHmmss')
    Save-Snapshot $snap
    Write-Ok "新配置已存档：$snap"

    Write-Title '3/4 重启内核'
    Stop-MihomoService
    Start-MihomoService
    $ver = Wait-Api 30

    Write-Title '4/4 健康检查'
    if (-not $ver) {
        Write-Fail '新配置下内核 30 秒内没有就绪，最近日志：'
        Show-RecentLog 20
        if (Test-Path (Join-Path $AppliedDir 'config.yaml')) {
            Write-Warn2 '正在自动退回上一次成功应用的配置……'
            Restore-Snapshot $AppliedDir
            Stop-MihomoService
            Start-MihomoService
            if (Wait-Api 30) { Write-Ok '已退回并恢复运行。出问题的版本保存在上面的存档目录里' }
            else { Write-Fail '退回后仍无法启动，请运行 rescue.cmd 恢复直连' }
        } else {
            Write-Fail '没有可退回的版本，请运行 rescue.cmd 恢复直连'
        }
        return
    }
    Write-Ok "内核已就绪：$ver"
    Save-Snapshot $AppliedDir
    if (Test-Egress) { Write-Ok '默认出口连通' }
    else { Write-Warn2 '默认出口不通。若是新配置导致的，运行 rollback.cmd 退回“已知可用”版本' }
    $u = Get-Trace $ProbeAI
    if ($u.Loc -eq 'US') { Write-Ok 'AI 出口为美国' }
    else { Write-Warn2 ("AI 出口检查：ip={0} loc={1}" -f $u.Ip, $u.Loc) }
    Write-Info '新配置稳定用几天后，运行 mark-good.cmd 把它保存为“已知可用”版本'
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
