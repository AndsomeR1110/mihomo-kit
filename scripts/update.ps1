# 一键升级：更新套件的脚本与文档（VERSION、CHANGELOG、scripts、*.cmd 等）。
# 绝不覆盖：config\（你的密钥、节点、订阅）、bin\（内核）、logs\、backup\、tray\（托盘有单独升级包）。
# 来源：GitHub 仓库 zip 包；GitHub 直连失败自动走 gh-proxy.com 镜像。
# 一般升级后无需重启内核；若提示配置结构有变，再跑 test-config.cmd + apply-config.cmd。
param([switch]$CheckOnly, [switch]$NoPause)
. "$PSScriptRoot\common.ps1"
Start-RunLog 'update'

$Repo   = 'AndsomeR1110/mihomo-kit'
$RawVer = "https://raw.githubusercontent.com/$Repo/main/VERSION"
$ZipUrl = "https://github.com/$Repo/archive/refs/heads/main.zip"

function Get-RemoteVersion {
    # 先按系统路由拉（内核在跑时经 TUN 可达 GitHub），失败再走 gh-proxy 镜像（国内直连可用的镜像）
    foreach ($u in @($RawVer, ('https://gh-proxy.com/' + $RawVer))) {
        $r = Invoke-Native 'curl.exe' @('-sL', '--max-time', '20', $u)
        $v = ($r.Output -join '').Trim()
        if ($r.ExitCode -eq 0 -and $v -match '^[0-9]+\.[0-9]+\.[0-9]+') { return $v }
    }
    return $null
}

function Save-RemoteZip([string]$Dest) {
    foreach ($u in @($ZipUrl, ('https://gh-proxy.com/' + $ZipUrl))) {
        $r = Invoke-Native 'curl.exe' @('-sL', '--max-time', '180', '-o', $Dest, $u)
        if ($r.ExitCode -eq 0 -and (Test-Path $Dest) -and (Get-Item $Dest).Length -gt 10KB) { return $true }
    }
    return $false
}

try {
    $cur = Get-KitVersion
    Write-Title "当前版本：$cur"
    $remote = Get-RemoteVersion
    if (-not $remote) { throw '拿不到 GitHub 上的最新版本（网络不通？）。稍后再试，或向分享者要升级包' }
    Write-Info "最新版本：$remote"

    if ($remote -eq $cur) {
        Write-Ok '已是最新，无需升级'
    }
    else {
        if ($CheckOnly) {
            Write-Warn2 '-CheckOnly：发现新版本，本次只提示不升级（去掉参数再跑一次即真正升级）'
        }
        else {
            Write-Title "升级 $cur → $remote"
            $zip = Join-Path $env:TEMP "mihomo-kit-update-$remote.zip"
            if (-not (Save-RemoteZip $zip)) { throw '升级包下载失败（GitHub 与镜像都不通）。稍后再试，或向分享者要升级包' }
            Write-Ok '升级包已下载'

            $stage = Join-Path $env:TEMP "mihomo-kit-update-stage-$remote"
            if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $stage -Force
            $src = Join-Path $stage 'mihomo-kit-main'
            if (-not (Test-Path (Join-Path $src 'VERSION'))) { throw '升级包内容不对（缺 VERSION），已放弃，套件未被改动' }

            # 只覆盖白名单（脚本/文档/启动器/图标），config、bin、logs、backup、tray 一律不动
            $copied = 0
            foreach ($f in (Get-ChildItem -Path $src -File)) {
                if ($f.Name -eq '.gitignore') { continue }
                Copy-Item $f.FullName (Join-Path $Root $f.Name) -Force
                $copied++
            }
            $newScripts = Join-Path $src 'scripts'
            if (Test-Path $newScripts) {
                foreach ($f in (Get-ChildItem -Path $newScripts -File)) {
                    Copy-Item $f.FullName (Join-Path $PSScriptRoot $f.Name) -Force
                    $copied++
                }
            }
            Write-Ok "已更新 $copied 个文件（config、节点、内核、日志均未动）"

            $cur2 = Get-KitVersion
            if ($cur2 -eq $remote) { Write-Ok "升级完成，当前版本：$cur2" }
            else { Write-Warn2 "版本文件读出来是 $cur2，与预期 $remote 不一致，请截图本窗口发给分享者" }

            Write-Info '一般无需重启内核。若变更说明里提到配置结构变化：test-config.cmd → apply-config.cmd'
            Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
        }
    }
}
catch { Write-Fail $_.Exception.Message }
finally { Wait-Close -NoPause:$NoPause }
