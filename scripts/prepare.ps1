# 准备：下载内核 / WinSW / 面板 / 规则集、生成面板密钥、建立私有文件模板
# 不改变当前上网方式。默认直连下载，GitHub 连不上时自动改走 gh-proxy.com 镜像；
# 可用 -Proxy 'http://127.0.0.1:7890' 指定现有代理加速下载
param(
    [string]$Proxy = '',
    [switch]$Force,
    [switch]$NoPause
)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'prepare'

$KernelUrl = 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-windows-amd64-v1.19.32.zip'
$WinSWUrl  = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
$UiUrl     = 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip'
$RuleBase  = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo'
$Mirror    = 'https://gh-proxy.com/'
$RuleSets = [ordered]@{
    'private-domain.mrs' = "$RuleBase/geosite/private.mrs"
    'anthropic.mrs'      = "$RuleBase/geosite/anthropic.mrs"
    'ai.mrs'             = "$RuleBase/geosite/category-ai-!cn.mrs"
    'cn-domain.mrs'      = "$RuleBase/geosite/cn.mrs"
    'global-domain.mrs'  = "$RuleBase/geosite/geolocation-!cn.mrs"
    'cn-ip.mrs'          = "$RuleBase/geoip/cn.mrs"
}

function Get-File([string]$Url, [string]$OutFile) {
    # 国内网络优先走 gh-proxy.com 镜像，失败回退直连；30 秒速度低于 10KB/s 视为失败
    foreach ($u in @(($Mirror + $Url), $Url)) {
        $a = @('-sSL', '--fail', '--retry', '1', '--connect-timeout', '8', '--max-time', '300',
               '--speed-limit', '10240', '--speed-time', '30', '-o', $OutFile)
        if ($Proxy) { $a += @('-x', $Proxy) }
        $a += $u
        $r = Invoke-Native 'curl.exe' $a
        if ($r.ExitCode -eq 0 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return $true }
    }
    return $false
}

$failed = 0
try {
    Write-Title '1/6 创建目录'
    foreach ($d in @($BinDir, $PrivDir, (Join-Path $ConfDir 'ruleset'), (Join-Path $ConfDir 'ui'), $LogDir, $BackupDir)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Write-Ok $Root

    Write-Title '2/6 内核 mihomo v1.19.32'
    if ((Test-Path $MihomoExe) -and -not $Force) {
        Write-Ok '已存在 bin\mihomo.exe（加 -Force 可覆盖）'
    } else {
        $zip = Join-Path $env:TEMP 'mihomo-kernel.zip'
        $tmp = Join-Path $env:TEMP 'mihomo-kernel-extract'
        if (Get-File $KernelUrl $zip) {
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Filter '*.exe' -Recurse | Select-Object -First 1
            if ($inner) {
                Copy-Item -Path $inner.FullName -Destination $MihomoExe -Force
                Write-Ok '已下载并解压到 bin\mihomo.exe'
            } else {
                Write-Fail '内核压缩包里没有找到 exe'
                $failed++
            }
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
        } else {
            Write-Fail "内核下载失败（直连与镜像都没成功）：$KernelUrl"
            $failed++
        }
    }
    if (Test-Path $MihomoExe) {
        $v = Invoke-Native $MihomoExe @('-v')
        Write-Info ($v.Output | Select-Object -First 1)
    }

    Write-Title '3/6 下载 WinSW v2.12.0'
    if ((Test-Path $WinSWExe) -and -not $Force) {
        Write-Ok '已存在 bin\mihomo-service.exe'
    } elseif (Get-File $WinSWUrl $WinSWExe) {
        Write-Ok '已下载为 bin\mihomo-service.exe'
    } else {
        Write-Fail "下载失败：$WinSWUrl"; $failed++
    }

    Write-Title '4/6 下载 zashboard 面板'
    $uiDir = Join-Path $ConfDir 'ui'
    if ((Test-Path (Join-Path $uiDir 'index.html')) -and -not $Force) {
        Write-Ok '面板已存在'
    } else {
        $zip = Join-Path $env:TEMP 'zashboard-dist.zip'
        $tmp = Join-Path $env:TEMP 'zashboard-extract'
        if (Get-File $UiUrl $zip) {
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Join-Path $tmp 'dist'
            if (-not (Test-Path $inner)) { $inner = $tmp }
            Get-ChildItem $uiDir -Force | Remove-Item -Recurse -Force
            Copy-Item -Path (Join-Path $inner '*') -Destination $uiDir -Recurse -Force
            Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
            Write-Ok '已解压到 config\ui'
        } else {
            Write-Fail "下载失败：$UiUrl"; $failed++
        }
    }

    Write-Title '5/6 预下载规则集'
    $rsDir = Join-Path $ConfDir 'ruleset'
    foreach ($name in $RuleSets.Keys) {
        $out = Join-Path $rsDir $name
        if ((Test-Path $out) -and (Get-Item $out).Length -gt 0 -and -not $Force) {
            Write-Ok ("{0,-20} 已存在" -f $name)
            continue
        }
        if (Get-File $RuleSets[$name] $out) {
            Write-Ok ("{0,-20} {1,8:N0} 字节" -f $name, (Get-Item $out).Length)
        } else {
            Write-Fail "$name 下载失败"; $failed++
        }
    }

    Write-Title '6/6 面板密钥与私有文件'
    $text = Get-ConfigText
    if ($text.Contains('__API_SECRET__')) {
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secret = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        $text = $text.Replace('__API_SECRET__', $secret)
        [IO.File]::WriteAllText($ConfigFile, $text, (New-Object Text.UTF8Encoding($false)))
        Write-Ok '已生成随机面板密钥（写入 config.yaml 的 secret）'
    } else {
        Write-Ok '面板密钥已存在'
    }
    foreach ($n in @('nodes', 'infra-direct')) {
        $real = Join-Path $PrivDir "$n.yaml"
        $tpl  = Join-Path $PrivDir "$n.example.yaml"
        if (-not (Test-Path $real) -and (Test-Path $tpl)) {
            Copy-Item $tpl $real
            Write-Warn2 "已从模板创建 config\private\$n.yaml，请填写其中的占位符"
        } elseif (Test-Path $real) {
            Write-Ok "config\private\$n.yaml 已存在"
        }
    }

    Write-Title '结果'
    $ph = Get-Placeholders
    if ($ph.Count -gt 0) {
        Write-Warn2 '还有占位符没填：'
        $ph | ForEach-Object { Write-Info "- $_" }
    }
    if ($failed -eq 0) { Write-Ok '准备完成。下一步：填好 private 下的两个文件，然后运行 test-config.cmd' }
    else { Write-Fail "$failed 项失败，请检查网络或代理后重试（已完成的项不会重复下载）" }
}
catch {
    Write-Fail $_.Exception.Message
}
finally {
    Wait-Close -NoPause:$NoPause
}
