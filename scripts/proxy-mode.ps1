# 代理模式：rule（规则）/ global（全局）/ direct（直连）
#
# 只改 config.yaml 里的 mode: 一行，不动任何规则。
#   rule   = 按规则分流（默认，日常用这个）
#   global = 所有流量都走「默认出口」指向的策略组（调试/临时全局代理）
#   direct = 所有流量直连（等于临时关掉分流，内核仍在跑）
#
# 模式是「热切换」：调 mihomo 的 API 立即生效，不需要重启服务、不需要管理员权限。
# 同时写回 config.yaml，这样重启内核 / 重启电脑后保持你选的模式。
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('rule', 'global', 'direct', 'get')]
    [string]$Mode,
    [switch]$NoPause
)
. "$PSScriptRoot\common.ps1"
$isGet = ($Mode -eq 'get')
if (-not $isGet) { Start-RunLog "proxy-mode-$Mode" }

try {
    if ($isGet) {
        Write-Output (Get-ProxyMode)
        exit 0
    }

    $before = Get-ProxyMode
    Set-ProxyMode $Mode

    # 热切换：内核在跑就直接改运行时，省掉一次重启
    $live = $false
    if (Test-ApiAlive) {
        try {
            Invoke-Api '/configs' -Method 'PATCH' -Body @{ mode = $Mode } -TimeoutSec 5 | Out-Null
            $live = $true
        } catch { }
    }

    $names = @{ rule = '规则模式'; global = '全局模式'; direct = '直连模式' }
    if ($live) {
        Write-Ok ("已切换为{0}（立即生效）" -f $names[$Mode])
    } else {
        Write-Warn2 ("已写入配置（{0}），但内核未运行——下次启动生效" -f $names[$Mode])
    }
    if ($before -ne $Mode) { Write-Info ("原模式：{0}" -f $names[$before]) }

    if ($Mode -eq 'direct') { Write-Info '直连模式下所有流量不走代理；切回 rule 即可恢复分流' }
    if ($Mode -eq 'global') { Write-Info '全局模式下所有流量走「默认出口」；AI 域名不再单独走美国组' }
}
catch { Write-Fail $_.Exception.Message; exit 1 }
finally { if (-not $isGet) { Wait-Close -NoPause:$NoPause } }
