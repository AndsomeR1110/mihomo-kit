# 系统层调整：关闭物理网卡的 IPv6 和 Teredo，防止 IPv6 流量绕过 TUN。
#   -Apply   关闭（会记录原状态到 backup\system-state.json）
#   -Revert  按记录恢复
# 执行时 Wi-Fi 可能短暂断开几秒。
param([switch]$Apply, [switch]$Revert, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Invoke-SelfElevate -ScriptPath $PSCommandPath -BoundParams $PSBoundParameters
Start-RunLog 'system-tweaks'

$StateFile = Join-Path $BackupDir 'system-state.json'

function Get-TeredoType {
    $r = Invoke-Native 'netsh.exe' @('interface', 'teredo', 'show', 'state')
    $line = $r.Output | Where-Object { $_ -match '^\s*(Type|类型)\s*:' } | Select-Object -First 1
    if ($line) { return ($line -split ':', 2)[1].Trim() }
    return 'unknown'
}

function Show-State {
    Write-Title '当前状态'
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
        $b = Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        $state = '未知'
        if ($b) { if ($b.Enabled) { $state = '开启' } else { $state = '关闭' } }
        Write-Info ("{0,-16} IPv6: {1}" -f $_.Name, $state)
    }
    Write-Info ("Teredo: {0}" -f (Get-TeredoType))
}

try {
    if (-not $Apply -and -not $Revert) {
        Show-State
        Write-Info ''
        Write-Info '用法：system-tweaks.cmd -Apply   关闭 IPv6 与 Teredo'
        Write-Info '      system-tweaks.cmd -Revert  恢复到调整前'
    }
    elseif ($Apply) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
        if (-not (Test-Path $StateFile)) {
            $state = [ordered]@{
                saved    = (Get-Date).ToString('s')
                teredo   = (Get-TeredoType)
                adapters = @($adapters | ForEach-Object {
                    $b = Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                    [ordered]@{ name = $_.Name; ipv6 = [bool]($b -and $b.Enabled) }
                })
            }
            $state | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
            Write-Ok "原状态已记录到 $StateFile"
        } else {
            Write-Ok '已有原状态记录，保留不覆盖'
        }
        Write-Title '关闭物理网卡 IPv6'
        foreach ($a in $adapters) {
            Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
            Write-Ok $a.Name
        }
        Write-Title '关闭 Teredo'
        Invoke-Native 'netsh.exe' @('interface', 'teredo', 'set', 'state', 'disabled') | Out-Null
        Write-Ok 'Teredo 已关闭'
        Show-State
        Write-Warn2 '另请手动关闭浏览器的“使用安全 DNS”（Chrome/Edge：设置 → 隐私和安全 → 安全）'
    }
    elseif ($Revert) {
        if (-not (Test-Path $StateFile)) { throw "没有找到原状态记录 $StateFile，无法自动恢复" }
        $state = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Title '恢复网卡 IPv6'
        foreach ($a in $state.adapters) {
            if ($a.ipv6) {
                Enable-NetAdapterBinding -Name $a.name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                Write-Ok "$($a.name) 已恢复开启"
            }
        }
        Write-Title '恢复 Teredo'
        Invoke-Native 'netsh.exe' @('interface', 'teredo', 'set', 'state', 'default') | Out-Null
        Write-Ok 'Teredo 已恢复默认'
        Remove-Item $StateFile -Force
        Show-State
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
