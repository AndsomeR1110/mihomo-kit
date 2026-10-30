# 公共定义与函数。所有脚本都先 dot-source 本文件。
# 兼容 Windows PowerShell 5.1；本文件及所有 .ps1 必须保存为 UTF-8 with BOM，否则中文会乱码。

$ErrorActionPreference = 'Stop'

# 控制台统一 UTF-8：新开的窗口代码页是 GBK(936)，curl 等外部程序的 UTF-8 输出会被按 GBK 解成乱码
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch { }

$Root        = Split-Path -Parent $PSScriptRoot
$BinDir      = Join-Path $Root 'bin'
$ConfDir     = Join-Path $Root 'config'
$PrivDir     = Join-Path $ConfDir 'private'
$LogDir      = Join-Path $Root 'logs'
$ScriptLogDir = Join-Path $LogDir 'scripts'
$BackupDir   = Join-Path $Root 'backup'
$AppliedDir  = Join-Path $BackupDir 'applied'
$LastGoodDir = Join-Path $BackupDir 'last-good'
$HistoryDir  = Join-Path $BackupDir 'history'
$MihomoExe   = Join-Path $BinDir 'mihomo.exe'
$WinSWExe    = Join-Path $BinDir 'mihomo-service.exe'
$ConfigFile  = Join-Path $ConfDir 'config.yaml'
$ServiceName = 'mihomo'

# ---------- 版本 ----------
$VersionFile = Join-Path $Root 'VERSION'
function Get-KitVersion {
    try {
        if (Test-Path $VersionFile) { return ([IO.File]::ReadAllText($VersionFile, [Text.Encoding]::UTF8)).Trim() }
    } catch { }
    return 'unknown'
}

# ---------- 订阅模式 ----------
# config\private\subscription.txt 里放一行订阅链接（https://…）即进入订阅模式：
# 节点改为在线订阅拉取，不再需要 nodes.yaml（面板分发的 token 订阅即用此方式）
$SubscriptionFile = Join-Path $PrivDir 'subscription.txt'
function Test-SubscriptionMode {
    if (-not (Test-Path $SubscriptionFile)) { return $false }
    try { return (([IO.File]::ReadAllText($SubscriptionFile, [Text.Encoding]::UTF8)).Trim() -match '^https?://') } catch { return $false }
}
function Get-SubscriptionUrl { return ([IO.File]::ReadAllText($SubscriptionFile, [Text.Encoding]::UTF8)).Trim() }

# 需要一起备份/回滚的文件（相对 config 目录）；订阅模式下 nodes.yaml 换成 subscription.txt
function Get-ManagedFiles {
    $f = @('config.yaml', 'private\infra-direct.yaml')
    if (Test-SubscriptionMode) { $f += 'private\subscription.txt' }
    else { $f += 'private\nodes.yaml' }
    return $f
}

# 出口实测地址
$ProbeDirect  = 'https://myip.ipip.net'                    # 国内直连，返回本机直连 IP
$ProbeDefault = 'https://www.cloudflare.com/cdn-cgi/trace'  # 走“默认出口”
$ProbeAI      = 'https://claude.ai/cdn-cgi/trace'           # 走“美国组”
$Probe204     = 'https://www.gstatic.com/generate_204'

# ---------- 输出 ----------
function Write-Title([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)    { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text)  { Write-Host "  [失败] $Text" -ForegroundColor Red }
function Write-Info([string]$Text)  { Write-Host "  $Text" }

# ---------- 权限与运行记录 ----------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 非管理员时，以管理员身份在新窗口重新运行当前脚本（会弹出 UAC），然后退出当前进程
function Invoke-SelfElevate {
    param([string]$ScriptPath, [System.Collections.IDictionary]$BoundParams)
    if (Test-IsAdmin) { return }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath))
    foreach ($key in $BoundParams.Keys) {
        $val = $BoundParams[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argList += "-$key" }
        } else {
            $argList += "-$key"
            $argList += ('"{0}"' -f $val)
        }
    }
    Write-Host '需要管理员权限，正在请求提权（请在弹窗中点“是”）……' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Write-Host '已取消提权，脚本未执行。' -ForegroundColor Red
    }
    exit
}

