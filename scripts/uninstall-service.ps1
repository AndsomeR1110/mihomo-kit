# 停止并注销 mihomo 服务（文件保留）。彻底不用时再删除整个 D:\mihomo 目录。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'uninstall-service'

try {
    Write-Title '注销服务'
    if (-not (Get-MihomoService)) { Write-Ok '服务本来就没有注册'; return }
    Stop-MihomoService
    $r = Invoke-Native $WinSWExe @('uninstall')
    $r.Output | ForEach-Object { Write-Info $_ }
    Start-Sleep -Seconds 2
    if (Get-MihomoService) { Write-Warn2 '服务仍显示存在，重启电脑后会消失' }
    else { Write-Ok '服务已注销，现在是直连状态' }
    Write-Info '如需恢复 IPv6：system-tweaks.cmd -Revert'
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
