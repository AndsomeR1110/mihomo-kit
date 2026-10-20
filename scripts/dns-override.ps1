# DNS 覆写开关：在 config\dns\off.yaml（基线）与 on.yaml（全量防泄露）之间切换。
#
#   off = 全部域名用国内公共 DNS 解析（最快，但所有域名查询都会泄露给本地网络）
#   on  = 所有域名（含国内、校园网、自有服务器）一律用非大陆 DoH 解析，
#         且查询本身经「美国组」的代理隧道发出；同时把 tun.strict-route 设为 true
#
# 一次切换会同时改动两处，两处必须一起生效：
#   · 标记之间的 dns: 段          （config\dns\on.yaml 或 off.yaml）
#   · 顶层 tun.strict-route       （on → true，off → false）
# 流程：内存里一起改 → 一次性写回 → mihomo -t 校验 → 重启内核 → 核对运行时状态。
# 任一步失败都恢复切换前的完整配置（DNS 段与路由开关一起恢复），避免半成品状态。
#
# 需要管理员权限（重启服务），会自动请求提权。
param(
    [ValidateSet('on', 'off', 'toggle', 'get')]
    [string]$State = '',
    [switch]$NoRestart,
    [switch]$NoPause
)
. "$PSScriptRoot\common.ps1"

# 托盘调用时不传 -State，而是设好环境变量，避免命令行里拼接参数
if (-not $State -and $env:MIHOMO_DNS_OVERRIDE) { $State = $env:MIHOMO_DNS_OVERRIDE }
if ($State -notin @('on', 'off', 'toggle', 'get')) {
    Write-Host '用法：dns-override.ps1 -State on|off|toggle|get' -ForegroundColor Red
    exit 1
}

$isGet = ($State -eq 'get')
if ($isGet) { Write-Output (Get-DnsOverride); exit 0 }

# 只有真的要动服务时才提权；-NoRestart 只改文件，不需要管理员
if (-not $NoRestart) { Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters }
Start-RunLog "dns-override-$State"

$names = @{ on = '开启（全量防泄露）'; off = '关闭（基线）' }

# 配置内容与两份方案都对不上时，toggle 只能靠旧特征猜一个起点
function Get-DnsOverrideLoose {
    $cur = Get-DnsOverride
    if ($cur -ne 'unknown') { return $cur }
    $disk = Get-StrictRouteDisk
    if ($disk -eq 'true') { return 'on' }
    $block = Get-DnsBlockInConfig
    if ($block -and $block -match '(?m)^\s*respect-rules:\s*true') { return 'on' }
    return 'off'
}

