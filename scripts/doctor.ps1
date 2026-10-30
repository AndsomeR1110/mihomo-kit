# 一键诊断：把版本/服务/端口/分组/节点/出口/系统代理/最近错误汇总成一份文本报告。
# 不需要管理员权限，纯只读。报告同时存到套件根目录 doctor-report-<时间>.txt——
# 出问题时把这个文件发给分享者（或贴给你的 AI 助手）即可远程排障。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $Root "doctor-report-$stamp.txt"
$lines  = New-Object System.Collections.Generic.List[string]

function Doc([string]$Text) {
    Write-Host $Text
    $lines.Add($Text)
}
function DocTitle([string]$Text) {
    Write-Host '' -ForegroundColor Cyan
    Write-Host "== $Text" -ForegroundColor Cyan
    $lines.Add('')
    $lines.Add("== $Text")
}
function DocOk([string]$Text)   { Doc ("  [OK]   $Text") }
function DocWarn([string]$Text) { Doc ("  [注意] $Text") }
function DocFail([string]$Text) { Doc ("  [失败] $Text") }

$notes = @()   # 结尾的结论提示

try {
    DocTitle "mihomo-kit 诊断报告"
    Doc ("生成时间：{0}　主机：{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
    Doc ("套件目录：$Root")
    Doc ("套件版本：$(Get-KitVersion)")
    if (Test-SubscriptionMode) {
        $u = Get-SubscriptionUrl
        # 报告里不泄露 token：只显示到路径前缀
        $uMasked = $u -replace '(/u/[^/]{6}).*', '$1…'
        Doc ("节点来源：在线订阅（$uMasked）")
    } else {
        Doc '节点来源：本地文件 config\private\nodes.yaml'
    }

    DocTitle '服务'
    $svc = Get-MihomoService
    if (-not $svc) {
        DocFail '服务未注册（还没跑过 install.cmd？）'
        $notes += '服务未注册：先双击 install.cmd 完成安装'
    } else {
        $mem = Get-MihomoMemoryMB; $memText = '-'; if ($mem) { $memText = "$mem MB" }
        Doc ("状态：{0}　启动类型：{1}　内核内存：{2}" -f $svc.Status, $svc.StartType, $memText)
        if ($svc.Status -ne 'Running') { $notes += '服务未在运行：双击 start.cmd 启动；若网页全挂先看下面「系统代理」一节' }
    }

    DocTitle '端口监听'
    foreach ($p in @((Get-MixedPort), 9097)) {
        $listen = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($listen) { DocOk "端口 $p 在监听" } else { DocWarn "端口 $p 没有监听（服务没跑或端口被改）" }
    }
    if (Test-VergeRunning) {
        DocFail '检测到 Clash Verge 在运行，会和本套件抢端口/抢 TUN！'
        $notes += 'Clash Verge 与本套件冲突：先在 Verge 里关系统代理并从托盘彻底退出'
    } else { DocOk '没有检测到其他代理客户端' }

    DocTitle '内核与分组'
    $apiOk = $false
    try {
        $v = Invoke-Api '/version'
        if ($v.version) { DocOk "API 正常，内核 $($v.version)"; $apiOk = $true }
    } catch { DocFail '内核 API 无响应（面板也会连不上；注意本套件面板端口是 9097，不是 9090）' }
    if ($apiOk) {
        foreach ($g in @('默认出口', '香港组', '美国组')) {
            try {
                $obj = Invoke-Api ('/proxies/' + [uri]::EscapeDataString($g))
                $line = ("{0}（{1}）当前 → {2}" -f $g, $obj.type, $obj.now)
                if ($obj.type -match 'URLTest|LoadBalance') {
                    DocWarn "$line　※ 自动切换组：出口 IP 会变，IP 敏感网站（Cloudflare 人机验证循环）建议在面板里钉住固定节点"
                    $notes += "「$g」是自动测速组，出口 IP 会漂移；访问 AI/登录类网站卡验证时，在面板把该组钉到固定节点"
                } else { Doc $line }
            } catch { DocWarn "读不到分组「$g」" }
        }
        try {
            $p = Invoke-Api '/providers/proxies/nodes'
            $alive = 0
            foreach ($n in $p.proxies) {
                $last = $n.history | Select-Object -Last 1
                $delay = 0; if ($last) { $delay = $last.delay }
                if ($delay -gt 0) { $alive++ }
                Doc ("  节点 {0,-22} {1,5} ms" -f $n.name, $delay)
            }
            Doc ("  可用节点：{0}/{1}" -f $alive, @($p.proxies).Count)
            if ($alive -eq 0) { $notes += '所有节点延迟为 0（全部不通）：订阅/节点问题，把本报告发给分享者' }
        } catch { DocWarn '读取节点列表失败' }
    }

    DocTitle '出口实测（经系统路由，与真实应用一致）'
    $d = Invoke-Probe $ProbeDirect
    if ($d.Code -eq '200') { DocOk ("国内直连：{0}" -f ($d.Body -replace '\s+', ' ')) }
    else { DocFail "国内直连失败（HTTP $($d.Code)）——本机连国内网都不通，先查网络/网卡，不是代理的问题" }
    $h = Get-Trace $ProbeDefault
    if ($h.Ip) { Doc ("默认出口：ip={0} loc={1}" -f $h.Ip, $h.Loc) }
    else { DocFail '默认出口不通（境外整体不可用）' }
    $u = Get-Trace $ProbeAI
    if ($u.Loc -eq 'US') { DocOk ("AI 出口（claude.ai）：ip={0} loc=US" -f $u.Ip) }
    elseif ($u.Ip) { DocFail ("AI 出口（claude.ai）：ip={0} loc={1}，不是美国（按设计不回落）" -f $u.Ip, $u.Loc) }
    else { DocWarn "AI 出口（claude.ai）不通（HTTP $($u.Code)）：美国节点可能不可用" }

    DocTitle 'TLS 连通对照（国内大站）'
    # 经验：校园网出口的上网行为管理偶发把 443 握手掐断（baidu 正常而 qq/zhihu 瞬断）。
    # 这里各测一次，失败集合若与网络路径无关，说明是网络侧问题，不是套件问题。
    foreach ($site in @('https://www.baidu.com', 'https://www.qq.com', 'https://www.taobao.com')) {
        $r = Invoke-Probe -Url $site
        if ($r.Code -match '^[23]') { DocOk "$site HTTP $($r.Code)" }
        elseif ($r.Code -eq '000') {
            # 000 = 连 HTTP 响应都没拿到：TLS 握手被掐或网络不通，正是"间歇性 TLS 重置"的现场特征
            DocWarn "$site 连接失败（TLS 握手被掐或网络不通）"
            $tlsBad = $true
        }
        else { Doc "$site HTTP $($r.Code)（连接与 TLS 正常，服务器返回此状态码）" }
    }
    if ($tlsBad) { $notes += '国内大站 HTTPS 有失败：把本报告发给分享者；可再用手机连同一 Wi-Fi 对比（区分本机/网络问题）' }

    DocTitle '系统代理与 TUN'
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pe  = (Get-ItemProperty -Path $key -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $ps  = (Get-ItemProperty -Path $key -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    if ($pe -eq 1) {
        DocWarn "系统代理开着：$ps —— 套件是 TUN 模式，不需要系统代理；服务停止时它会指向死端口导致浏览器全挂"
        $notes += '系统代理开着但套件用 TUN：双击 rescue.cmd 关掉它（防「服务一停浏览器全挂」）'
    } else { DocOk '系统代理关闭（正常，套件走 TUN）' }
    $tun = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue
    if ($tun) { DocOk ("TUN 网卡存在（{0}）" -f $tun.Status) }
    else { DocWarn 'TUN 网卡 Mihomo 不存在（服务没跑，或 TUN 创建失败——看内核日志）' }

    DocTitle '最近内核日志（error/warn/fatal）'
    $f = Get-LatestCoreLog
    if ($f) {
        $bad = Get-Content -Path $f.FullName -Tail 300 -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '\b(error|warn|fatal|warning)\b' } | Select-Object -Last 12
        if ($bad) { $bad | ForEach-Object { Doc ("  $_") } }
        else { DocOk "（最近 300 行没有 error/warn）" }
    } else { DocWarn '没有内核日志文件' }

    if ($notes.Count -gt 0) {
        DocTitle '结论提示'
        $notes | ForEach-Object { DocWarn $_ }
    } else {
        DocTitle '结论'
        DocOk '各项检查未见异常'
    }

    [IO.File]::WriteAllText($report, ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
    Write-Host ''
    Write-Ok "报告已保存：$report"
    Write-Info '出问题时把这份报告发给分享者（或贴给你的 AI 助手）即可远程排障'
}
catch {
    Write-Fail $_.Exception.Message
    try { [IO.File]::WriteAllText($report, ($lines -join "`r`n") + "`r`n`r`n[诊断中断] $($_.Exception.Message)", (New-Object Text.UTF8Encoding($true))) } catch { }
}
finally {
    Stop-RunLog
    if (-not $NoPause) { Write-Host ''; Read-Host '按回车键关闭窗口' | Out-Null }
}
