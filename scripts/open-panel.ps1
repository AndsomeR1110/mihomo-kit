# 用默认浏览器打开 mihomo 面板（自动带上密钥，免手动登录）
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'open-panel'

try {
    $secret = Get-ApiSecret
    if (-not $secret) { throw 'config.yaml 里没有 secret，请先运行 prepare.cmd' }
    $base = Get-ApiBase
    $port = [int](($base -split ':')[2])
    $url  = "$base/ui/?hostname=127.0.0.1&port=$port&secret=$secret"
    Start-Process $url
    Write-Ok '已在默认浏览器打开面板'
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
