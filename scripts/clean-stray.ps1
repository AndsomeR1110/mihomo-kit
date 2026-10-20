# 清理残留内核：结束占用本套件端口、但不是当前服务子进程的 mihomo 进程。
#
# 为什么会有残留：
#   mihomo 重启时会先拉起新进程再退出旧的。如果此刻 WinSW 也判定子进程退出并重启服务，
#   就会留下一个由 SYSTEM 启动、父进程已死的孤儿内核。它继续占着 mixed-port(7897) /
#   external-controller(9097) 和 TUN 适配器，于是服务随后启动的内核 bind 失败、
#   建不出适配器 —— 表现为「服务显示 Running，但面板连不上、代理完全不通」。
#   按可执行文件路径匹配清理不掉它（SYSTEM 进程的 Path 读不到），只能按端口占用找。
#
# 本脚本只结束进程名像 mihomo 的进程。若端口被别的代理软件（Clash Party / Verge 等）占用，
# 只报告，不会替你结束别的程序。
param([switch]$NoRestart, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"

# 结束 SYSTEM 进程需要管理员
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'clean-stray'

try {
    $ports = Get-ConfigPorts
    Write-Title ("本套件使用的端口：{0}" -f ($ports -join ', '))

    $occ = Get-PortOccupancy
    if ($occ.Strays.Count -eq 0 -and $occ.Conflicts.Count -eq 0) {
        Write-Ok '没有发现残留内核，端口都是干净的'
    }

    foreach ($s in $occ.Strays) {
        Write-Info ("残留内核：pid {0}（{1}），占用端口 {2}" -f $s.Pid, $s.Name, $s.Port)
        try {
            Stop-Process -Id $s.Pid -Force -ErrorAction Stop
            Write-Ok ("已结束 pid {0}" -f $s.Pid)
        } catch {
            Write-Fail ("结束 pid {0} 失败：{1}" -f $s.Pid, $_.Exception.Message)
        }
    }

    foreach ($c in $occ.Conflicts) {
        Write-Warn2 ("端口 {0} 被「{1}」(pid {2}) 占用。这是别的代理软件，请自行退出（本脚本不动它）" -f $c.Port, $c.Name, $c.Pid)
    }

    Start-Sleep -Seconds 1
    $left = (Get-PortOccupancy).Strays
    if ($left.Count -gt 0) {
        Write-Fail ("仍有 {0} 个残留内核没清掉，端口依旧被占" -f $left.Count)
        return
    }
    Write-Ok '端口已释放'

    if ($NoRestart) {
        Write-Warn2 '按 -NoRestart 要求，没有重启服务；内核当前仍是停止状态'
        return
    }

    if (-not (Get-MihomoService)) {
        Write-Warn2 '服务未注册，跳过重启。运行 install-service.cmd 注册后再启动'
        return
    }

    Write-Title '重启内核并核对'
    Stop-MihomoService
    Start-MihomoService
    $ver = Wait-Api 30
    if (-not $ver) {
        Write-Fail '内核 30 秒内没就绪，最近日志：'
        Show-RecentLog 20
        return
    }
    Write-Ok "内核已就绪：$ver"

    $tun = Get-TunEnableRuntime
    if ($tun -eq $true) { Write-Ok '运行时 TUN = 开启' }
    elseif ($tun -eq $false) { Write-Warn2 '运行时 TUN = 关闭（tun.enable 为 false，或内核没装载这份配置）' }
    else { Write-Warn2 '读不到运行时 TUN 状态' }

    $bad = Get-ApiInstanceMismatch
    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Write-Fail $b }
    } else {
        Write-Ok '回答 API 的就是本套件的内核'
    }

    if (Test-Egress) { Write-Ok '默认出口连通' } else { Write-Warn2 '默认出口暂时不通，可在面板换节点' }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
