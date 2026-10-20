# 查看状态：服务、内存、当前选择、节点延迟、三条出口实测、最近日志。不需要管理员权限。
param([int]$LogLines = 20, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'status'

try {
    Write-Title '服务'
    $svc = Get-MihomoService
    if (-not $svc) {
        Write-Warn2 '服务未注册'
    } else {
        $mem = Get-MihomoMemoryMB
        $memText = '-'
        if ($mem) { $memText = "$mem MB" }
        Write-Info ("状态：{0}　启动类型：{1}　内核内存：{2}" -f $svc.Status, $svc.StartType, $memText)
    }

    # 残留内核会让「服务 Running」变成假象：端口被孤儿占着，服务的内核根本 bind 不上。
    # 这一步放在最前面，因为后面所有 API 查询都可能是在问那个孤儿。
    Write-Title '残留内核检查'
    $occ = Get-PortOccupancy
    if ($occ.Strays.Count -eq 0 -and $occ.Conflicts.Count -eq 0) {
        Write-Ok ("端口 {0} 干净" -f ((Get-ConfigPorts) -join ', '))
    } else {
        foreach ($s in $occ.Strays) {
            Write-Fail ("残留内核 pid {0}（{1}）占着端口 {2}——服务的内核起不来就是这个原因" -f $s.Pid, $s.Name, $s.Port)
        }
        foreach ($c in $occ.Conflicts) {
            Write-Warn2 ("端口 {0} 被「{1}」(pid {2}) 占用：别的代理软件，请自行退出" -f $c.Port, $c.Name, $c.Pid)
        }
        if ($occ.Strays.Count -gt 0) {
            Write-Info '      处理：运行 clean-stray.cmd（需要管理员），它会结束残留内核并重启服务'
        }
    }

    Write-Title '内核'
    $ver = $null
    try { $ver = (Invoke-Api '/version').version } catch { }
    if ($ver) {
        Write-Ok "运行中 $ver　面板：$(Get-ApiBase)/ui"
        Write-Title '当前选择'
        $def = Get-GroupNow '默认出口'
        $defNode = ''
        if ($def -eq '香港组' -or $def -eq '美国组') { $defNode = ' → ' + (Get-GroupNow $def) }
        Write-Info "默认出口 → $def$defNode"
        Write-Info ("美国组（AI 专用） → {0}" -f (Get-GroupNow '美国组'))

        Write-Title '节点延迟（最近一次自动检测，0 表示不通）'
        try {
            $p = Invoke-Api '/providers/proxies/nodes'
            foreach ($n in $p.proxies) {
                $last = $n.history | Select-Object -Last 1
                $delay = 0
                if ($last) { $delay = $last.delay }
                $line = "{0,-12} {1,5} ms" -f $n.name, $delay
                if ($delay -gt 0) { Write-Ok $line } else { Write-Warn2 $line }
            }
        } catch { Write-Warn2 '读取节点状态失败' }
    } else {
        Write-Warn2 '内核未运行或 API 无响应（现在可能是直连状态）'
    }

    Write-Title '出口实测（经系统路由，与真实应用一致）'
    $d = Invoke-Probe $ProbeDirect
    if ($d.Code -eq '200') { Write-Info ("国内直连：{0}" -f ($d.Body -replace '\s+', ' ')) }
    else { Write-Warn2 "国内直连：失败（HTTP $($d.Code)）" }
    $h = Get-Trace $ProbeDefault
    if ($h.Ip) { Write-Info ("默认出口：ip={0} loc={1}" -f $h.Ip, $h.Loc) }
    else { Write-Warn2 "默认出口：失败（HTTP $($h.Code)）" }
    $u = Get-Trace $ProbeAI
    if ($u.Loc -eq 'US') { Write-Ok ("AI 出口（claude.ai）：ip={0} loc=US" -f $u.Ip) }
    elseif ($u.Ip) { Write-Fail ("AI 出口（claude.ai）：ip={0} loc={1}，不是美国！" -f $u.Ip, $u.Loc) }
    else { Write-Warn2 "AI 出口（claude.ai）：不通（HTTP $($u.Code)）。美国两个节点可能都不可用——按设计不会回落到香港" }
    Write-Info '以上只反映业务流量的出口地区，不能说明 DNS 有没有泄露。'

    Write-Title 'DNS 覆写 / 严格路由'
    $dns = Get-DnsOverrideStatus
    $names = @{ on = '开启（全量防泄露）'; off = '关闭（基线）'; unknown = '配置与方案文件不一致' }
    Write-Info ("配置内容：{0}" -f $names[$dns.Scheme])
    if ($dns.Scheme -eq 'unknown') {
        Write-Warn2 '内容与 config\dns 下的两份方案都对不上（改过方案文件，或从旧版本升级上来）'
        Write-Info '      运行 dns-override.cmd -State on|off 会把 dns 段与 tun.strict-route 重新写成一套'
    }
    if ($null -eq $dns.DiskStrictRoute) { Write-Warn2 'config.yaml 的 tun: 段里没有 strict-route 这一行' }
    else { Write-Info ("磁盘 tun.strict-route：{0}" -f $dns.DiskStrictRoute) }
    if ($dns.ApiMismatch.Count -gt 0) {
        foreach ($m in $dns.ApiMismatch) { Write-Fail $m }
        Write-Warn2 '请先退出其他代理软件（Clash Verge / Clash Party 等）再重跑 status'
    } elseif ($null -eq $dns.RuntimeTunEnable) {
        Write-Warn2 '内核未运行，无法核对运行时状态'
    } else {
        Write-Info ("运行时 TUN：{0}　tun.strict-route：{1}" -f $dns.RuntimeTunEnable, $dns.RuntimeStrictRoute)
        if ($dns.Applied) { Write-Ok 'DNS 覆写与严格路由已在运行时生效' }
        else { Write-Warn2 '配置尚未生效（改过文件或未重启内核）。运行 dns-override.cmd -State on 重新应用' }
    }

    Write-Title '内核管不到的 DNS 出口'
    $surface = Get-DnsLeakSurface
    if ($surface.Count -eq 0) {
        Write-Ok '没有发现网卡上的大陆 DNS，也没有正在使用的系统加密 DNS'
    } else {
        foreach ($s in $surface) { Write-Warn2 $s }
        Write-Info '这些不是内核配置能修的：网卡 DNS 要在「网络适配器属性」里改，加密 DNS 要在浏览器/应用里关。'
    }

    Write-Title "最近日志（$LogLines 行）"
    Show-RecentLog $LogLines
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
