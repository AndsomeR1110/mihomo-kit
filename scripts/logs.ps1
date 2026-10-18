# 实时查看内核日志（Ctrl+C 退出）。不需要管理员权限。
param([int]$Tail = 50)
. "$PSScriptRoot\common.ps1"

$f = Get-LatestCoreLog
if (-not $f) {
    Write-Warn2 '还没有内核日志（服务可能从未启动过）'
    Read-Host '按回车键关闭窗口' | Out-Null
    exit 1
}
Write-Host "正在跟踪 $($f.FullName)，按 Ctrl+C 退出" -ForegroundColor Cyan
Get-Content -Path $f.FullName -Tail $Tail -Wait -Encoding UTF8
