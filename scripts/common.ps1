# 公共定义与函数。所有脚本都先 dot-source 本文件。
# 兼容 Windows PowerShell 5.1；本文件及所有 .ps1 必须保存为 UTF-8 with BOM，否则中文会乱码。

$ErrorActionPreference = 'Stop'

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

# 需要一起备份/回滚的文件（相对 config 目录）
$ManagedFiles = @('config.yaml', 'private\nodes.yaml', 'private\infra-direct.yaml')

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
    return Invoke-RestMethod -Uri ((Get-ApiBase) + $Path) -Headers $headers -Method $Method `
        -TimeoutSec $TimeoutSec -UseBasicParsing
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
    foreach ($rel in $ManagedFiles) {
        $path = Join-Path $ConfDir $rel
        if (-not (Test-Path $path)) { $found += "缺少文件 config\$rel"; continue }
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($text, '__[A-Z0-9_]+__')) { $found += "config\$rel 中仍有占位符 $($m.Value)" }
    }
    return $found
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
    foreach ($rel in $ManagedFiles) {
        $src = Join-Path $ConfDir $rel
        if (Test-Path $src) {
            $dst = Join-Path $Dest $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -Path $src -Destination $dst -Force
        }
    }
}

function Restore-Snapshot([string]$Src) {
    foreach ($rel in $ManagedFiles) {
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
