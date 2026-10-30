# 查看状态：服务、内存、当前选择、节点延迟、三条出口实测、最近日志。不需要管理员权限。
param([int]$LogLines = 20, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'status'

try {
    Write-Title '版本'
    Write-Info ("套件 {0}　（update.cmd 检查升级，doctor.cmd 一键诊断）" -f (Get-KitVersion))

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

    Write-Title "最近日志（$LogLines 行）"
    Show-RecentLog $LogLines
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