# 每次运行写一份记录到 logs\scripts\，方便 agent 或事后查看
function Start-RunLog([string]$Name) {
    if (-not (Test-Path $ScriptLogDir)) { New-Item -ItemType Directory -Path $ScriptLogDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $ScriptLogDir "$Name-$stamp.log"
    try { Start-Transcript -Path $path -Force | Out-Null } catch { }
}

function Stop-RunLog {
    try { Stop-Transcript | Out-Null } catch { }
}

function Wait-Close([switch]$NoPause) {
    Stop-RunLog
    if (-not $NoPause) {
        Write-Host ''
        Read-Host '按回车键关闭窗口' | Out-Null
    }
}

# ---------- 运行外部程序（避免 PowerShell 5.1 把 stderr 当成异常） ----------
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

# ---------- 读配置 ----------
function Get-ConfigText {
    return [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8)
}

function Get-ConfigValue([string]$Key, [string]$Default) {
    $text = Get-ConfigText
    $m = [regex]::Match($text, "(?m)^$([regex]::Escape($Key)):\s*`"?([^`"\r\n#]+?)`"?\s*(#.*)?$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $Default
}

function Get-ApiBase   { return 'http://' + (Get-ConfigValue 'external-controller' '127.0.0.1:9097') }
function Get-ApiSecret { return (Get-ConfigValue 'secret' '') }
function Get-MixedPort { return [int](Get-ConfigValue 'mixed-port' '7897') }

# ---------- API ----------
function Invoke-Api {
    param([string]$Path, [string]$Method = 'GET', [int]$TimeoutSec = 3)
    $headers = @{ Authorization = 'Bearer ' + (Get-ApiSecret) }
    # PS5.1 对不带 charset 的 JSON 响应按 ISO-8859-1 解码，中文会乱（“美国组”→“ç¾…”）；按字节还原后统一按 UTF-8 解
    $resp = Invoke-WebRequest -Uri ((Get-ApiBase) + $Path) -Headers $headers -Method $Method `
        -TimeoutSec $TimeoutSec -UseBasicParsing
    if ($resp.Content -is [byte[]]) {
        $text = [Text.Encoding]::UTF8.GetString($resp.Content)
    } else {
        $text = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($resp.Content))
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Wait-Api([int]$TimeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $v = Invoke-Api '/version'
            if ($v.version) { return $v.version }
        } catch { }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Get-GroupNow([string]$Name) {
    try {
        $g = Invoke-Api ('/proxies/' + [uri]::EscapeDataString($Name))
        return $g.now
    } catch { return '?' }
}

# ---------- 出口实测 ----------
# 不加 -ViaMixedPort 时走系统路由（即 TUN），和真实应用看到的一致
function Invoke-Probe {
    param([string]$Url, [switch]$ViaMixedPort, [int]$TimeoutSec = 10)
    $args2 = @('-s', '--max-time', "$TimeoutSec", '-w', "`n__HTTP__%{http_code}")
    if ($ViaMixedPort) { $args2 += @('-x', ('http://127.0.0.1:{0}' -f (Get-MixedPort))) }
    $args2 += $Url
    $r = Invoke-Native 'curl.exe' $args2
    $text = ($r.Output -join "`n")
    $code = '000'
    $m = [regex]::Match($text, '__HTTP__(\d{3})')
    if ($m.Success) { $code = $m.Groups[1].Value; $text = $text.Substring(0, $m.Index) }
    return [pscustomobject]@{ Code = $code; Body = $text.Trim() }
}

function Get-Trace {
    param([string]$Url, [switch]$ViaMixedPort)
    $r = Invoke-Probe -Url $Url -ViaMixedPort:$ViaMixedPort
    $ip = ''; $loc = ''
    foreach ($line in ($r.Body -split "`n")) {
        if ($line -like 'ip=*')  { $ip  = $line.Substring(3).Trim() }
        if ($line -like 'loc=*') { $loc = $line.Substring(4).Trim() }
    }
    return [pscustomobject]@{ Code = $r.Code; Ip = $ip; Loc = $loc }
}

function Test-Egress {
    $r = Invoke-Probe -Url $Probe204 -ViaMixedPort
    return ($r.Code -eq '204')
}

# ---------- 服务 ----------
function Get-MihomoService { return Get-Service -Name $ServiceName -ErrorAction SilentlyContinue }

function Start-MihomoService {
    Set-Service -Name $ServiceName -StartupType Automatic
    Start-Service -Name $ServiceName
}

function Stop-MihomoService {
    $svc = Get-MihomoService
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
    # 兜底：服务停了但内核进程残留时强制结束（只针对本目录下的 mihomo.exe）
    Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $MihomoExe } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-MihomoMemoryMB {
    $p = Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return [math]::Round($p.WorkingSet64 / 1MB, 1) }
    return $null
}

function Test-VergeRunning {
    $names = @('clash-verge', 'verge-mihomo', 'verge-mihomo-alpha')
    return [bool](Get-Process -Name $names -ErrorAction SilentlyContinue)
}

# ---------- 系统代理 ----------
function Disable-SystemProxy {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $cur = (Get-ItemProperty -Path $key -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    if ($cur -eq 1) {
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 0
        return $true
    }
    return $false
}

# ---------- 配置检查 ----------
function Get-Placeholders {
    $found = @()
    foreach ($rel in (Get-ManagedFiles)) {
        $path = Join-Path $ConfDir $rel
        if (-not (Test-Path $path)) { $found += "缺少文件 config\$rel"; continue }
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($text, '__[A-Z0-9_]+__')) { $found += "config\$rel 中仍有占位符 $($m.Value)" }
    }
    return $found
}

# ---------- 订阅模式：改写 config.yaml ----------
# 直连拉一次订阅，提取节点名列表（拉不到返回 $null）
function Get-SubscriptionNodeNames([string]$Url, [int]$TimeoutSec = 25) {
    $r = Invoke-Native 'curl.exe' @('-sL', '--max-time', "$TimeoutSec", $Url)
    if ($r.ExitCode -ne 0) { return $null }
    $names = @()
    foreach ($m in [regex]::Matches(($r.Output -join "`n"), '(?m)^\s*-\s*name:\s*["'']?(.+?)["'']?\s*$')) {
        $names += $m.Groups[1].Value.Trim()
    }
    return $names
}

# 把 config.yaml 的 nodes provider 换成在线订阅（file → http），并按订阅节点名有无 HK-/US- 前缀决定是否去掉分组 filter
function Enable-SubscriptionProvider {
    $url = Get-SubscriptionUrl
    $text = Get-ConfigText

    # 已经是订阅型且 URL 一致 → 无需改写
    if ($text -match ('(?m)^    url: "' + [regex]::Escape($url) + '"')) { return 'already' }

    $nl = "`r`n"
    if ($text -match '(?m)^  nodes:\r?\n    type: file\r?\n    path: \./private/nodes\.yaml\r?\n') {
        $newBlock = '  nodes:' + $nl + '    type: http' + $nl + '    url: "' + $url + '"' + $nl +
                    '    interval: 86400' + $nl + '    path: ./private/subscription-cache.yaml' + $nl
        $text = [regex]::Replace($text, '(?m)^  nodes:\r?\n    type: file\r?\n    path: \./private/nodes\.yaml\r?\n', { param($m) $newBlock })
    }
    elseif ($text -match '(?m)^  nodes:\r?\n    type: http\r?\n') {
        # 订阅型但 URL 变了（换 token / 换面板）→ 只换 URL 行
        $text = [regex]::Replace($text, '(?m)^    url: "[^"]*"$', '    url: "' + $url + '"')
    }
    else {
        throw 'config.yaml 的 proxy-providers.nodes 不是预期的 file/http 型，请手动检查后再试'
    }

    # 订阅里没有 HK-/US- 前缀时去掉两组 filter（否则组会是空的）；保留 empty-fallback 防误直连
    $names = Get-SubscriptionNodeNames $url
    if ($null -eq $names) { Write-Warn2 '订阅暂时拉不到（稍后内核会自己再拉），本次跳过节点前缀检测' }
    else {
        $hasHK = @($names | Where-Object { $_ -like 'HK-*' }).Count -gt 0
        $hasUS = @($names | Where-Object { $_ -like 'US-*' }).Count -gt 0
        if ($names.Count -gt 0 -and -not ($hasHK -and $hasUS)) {
            $text = [regex]::Replace($text, '(?m)^\s+filter: "\^(?:HK|US)-"\s*$', '')
            Write-Warn2 '订阅节点没有 HK-/US- 前缀，已取消分组过滤（全部节点在两组均可用）'
        }
        Write-Info ("订阅节点数：{0}" -f $names.Count)
    }

    [IO.File]::WriteAllText($ConfigFile, $text, (New-Object Text.UTF8Encoding($false)))
    return 'updated'
}

# mihomo -t 不检查 Hy2 证书指纹格式，这里补一道
function Get-FingerprintProblems {
    $path = Join-Path $PrivDir 'nodes.yaml'
    if (-not (Test-Path $path)) { return @() }
    $bad = @()
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '(?m)^\s*fingerprint:\s*"?([^"\r\n#]+?)"?\s*$')) {
        $hex = ($m.Groups[1].Value -replace ':', '').Trim()
        if ($hex -notmatch '^[0-9A-Fa-f]{64}$') { $bad += "证书指纹格式不对：$($m.Groups[1].Value)" }
    }
    return $bad
}

function Test-MihomoConfig {
    $problems = @()
    $problems += Get-Placeholders
    $problems += Get-FingerprintProblems
    if ($problems.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Lines = $problems }
    }
    $r = Invoke-Native $MihomoExe @('-t', '-d', $ConfDir)
    $ok = ($r.ExitCode -eq 0) -and (($r.Output -join "`n") -match 'test is successful')
    return [pscustomobject]@{ Ok = $ok; Lines = $r.Output }
}

# ---------- 快照 ----------
function Save-Snapshot([string]$Dest) {
    foreach ($rel in (Get-ManagedFiles)) {
        $src = Join-Path $ConfDir $rel
        if (Test-Path $src) {
            $dst = Join-Path $Dest $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -Path $src -Destination $dst -Force
        }
    }
}

function Restore-Snapshot([string]$Src) {
    foreach ($rel in (Get-ManagedFiles)) {
        $from = Join-Path $Src $rel
        if (Test-Path $from) {
            $to = Join-Path $ConfDir $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
            Copy-Item -Path $from -Destination $to -Force
        }
    }
}

# ---------- 日志 ----------
function Get-LatestCoreLog {
    if (-not (Test-Path $LogDir)) { return $null }
    return Get-ChildItem -Path $LogDir -Filter '*.out.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Show-RecentLog([int]$Lines = 30) {
    $f = Get-LatestCoreLog
    if (-not $f) { Write-Info '（还没有内核日志）'; return }
    Write-Info "日志文件：$($f.FullName)"
    Get-Content -Path $f.FullName -Tail $Lines -Encoding UTF8 | ForEach-Object { Write-Host "    $_" }
}
