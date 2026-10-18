# 恢复联网（面板打不开、网络全断时用）
# 停止 mihomo 并取消开机自启、关闭残留的系统代理、刷新 DNS，然后测试直连。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'rescue'

try {
    Write-Title '1/4 停止 mihomo'
    if (Get-MihomoService) {
        Stop-MihomoService
        Set-Service -Name $ServiceName -StartupType Manual
        Write-Ok '已停止，并改为手动启动（重启电脑也不会自动开启；start.cmd 会恢复自启）'
    } else {
        Write-Ok '服务未注册，跳过'
    }

    Write-Title '2/4 关闭残留系统代理'
    if (Disable-SystemProxy) { Write-Ok '已关闭指向本机的系统代理' } else { Write-Ok '系统代理本来就是关闭的' }

    Write-Title '3/4 刷新 DNS 缓存'
    Invoke-Native 'ipconfig.exe' @('/flushdns') | Out-Null
    Write-Ok '完成'

    Write-Title '4/4 测试直连'
    $r = Invoke-Probe 'https://www.baidu.com' -TimeoutSec 8
    if ($r.Code -eq '200') { Write-Ok '直连正常（百度可访问）' }
    else {
        Write-Warn2 "直连仍不通（HTTP $($r.Code)）。可能需要重新登录校园网，或检查 Wi-Fi 本身"
        Write-Info '如果之前执行过 system-tweaks -Apply，也可以运行 system-tweaks.cmd -Revert 排除 IPv6 设置的影响'
    }
    Write-Host ''
    Write-Info '下一步：排查后用 start.cmd 恢复代理；或打开 Clash Verge 并开启系统代理临时替代'
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
