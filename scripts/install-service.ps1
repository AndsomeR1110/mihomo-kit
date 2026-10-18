# 阶段 2：切换。注册并启动 mihomo 服务（TUN 接管全部流量）。
# 前提：已运行 prepare、填好 private 文件、test-config 通过、Clash Verge 已完全退出。
param([switch]$Force, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'install-service'

try {
    Write-Title '1/5 前置检查'
    foreach ($f in @($MihomoExe, $WinSWExe, (Join-Path $BinDir 'mihomo-service.xml'))) {
        if (-not (Test-Path $f)) { throw "缺少 $f，请先运行 prepare.cmd" }
    }
    Write-Ok '程序文件齐全'

    if (Test-VergeRunning) {
        if ($Force) { Write-Warn2 'Clash Verge 仍在运行（-Force 忽略）' }
        else { throw 'Clash Verge 仍在运行：请先在 Clash Verge 里关闭系统代理，再从托盘图标彻底退出，然后重试' }
    } else { Write-Ok 'Clash Verge 未运行' }

    $t = Test-MihomoConfig
    if (-not $t.Ok) {
        $t.Lines | Select-Object -Last 8 | ForEach-Object { Write-Info $_ }
        throw '配置检查未通过'
    }
    Write-Ok '配置检查通过'

    Write-Title '2/5 关闭系统代理'
    if (Disable-SystemProxy) { Write-Ok '已关闭 Windows 系统代理（改由 TUN 接管）' }
    else { Write-Ok '系统代理本来就是关闭的' }

    Write-Title '3/5 注册服务'
    $svc = Get-MihomoService
    if ($svc) {
        Write-Ok '服务已存在，跳过注册'
    } else {
        $r = Invoke-Native $WinSWExe @('install')
        $r.Output | ForEach-Object { Write-Info $_ }
        if (-not (Get-MihomoService)) {
            throw ('服务注册失败。如果 360 等安全软件弹窗拦截，请选择“允许”，并把本目录（' + $Root + '）加入信任区后重试')
        }
        Write-Ok '服务 mihomo 已注册（开机自启，崩溃自动拉起）'
    }

    Write-Title '4/5 启动服务'
    Start-MihomoService
    $ver = Wait-Api 30
    if (-not $ver) {
        Write-Fail '内核 30 秒内没有就绪，最近日志：'
        Show-RecentLog 30
        throw '启动失败。可运行 rescue.cmd 恢复直连'
    }
    Write-Ok "内核已就绪：$ver"
    Save-Snapshot $AppliedDir
    Write-Ok '当前配置已保存为“最近一次成功应用”'

    Write-Title '5/5 出口实测（经 TUN）'
    Start-Sleep -Seconds 3
    $d = Invoke-Probe $ProbeDirect
    Write-Info ("国内直连：{0}" -f ($d.Body -replace '\s+', ' '))
    $h = Get-Trace $ProbeDefault
    Write-Info ("默认出口：ip={0} loc={1}" -f $h.Ip, $h.Loc)
    $u = Get-Trace $ProbeAI
    if ($u.Loc -eq 'US') { Write-Ok ("AI 出口：ip={0} loc=US" -f $u.Ip) }
    else { Write-Warn2 ("AI 出口：ip={0} loc={1}（应为 US，请在面板检查美国组）" -f $u.Ip, $u.Loc) }

    Write-Host ''
    Write-Ok "完成。面板：$(Get-ApiBase)/ui （后端地址 $(Get-ApiBase)，密钥见 config.yaml 的 secret）"
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