# 切换后的核对：磁盘、运行时、DNS 实际路径都要看，缺一不算通过
function Show-DnsVerification([string]$Target) {
    $st = Get-DnsOverrideStatus
    $ok = $true

    if ($st.Scheme -ne $Target) {
        Write-Fail ("配置内容不是「{0}」方案（当前判定：{1}）" -f $names[$Target], $st.Scheme)
        $ok = $false
    } else {
        Write-Ok ("配置内容 = {0} 方案" -f $names[$Target])
    }

    $want = ($Target -eq 'on')
    if ($null -eq $st.DiskStrictRoute) {
        Write-Fail 'tun.strict-route 在 config.yaml 里找不到'
        $ok = $false
    } elseif ($st.DiskMatches) {
        Write-Ok ("磁盘 tun.strict-route = {0}" -f $st.DiskStrictRoute)
    } else {
        Write-Fail ("磁盘 tun.strict-route = {0}，应为 {1}" -f $st.DiskStrictRoute, $want)
        $ok = $false
    }

    if ($st.ApiMismatch.Count -gt 0) {
        foreach ($m in $st.ApiMismatch) { Write-Fail $m }
        Write-Warn2 '请先退出其他代理软件（Clash Verge / Clash Party 等）再重跑本命令；'
        Write-Warn2 '否则下面读到的运行时状态属于别的内核，不能用来判断本套件是否生效'
        return $false
    }

    if ($null -eq $st.RuntimeTunEnable) {
        Write-Warn2 '读不到内核运行时状态（内核未运行？）——配置已保存，但尚未生效'
        return $false
    }
    if ($st.RuntimeTunEnable) { Write-Ok '运行时 TUN = 开启' }
    else { Write-Fail '运行时 TUN = 关闭，DNS 覆写无法覆盖全机'; $ok = $false }

    if ($st.RuntimeStrictRoute -eq $want) {
        Write-Ok ("运行时 tun.strict-route = {0}" -f $st.RuntimeStrictRoute)
    } else {
        Write-Fail ("运行时 tun.strict-route = {0}，应为 {1}" -f $st.RuntimeStrictRoute, $want)
        $ok = $false
    }

    if ($Target -eq 'on') {
        # 解析一个国内域名和一个随机未知域名：都要能出结果，且不能出现大陆解析器
        $probe = @('www.baidu.com', 'probe-' + (Get-Random) + '-unknown.example')
        foreach ($d in $probe) {
            try {
                $r = Invoke-Api ('/dns/query?name=' + [uri]::EscapeDataString($d) + '&type=A') -TimeoutSec 12
                $ans = @($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
                if ($ans.Count -gt 0) { Write-Ok ("解析 {0} → {1}" -f $d, ($ans -join ', ')) }
                else { Write-Warn2 ("解析 {0}：没有 A 记录（可能是节点不可用）" -f $d) }
            } catch {
                Write-Warn2 ("解析 {0} 失败：{1}" -f $d, $_.Exception.Message)
            }
        }

        # 看 DNS 上游到底走了哪条路：内核内部连接里 1.1.1.1 / 8.8.8.8:443 的 chains
        try {
            $conns = (Invoke-Api '/connections' -TimeoutSec 5).connections
            $doh = @($conns | Where-Object {
                $_.metadata.destinationIP -in @('1.1.1.1', '8.8.8.8') -and $_.metadata.destinationPort -eq '443'
            })
            if ($doh.Count -eq 0) {
                Write-Warn2 '连接表里还没看到 DoH 上游（解析结果已走缓存？）——用面板或抓包再确认一次'
            } else {
                foreach ($c in ($doh | Select-Object -First 3)) {
                    Write-Ok ("DNS 上游 {0} → 出口 {1}（规则：{2}）" -f $c.metadata.destinationIP, ($c.chains -join ' > '), $c.rule)
                }
                $direct = @($doh | Where-Object { $_.chains -contains 'DIRECT' })
                if ($direct.Count -gt 0) { Write-Fail '有 DoH 上游是直连发出的，DNS 会泄露'; $ok = $false }
            }
        } catch { Write-Warn2 '读连接表失败，无法核对 DNS 上游路径' }
    }

    return $ok
}

try {
    $current = Get-DnsOverrideLoose
    $target = $State
    if ($State -eq 'toggle') { if ($current -eq 'on') { $target = 'off' } else { $target = 'on' } }

    $curLabel = $names[$current]
    if ((Get-DnsOverride) -eq 'unknown') { $curLabel = '当前内容与两份方案都对不上（按 strict-route 推断为 ' + $names[$current] + '）' }
    Write-Title ("DNS 覆写：{0} → {1}" -f $curLabel, $names[$target])

    # 先看现状：即使「已经开着」，也要核对内容与运行时是否符合新方案，不能直接跳过
    $st = Get-DnsOverrideStatus
    $alreadyGood = ($st.Scheme -eq $target) -and ($st.Applied)
    if ($alreadyGood) {
        Write-Ok ("已经是「{0}」且已生效，无需改动" -f $names[$target])
        Show-DnsVerification $target | Out-Null
        return
    }
    if ($st.Scheme -eq $target) {
        Write-Warn2 '配置内容已是目标方案，但运行时状态不符（改过文件或内核没重启）——重新写入并应用'
    }

    # 1. 完整配置存档：失败时按原文恢复，DNS 段与路由开关一起回退
    $backup = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8)
    $restore = {
        param($text)
        [IO.File]::WriteAllText($ConfigFile, $text, (New-Object Text.UTF8Encoding($false)))
    }

    # 2. 内存里一起改：dns 段 + tun.strict-route，然后一次性写回
    Set-DnsOverride $target
    Write-Ok ("已写入 config\dns\{0}.yaml 的 dns 段，并把 tun.strict-route 设为 {1}" -f $target, ($target -eq 'on'))
    $after = Get-DnsOverrideStatus
    if (-not $after.DiskMatches) {
        & $restore $backup
        throw ("写回后核对失败：磁盘 tun.strict-route = {0}，应为 {1}（已恢复原配置）" -f $after.DiskStrictRoute, $after.WantStrictRoute)
    }

    # 3. 语法校验
    $t = Test-MihomoConfig
    if (-not $t.Ok) {
        Write-Fail '新方案没通过校验，正在恢复原配置……'
        $t.Lines | Select-Object -Last 6 | ForEach-Object { Write-Info $_ }
        & $restore $backup
        throw 'DNS 方案未应用（已恢复原配置）'
    }
    Write-Ok '配置校验通过'

    if ($NoRestart) {
        Write-Warn2 '按 -NoRestart 要求只写了配置，没有重启内核'
        if ($target -eq 'on') {
            Write-Warn2 '保护尚未生效：DNS 覆写与严格路由都要重启内核（restart.cmd）后才真正起作用'
        } else {
            Write-Warn2 '配置已保存：重启内核（restart.cmd）后才会回到基线'
        }
        return
    }

    if (-not (Get-MihomoService)) { throw '服务未注册，配置已保存但无法应用；请先运行 install-service.cmd' }

    # 4. 重启内核（dns 段与 tun.strict-route 都只在启动时装载）
    Write-Title '重启内核使其生效'
    Stop-MihomoService
    Start-MihomoService
    $ver = Wait-Api 30
    if (-not $ver) {
        Write-Fail '新方案下内核 30 秒内没就绪，正在恢复原配置……'
        Show-RecentLog 15
        & $restore $backup
        Stop-MihomoService
        Start-MihomoService
        if (Wait-Api 30) { Write-Ok ("已恢复「{0}」并重新运行" -f $names[$current]) }
        else { Write-Fail '恢复后仍未就绪，请运行 rescue.cmd 恢复直连' }
        return
    }
    Write-Ok "内核已就绪：$ver"

    # 5. 核对实际运行状态
    Write-Title '核对实际运行状态'
    if (Test-Egress) { Write-Ok '默认出口连通' } else { Write-Warn2 '默认出口暂时不通，可在面板换节点' }
    $passed = Show-DnsVerification $target

    if ($target -eq 'on') {
        Write-Host ''
        if ($passed) { Write-Ok 'DNS 覆写与严格路由都已按新方案生效' }
        else { Write-Warn2 '有项目未通过，见上面的失败项；可在面板换节点后重跑本命令核对' }

        # 内核管不到的地方：网卡上直接配的大陆 DNS、系统登记的加密 DNS、应用自带 DoH
        $surface = Get-DnsLeakSurface
        if ($surface.Count -gt 0) {
            Write-Title '内核管不到的 DNS 出口（需要手动处理）'
            foreach ($s in $surface) { Write-Warn2 $s }
            Write-Info '内核只能约束「发到 53 端口的明文 DNS」与系统解析器；'
            Write-Info '加密 DNS(DoH/DoT) 走 443，dns-hijack 和 strict-route 都拦不住，只能在应用侧关掉。'
        }
        Write-Info '换网络（学校↔宿舍↔热点）后策略自动跟随；改过 on.yaml 后重跑本命令即可重新核对。'
    } else {
        Write-Info '已回到基线：全部域名用国内公共 DNS，且 tun.strict-route 恢复为 false'
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
