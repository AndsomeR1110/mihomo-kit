# 启动 mihomo 服务（并恢复为开机自启）
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'start'

try {
    if (-not (Get-MihomoService)) { throw '服务未注册，请先运行 install-service.cmd' }
    if (Test-VergeRunning) { throw 'Clash Verge 正在运行，两者端口相同不能同时开。请先退出 Clash Verge' }
    Write-Title '启动'
    Start-MihomoService
    $ver = Wait-Api 30
    if ($ver) {
        Write-Ok "内核已就绪：$ver（开机自启已恢复）"
        if (Test-Egress) { Write-Ok '默认出口连通' } else { Write-Warn2 '默认出口暂时不通，可在面板里换一个节点' }
    } else {
        Write-Fail '内核 30 秒内没有就绪，最近日志：'
        Show-RecentLog 30
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
