# 重启 mihomo 服务（不改配置）。适合网络异常时“重开一下”。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'restart'

try {
    if (-not (Get-MihomoService)) { throw '服务未注册，请先运行 install-service.cmd' }
    Write-Title '重启'
    Stop-MihomoService
    Start-MihomoService
    $ver = Wait-Api 30
    if ($ver) {
        Write-Ok "内核已就绪：$ver"
        if (Test-Egress) { Write-Ok '默认出口连通' } else { Write-Warn2 '默认出口暂时不通，可在面板里换一个节点' }
    } else {
        Write-Fail '内核 30 秒内没有就绪，最近日志：'
        Show-RecentLog 30
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
