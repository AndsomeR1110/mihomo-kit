# 停止 mihomo 服务，恢复直连。下次开机仍会自动启动（如不想自启，用 rescue.cmd）。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'stop'

try {
    Write-Title '停止'
    Stop-MihomoService
    Write-Ok '已停止，现在是直连状态。'
    Write-Info '重新开启：start.cmd；临时改用 Clash Verge：直接打开 Clash Verge 并开启系统代理'
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
