# 检查配置：占位符、证书指纹格式、mihomo -t 语法校验。不需要管理员权限，不影响正在运行的服务。
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'test-config'

$exit = 1
try {
    Write-Title '检查配置'
    if (-not (Test-Path $MihomoExe)) { throw '找不到 bin\mihomo.exe，请先运行 prepare.cmd' }
    $r = Test-MihomoConfig
    $r.Lines | Select-Object -Last 8 | ForEach-Object { Write-Info $_ }
    if ($r.Ok) { Write-Ok '配置检查通过'; $exit = 0 }
    else { Write-Fail '配置检查未通过，未做任何改动' }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
exit $exit
