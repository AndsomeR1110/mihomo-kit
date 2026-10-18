# 一键安装：检查 → 下载补齐（prepare）→ 私有文件检查 → 询问快捷方式/系统调整
#           → 配置检查 → 注册并启动服务 → 创建桌面面板快捷方式
# 全程可重复运行（已完成的步骤自动跳过）。-DryRun 只检查和下载，不装服务。
param(
    [switch]$Yes,          # 无人值守：快捷方式=是、系统调整=否
    [switch]$NoShortcut,   # 无人值守也不要快捷方式
    [switch]$ApplyTweaks,  # 无人值守也关闭 IPv6/Teredo
    [switch]$DryRun,       # 不注册服务（本机已有别的 mihomo 时用它做检查）
    [string]$Proxy = '',   # 下载走指定代理，如 http://127.0.0.1:7890
    [switch]$NoPause
)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'install'

try {
    Write-Title '1/7 安装位置检查'
    if ($Root -match ' ') { throw "目录路径里有空格：$Root`n请把整个文件夹移到没有空格的路径（例如 C:\mihomo 或 D:\mihomo）后重试" }
    if ($Root -match '[^\x00-\x7F]') { Write-Warn2 "目录路径里有中文：$Root（一般可用，遇到问题就改成纯英文路径）" }
    Write-Ok $Root

    Write-Title '2/7 冲突检查'
    if (Test-VergeRunning) {
        throw '检测到 Clash Verge 正在运行。请先在 Verge 里关闭系统代理并从托盘彻底退出（两者不能同时用），然后重试'
    }
    $svc = Get-MihomoService
    $svcRunning = ($svc -and $svc.Status -eq 'Running')
    if ($svc) { Write-Ok "服务 mihomo 已存在（$($svc.Status)），本次将重新应用配置" }
    $base = Get-ApiBase
    $ctrlPort = [int](($base -split ':')[2])
    $taken = @()
    if (-not $svcRunning) {
        foreach ($p in @((Get-MixedPort), $ctrlPort)) {
            if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $taken += $p }
        }
    }
    if ($taken.Count -gt 0) {
        throw "端口 $($taken -join '、') 已被其他程序占用（常见于其他代理软件）。请先退出占用程序，或改 config.yaml 里的 mixed-port / external-controller 后重试"
    }
    Write-Ok '没有端口冲突'

    Write-Title '3/7 下载补齐（已有文件自动跳过）'
    & "$PSScriptRoot\prepare.ps1" -Proxy $Proxy -NoPause
    foreach ($f in @($MihomoExe, $WinSWExe, (Join-Path $ConfDir 'ui\index.html'))) {
        if (-not (Test-Path $f)) { throw "缺少 $f，下载没有完成。请检查网络后重试 install.cmd" }
    }
    foreach ($n in 'private-domain', 'anthropic', 'ai', 'cn-domain', 'global-domain', 'cn-ip') {
        if (-not (Test-Path (Join-Path $ConfDir "ruleset\$n.mrs"))) { throw "缺少 ruleset\$n.mrs，请重试 install.cmd" }
    }
    Write-Ok '程序文件齐全'

    Write-Title '4/7 私有文件检查'
    $ph = Get-Placeholders
    if ($ph.Count -gt 0) {
        $ph | ForEach-Object { Write-Warn2 $_ }
        Write-Host ''
        Write-Info '说明：节点信息没有就位。两种解决方式：'
        Write-Info '  A. 拿到分享者给的 nodes.yaml 和 infra-direct.yaml → 直接放进 config\private\ 覆盖'
        Write-Info '  B. 自建节点 → 按config\private\nodes.example.yaml 顶部的说明填写'
        Write-Info '填好后重新运行 install.cmd（之前的进度都会保留）'
        throw '私有文件未就绪'
    }
    Write-Ok 'nodes.yaml / infra-direct.yaml 已就绪'

    Write-Title '5/7 安装选项'
    if ($NoShortcut) { $wantShortcut = $false }
    elseif ($Yes)    { $wantShortcut = $true }
    else {
        $ans = Read-Host '在桌面创建「mihomo 面板」快捷方式（免密自动登录）？[Y/n]'
        $wantShortcut = -not ($ans -match '^[nN]')
    }
    if ($ApplyTweaks) { $wantTweaks = $true }
    elseif ($Yes)     { $wantTweaks = $false }
    else {
        $ans2 = Read-Host '关闭网卡 IPv6 与 Teredo，防止流量绕过代理（校园网建议 Y，随时可用 system-tweaks-revert 恢复）？[y/N]'
        $wantTweaks = $ans2 -match '^[yY]'
    }
    $shortcutText = '否'; if ($wantShortcut) { $shortcutText = '是' }
    $tweaksText   = '否'; if ($wantTweaks)   { $tweaksText = '是' }
    Write-Info "桌面快捷方式：$shortcutText　系统调整：$tweaksText"

    if ($wantTweaks) {
        Write-Title '6/7 系统调整'
        & "$PSScriptRoot\system-tweaks.ps1" -Apply -NoPause
    } else {
        Write-Title '6/7 系统调整（跳过）'
    }

    Write-Title '7/7 配置检查与服务安装'
    $t = Test-MihomoConfig
    if (-not $t.Ok) {
        $t.Lines | Select-Object -Last 8 | ForEach-Object { Write-Info $_ }
        throw '配置检查未通过'
    }
    Write-Ok '配置检查通过'

    if ($DryRun) {
        Write-Warn2 '-DryRun：到此为止，不注册服务、不改动网络'
        throw 'DRYRUN-STOP'
    }

    & "$PSScriptRoot\install-service.ps1" -NoPause

    $ok = $false
    $svc2 = Get-MihomoService
    if ($svc2 -and $svc2.Status -eq 'Running') { $ok = $true }
    if (-not $ok) {
        Write-Fail '服务没有运行起来。可运行 rescue.cmd 恢复直连，然后看日志排查（logs.cmd）'
    } else {
        Write-Ok '服务运行中'
        if ($wantShortcut) {
            & "$PSScriptRoot\make-panel-shortcut.ps1" -NoPause
        }
    }

    Write-Host ''
    if ($ok) {
        Write-Ok "安装完成。面板：$(Get-ApiBase)/ui （桌面快捷方式免密直达，或双击 panel.cmd）"
        Write-Info '建议：正常使用几天后双击 mark-good.cmd，把当前配置存为「已知可用」版本'
    }
}
catch {
    if ($_.Exception.Message -ne 'DRYRUN-STOP') { Write-Fail $_.Exception.Message }
}
finally {
    Wait-Close -NoPause:$NoPause
}
