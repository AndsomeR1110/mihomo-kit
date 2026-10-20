# 启动 mihomo 服务（并恢复为开机自启）
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'start'

try {
    if (-not (Get-MihomoService)) { throw '服务未注册，请先运行 install-service.cmd' }
    if (Test-VergeRunning) { throw 'Clash Verge 正在运行，两者端口相同不能同时开。请先退出 Clash Verge' }

    # 残留内核会占着端口，服务起来的内核 bind 不上，表现为「服务 Running 但完全不通」。
    # 启动前先清一次，避免这种假象。
    $occ = Get-PortOccupancy
    if ($occ.Strays.Count -gt 0 -or $occ.Conflicts.Count -gt 0) {
        Write-Title '启动前检查端口'
        foreach ($s in $occ.Strays) { Write-Warn2 ("残留内核 pid {0}（{1}）占着端口 {2}，正在清理" -f $s.Pid, $s.Name, $s.Port) }
        foreach ($c in $occ.Conflicts) { Write-Warn2 ("端口 {0} 被「{1}」(pid {2}) 占用——请先退出该程序，否则内核起不来" -f $c.Port, $c.Name, $c.Pid) }
        foreach ($s in $occ.Strays) { Stop-Process -Id $s.Pid -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        $left = Get-PortOccupancy
        if ($left.Conflicts.Count -gt 0) { throw ("端口 {0} 仍被其他代理软件占用，请先退出它" -f (($left.Conflicts | ForEach-Object { $_.Port }) -join ', ')) }
        if ($left.Strays.Count -gt 0) { throw '残留内核清不掉（由 SYSTEM 启动），请用管理员权限运行 clean-stray.cmd' }
        Write-Ok '端口已腾空'
    }

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
