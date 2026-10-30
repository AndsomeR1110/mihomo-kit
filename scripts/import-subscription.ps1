# 一键导入订阅：把订阅链接写进套件并切换为在线订阅模式（不再需要 nodes.yaml）。
# 用法：
#   双击 import-subscription.cmd            → 弹出输入框，粘贴分享者/面板给的订阅链接
#   import-subscription.cmd -Url <链接>      → 直接导入（面板下载的「一键导入订阅.cmd」即此形态）
# 改写 config.yaml 前自动备份到 backup\；订阅节点没有 HK-/US- 前缀时自动取消分组过滤。
param([string]$Url = '', [switch]$FromPanel, [switch]$NoRestart, [switch]$NoPause)

# 定位校验：本脚本必须经由套件的 scripts\ 目录运行（面板下载的导入文件会转到这里）
$kitRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $kitRoot 'panel.cmd'))) {
    Write-Host ''
    Write-Host '[!] 目录结构不对：这不是 mihomo 套件的 scripts 目录。' -ForegroundColor Red
    Write-Host '    正确做法：如果你拿到的是「一键导入订阅.cmd」文件，把它移到套件目录' -ForegroundColor Yellow
    Write-Host '    （能看到 panel.cmd、config 文件夹的那一层），再双击它。' -ForegroundColor Yellow
    exit 1
}

. "$PSScriptRoot\common.ps1"
Start-RunLog 'import-subscription'

try {
    Write-Title '导入订阅'

    if (-not $Url) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $Url = [Microsoft.VisualBasic]::Interaction::InputBox('粘贴分享者或面板给你的订阅链接（https:// 开头）：', '导入订阅', '')
        if ([string]::IsNullOrWhiteSpace($Url)) { Write-Info '已取消，套件未做任何改动'; throw 'CANCEL-STOP' }
    }
    $Url = $Url.Trim()
    if ($Url -notmatch '^https?://') { throw '这个链接不像订阅地址（应以 http:// 或 https:// 开头）。请向分享者确认后重试' }
    if ($FromPanel) { Write-Ok '已从面板导入文件接收订阅链接' }

    # 打码显示（面板 token 属凭据，日志不整段落盘）
    $masked = $Url -replace '(/u/[^/]{6}).*', '$1…'
    Write-Info "订阅链接：$masked"

    # 1) 备份当前 config.yaml（改写失败可手工还原）
    $histDir = Join-Path $HistoryDir 'subscription-import'
    New-Item -ItemType Directory -Path $histDir -Force | Out-Null
    $bakName = 'config-{0}.yaml' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $ConfigFile (Join-Path $histDir $bakName) -Force
    Write-Ok "已备份当前配置 → backup\history\subscription-import\$bakName"

    # 2) 写 subscription.txt（进入订阅模式）
    [IO.File]::WriteAllText($SubscriptionFile, $Url, (New-Object Text.UTF8Encoding($false)))
    Write-Ok '已写入 config\private\subscription.txt'

    # 3) 切换 config.yaml 的节点来源为在线订阅（直连试拉一次订阅并验证节点）
    $r = Enable-SubscriptionProvider
    if ($r -eq 'already') { Write-Ok 'config.yaml 已指向此订阅' }
    else { Write-Ok 'config.yaml 已切换为在线订阅' }

    # 4) 配置校验
    $t = Test-MihomoConfig
    if (-not $t.Ok) {
        $t.Lines | Select-Object -Last 8 | ForEach-Object { Write-Info $_ }
        throw '配置校验未通过：链接可能拉不到节点。订阅信息已保留（subscription.txt），换网络或找分享者确认后重新双击导入即可；想回到原来的文件模式就删除 subscription.txt 再跑 test-config.cmd'
    }
    Write-Ok '配置校验通过'

    # 5) 生效
    $svc = Get-MihomoService
    if ($svc -and $svc.Status -eq 'Running') {
        if ($NoRestart) {
            Write-Warn2 '-NoRestart：本次不重启，稍后双击 restart.cmd 生效'
        }
        else {
            $ans = Read-Host '现在重启内核加载新订阅？[Y/n]'
            if ($ans -notmatch '^[nN]') {
                Write-Info '正在请求管理员权限重启服务（弹窗请点「是」）…'
                Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\restart.ps1", '-NoPause') | Out-Null
                Start-Sleep -Seconds 2
                $svc2 = Get-MihomoService
                if ($svc2 -and $svc2.Status -eq 'Running') { Write-Ok '服务已重启，订阅已加载' }
                else { Write-Warn2 '服务还在重启中，几秒后双击 status.cmd 确认' }
            }
            else {
                Write-Info '好的，稍后双击 restart.cmd（会弹管理员窗口）即可生效'
            }
        }
    }
    else {
        Write-Info '服务当前未运行：下次启动（start.cmd 或开机自启）时自动使用新订阅'
    }

    Write-Host ''
    Write-Ok '导入完成。打开面板（panel.cmd）就能看到新节点与延迟'
    Write-Info '想换回文件模式：删除 config\private\subscription.txt，再把 nodes.yaml 放回去，双击 apply-config.cmd'
}
catch {
    if ($_.Exception.Message -ne 'CANCEL-STOP') { Write-Fail $_.Exception.Message }
}
finally { Wait-Close -NoPause:$NoPause }
