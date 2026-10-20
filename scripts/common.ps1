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
$ManagedFiles = @('config.yaml', 'private\nodes.yaml', 'private\infra-direct.yaml',
                  'dns\on.yaml', 'dns\off.yaml')

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

# ---------- 配置就地编辑（托盘开关用） ----------
# config.yaml 必须保留为 UTF-8 无 BOM、LF 换行：mihomo 对 CRLF 的 YAML 块标量敏感，
# 直接改坏会导致内核起不来。这里统一按「读全文 → 正则替换 → 原子写回」处理。

$DnsMarkerBegin = '# >>> dns-override >>>'
$DnsMarkerEnd   = '# <<< dns-override <<<'

function Read-ConfigText {
    return [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8)
}

function Write-ConfigText([string]$Text) {
    $tmp = $ConfigFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $ConfigFile -Force
}

# 当前代理模式：rule | global | direct
function Get-ProxyMode {
    $m = [regex]::Match((Read-ConfigText), '(?m)^mode:\s*(\w+)')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return 'rule'
}

function Set-ProxyMode([string]$Mode) {
    if ($Mode -notin @('rule', 'global', 'direct')) { throw "未知的代理模式：$Mode" }
    $text = Read-ConfigText
    $new = [regex]::Replace($text, '(?m)^mode:\s*\w+', ('mode: ' + $Mode), 1)
    if ($new -eq $text -and $text -notmatch '(?m)^mode:') {
        throw 'config.yaml 里没有 mode 这一行，请手动加上（例如 mode: rule）'
    }
    Write-ConfigText $new
}

# ---------- DNS 覆写方案（on / off） ----------
# 一次切换同时改两处，缺一不可：
#   1) 标记之间的 dns: 段（内容取自 config\dns\<state>.yaml）
#   2) 顶层 tun.strict-route（on → true，off → false）
# 两处必须在内存里一起改完再一次性写回，否则会留下「DNS 是新的、路由开关是旧的」半成品。

# 方案文件里 dns: 段（含其后的注释）的原文
function Get-DnsSchemeBlock([string]$State) {
    if ($State -notin @('on', 'off')) { throw "未知的 DNS 覆写状态：$State" }
    $variant = Join-Path (Join-Path $ConfDir 'dns') "$State.yaml"
    if (-not (Test-Path $variant)) { throw "缺少 DNS 方案文件：$variant" }
    $block = [IO.File]::ReadAllText($variant, [Text.Encoding]::UTF8)
    $i = $block.IndexOf("`ndns:")
    if ($block.StartsWith('dns:')) { $i = 0 }
    if ($i -lt 0) { throw "$variant 里找不到 dns: 段落" }
    return ($block.Substring($i).Trim() + "`n")
}

# 去掉注释行与空行后的「语义签名」：用来判断 config.yaml 里的内容是否就是某份方案。
# 这样用户可以随手改方案文件里的注释，不影响状态判断；但任何实质字段变动都能被认出来。
function Get-DnsSchemeSignature([string]$Text) {
    $lines = $Text -split "`r`n|`n" |
        ForEach-Object { $_.TrimEnd() } |
        Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
    return ($lines -join "`n")
}

# config.yaml 标记之间的当前内容
function Get-DnsBlockInConfig {
    $text = Read-ConfigText
    if (-not $text.Contains($DnsMarkerBegin)) { return $null }
    $m = [regex]::Match($text, '(?s)' + [regex]::Escape($DnsMarkerBegin) + '(.*?)' + [regex]::Escape($DnsMarkerEnd))
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value.Trim() + "`n")
}

# 当前 DNS 覆写状态：on | off | unknown
#   unknown = 标记缺失，或内容与两份方案都对不上（例如改过 on.yaml 但还没重新切换）
function Get-DnsOverride {
    $cur = Get-DnsBlockInConfig
    if ($null -eq $cur) { return 'unknown' }
    $sig = Get-DnsSchemeSignature $cur
    foreach ($s in @('on', 'off')) {
        try {
            if ((Get-DnsSchemeSignature (Get-DnsSchemeBlock $s)) -eq $sig) { return $s }
        } catch { }
    }
    return 'unknown'
}

# ---------- tun.strict-route ----------
# 只认顶层 tun: 段里的那一行；dns: 段里没有这个字段，不要写错位置。

function Get-StrictRouteDisk {
    $inTun = $false
    foreach ($ln in ((Read-ConfigText) -split "`r`n|`n")) {
        if (-not $inTun) {
            if ($ln -match '^tun:\s*$') { $inTun = $true }
            continue
        }
        if ($ln.Trim() -ne '' -and $ln -notmatch '^[ \t]') { break }   # 离开 tun 段
        $m = [regex]::Match($ln, '^[ \t]*strict-route:\s*(\w+)')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

function Set-StrictRouteInText([string]$Text, [bool]$Value) {
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text -split "`r`n|`n"
    $inTun = $false
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if (-not $inTun) {
            if ($ln -match '^tun:\s*$') { $inTun = $true }
            continue
        }
        if ($ln.Trim() -ne '' -and $ln -notmatch '^[ \t]') { break }   # 离开 tun 段
        $m = [regex]::Match($ln, '^([ \t]*)strict-route:\s*\S+(.*)$')
        if ($m.Success) {
            $want = if ($Value) { 'true' } else { 'false' }
            $lines[$i] = $m.Groups[1].Value + 'strict-route: ' + $want + $m.Groups[2].Value
            $done = $true
            break
        }
    }
    if (-not $done) {
        throw 'config.yaml 的 tun: 段里找不到 strict-route 这一行，请先手动补上（例如 strict-route: false）'
    }
    return ($lines -join $nl)
}

# 内核运行时的值（配置只有重启才装载，所以要单独读一次运行时状态）
#
# 注意内核的 JSON 用了 omitempty：strict-route / enable 为 false 时字段会整个消失。
# 所以「tun 段在、字段不在」= false，不能当成「读不到」——否则关闭状态会被误判成未生效。
function Get-TunRuntimeBool([string]$Key) {
    try {
        $c = Invoke-Api '/configs' -TimeoutSec 4
        if ($null -eq $c.tun) { return $null }
        $p = $c.tun.PSObject.Properties[$Key]
        if ($p) { return [bool]$p.Value }
        return $false          # 段在、键不在 → 值就是 false
    } catch { }
    return $null
}

function Get-StrictRouteRuntime { return Get-TunRuntimeBool 'strict-route' }
function Get-TunEnableRuntime   { return Get-TunRuntimeBool 'enable' }

# 回答 API 的是不是「本套件的那个内核」？
# 端口固定（9097 / 7897）时，别的代理软件（Clash Verge / Clash Party 等）可能先占住端口，
# 于是 API 由另一个实例回答，此时读到的 strict-route / TUN 状态与我们的配置无关。
# 用 tun.device 与 mixed-port 做指纹比对，不一致就说明认错了内核。
function Get-TunDeviceDisk {
    $inTun = $false
    foreach ($ln in ((Read-ConfigText) -split "`r`n|`n")) {
        if (-not $inTun) {
            if ($ln -match '^tun:\s*$') { $inTun = $true }
            continue
        }
        if ($ln.Trim() -ne '' -and $ln -notmatch '^[ \t]') { break }
        $m = [regex]::Match($ln, '^[ \t]*device:\s*(\S+)')
        if ($m.Success) { return $m.Groups[1].Value.Trim('"') }
    }
    return $null
}

function Get-TunStackDisk {
    $inTun = $false
    foreach ($ln in ((Read-ConfigText) -split "`r`n|`n")) {
        if (-not $inTun) {
            if ($ln -match '^tun:\s*$') { $inTun = $true }
            continue
        }
        if ($ln.Trim() -ne '' -and $ln -notmatch '^[ \t]') { break }
        $m = [regex]::Match($ln, '^[ \t]*stack:\s*(\S+)')
        if ($m.Success) { return $m.Groups[1].Value.Trim('"').ToLowerInvariant() }
    }
    return $null
}

function Get-ApiInstanceMismatch {
    $bad = @()
    try { $c = Invoke-Api '/configs' -TimeoutSec 4 } catch { return @('内核 API 无响应') }

    $wantDevice = Get-TunDeviceDisk
    if ($wantDevice -and $null -ne $c.tun) {
        $p = $c.tun.PSObject.Properties['device']
        if ($p -and $p.Value -and ($p.Value -ne $wantDevice)) {
            $bad += ("回答 API 的内核 TUN 设备是「{0}」，本套件配置里是「{1}」——很可能有另一个代理软件占着 9097 端口" -f $p.Value, $wantDevice)
        }
    }
    $wantPort = Get-ConfigValue 'mixed-port' ''
    if ($wantPort -and ($null -ne $c.'mixed-port') -and ("$($c.'mixed-port')" -ne $wantPort)) {
        $bad += ("回答 API 的内核 mixed-port 是 {0}，本套件配置里是 {1}" -f $c.'mixed-port', $wantPort)
    }
    # stack 不一致 = 运行中的内核没有装载这份 config.yaml（可能另一个实例先起了）
    $wantStack = Get-TunStackDisk
    if ($wantStack -and $null -ne $c.tun) {
        $p = $c.tun.PSObject.Properties['stack']
        if ($p -and $p.Value -and ($p.Value.ToString().ToLowerInvariant() -ne $wantStack)) {
            $bad += ("回答 API 的内核 TUN stack 是「{0}」，本套件配置里是「{1}」——运行中的内核没有装载这份配置" -f $p.Value, $wantStack)
        }
    }
    return $bad
}

# ---------- 系统 / 应用层的 DNS 泄露面 ----------
# 内核只能约束「发到 53 端口的明文 DNS」和「系统解析器」。
# 网卡上直接配置的 DNS、Windows 自带的加密 DNS(DoH)、应用自带的 DoH/DoT 都可能绕过内核。
# 这里只做只读检查并把结果报出来，不替用户改系统设置。

$MainlandDnsMarkers = @(
    '223.5.5.5', '223.6.6.6',              # 阿里
    '119.29.29.29', '119.28.28.28',        # DNSPod
    '1.12.12.12', '120.53.53.53',          # DNSPod / DNSPod 备用
    '114.114.114.114', '114.114.115.115',  # 114DNS
    '180.76.76.76',                        # 百度
    '2400:3200::1', '2400:3200:baba::1',   # 阿里 IPv6
    '240e:4c:4008::1', '240e:4c:4808::1'   # 电信 IPv6
)

function Get-InterfaceDnsReport {
    $rows = @()
    try {
        foreach ($a in (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            $addrs = @($a.ServerAddresses | Where-Object { $_ -and $_ -ne '127.0.0.1' -and $_ -ne '0.0.0.0' })
            if ($addrs.Count -eq 0) { continue }
            $rows += [pscustomobject]@{
                Alias    = $a.InterfaceAlias
                Servers  = $addrs
                Mainland = @($addrs | Where-Object { $MainlandDnsMarkers -contains $_ })
            }
        }
    } catch { }
    return $rows
}

function Get-SystemDohReport {
    $doh = @()
    try {
        foreach ($d in (Get-DnsClientDohServerAddress -ErrorAction Stop)) {
            if ($d.AutoUpgrade -or $d.DohTemplate) { $doh += $d }
        }
    } catch { }
    return $doh
}

# 只有「真的在用」的加密 DNS 才算泄露面：
#   · AutoUpgrade = true（系统会把明文查询自动升级成 DoH）
#   · 或该 DoH 服务器地址就配在某个网卡上
# 只是登记在 Windows 已知列表里、又没配到网卡上的模板不算问题（每台机器都有这份默认清单）。
function Get-ActiveSystemDoh {
    $used = @{}
    foreach ($r in (Get-InterfaceDnsReport)) {
        foreach ($s in $r.Servers) { $used[$s] = $true }
    }
    $active = @()
    foreach ($d in (Get-SystemDohReport)) {
        if ($d.AutoUpgrade -or $used.ContainsKey($d.ServerAddress)) { $active += $d }
    }
    return $active
}

# 判断某个 IPv4 地址是否落在 tun.route-exclude-address 里（这些网段不进 TUN）
function Test-IpInRouteExclude([string]$Ip) {
    $ipAddr = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$ipAddr)) { return $false }
    $bytes = $ipAddr.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    $v = [uint32](([uint32]$bytes[0] -shl 24) + ([uint32]$bytes[1] -shl 16) + ([uint32]$bytes[2] -shl 8) + [uint32]$bytes[3])

    $inExcl = $false
    foreach ($ln in ((Read-ConfigText) -split "`r`n|`n")) {
        if (-not $inExcl) {
            if ($ln -match 'route-exclude-address:') { $inExcl = $true }
            continue
        }
        if ($ln.Trim() -eq '') { continue }
        $m = [regex]::Match($ln, '^\s*-\s*(\d+\.\d+\.\d+\.\d+)/(\d+)')
        if (-not $m.Success) { break }   # 离开 route-exclude-address 列表
        $net = [Net.IPAddress]::Parse($m.Groups[1].Value).GetAddressBytes()
        $bits = [int]$m.Groups[2].Value
        $netV = [uint32](([uint32]$net[0] -shl 24) + ([uint32]$net[1] -shl 16) + ([uint32]$net[2] -shl 8) + [uint32]$net[3])
        $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32](([uint32]::MaxValue -shr (32 - $bits)) -shl (32 - $bits)) }
        if (($v -band $mask) -eq ($netV -band $mask)) { return $true }
    }
    return $false
}

# 返回需要用户处理的条目（每条一句人话）
function Get-DnsLeakSurface {
    $issues = @()

    foreach ($r in (Get-InterfaceDnsReport)) {
        if ($r.Mainland.Count -gt 0) {
            $excluded = @($r.Mainland | Where-Object { Test-IpInRouteExclude $_ })
            $where = if ($excluded.Count -gt 0) { '这些地址落在 tun.route-exclude-address 覆盖的网段里，TUN 不会接管它们，可以直接被使用' }
                     else { 'TUN 开启时这些 53 端口查询会被 dns-hijack 截获，但 TUN 关闭后会直接生效' }
            $issues += ("网卡「{0}」上配置的是大陆 DNS：{1}。{2}。" -f $r.Alias, ($r.Mainland -join ', '), $where)
        }
    }

    $doh = Get-ActiveSystemDoh
    if ($doh.Count -gt 0) {
        $tpl = @($doh | ForEach-Object { $_.DohTemplate } | Select-Object -Unique)
        $issues += ("Windows 正在使用 {0} 个加密 DNS(DoH) 地址（{1}）。加密 DNS 走 443，dns-hijack 与 strict-route 都拦不住，必须由系统/应用侧关闭。" -f $doh.Count, (($tpl | Select-Object -First 3) -join '; '))
    }

    return $issues
}

# 磁盘内容 vs 运行时状态的综合结论
function Get-DnsOverrideStatus {
    $scheme = Get-DnsOverride
    $disk = Get-StrictRouteDisk
    $rtStrict = Get-StrictRouteRuntime
    $rtTun = Get-TunEnableRuntime
    $mismatch = Get-ApiInstanceMismatch
    $wantStrict = ($scheme -eq 'on')

    $applied = $false
    if ($scheme -in @('on', 'off') -and $null -ne $rtStrict -and $null -ne $rtTun -and $mismatch.Count -eq 0) {
        $applied = ($rtTun -eq $true) -and ($rtStrict -eq $wantStrict)
    }
    $diskOk = ($null -ne $disk) -and ($disk -eq $wantStrict.ToString().ToLowerInvariant())

    return [pscustomobject]@{
        Scheme             = $scheme
        WantStrictRoute    = $wantStrict
        DiskStrictRoute    = $disk
        DiskMatches        = $diskOk
        RuntimeStrictRoute = $rtStrict
        RuntimeTunEnable   = $rtTun
        ApiMismatch        = $mismatch
        Applied            = $applied
    }
}

# 把 config\dns\<State>.yaml 的 dns: 段与 tun.strict-route 一起写进 config.yaml
function Set-DnsOverride([string]$State) {
    if ($State -notin @('on', 'off')) { throw "未知的 DNS 覆写状态：$State" }
    $block = Get-DnsSchemeBlock $State

    $text = Read-ConfigText
    $pattern = '(?s)' + [regex]::Escape($DnsMarkerBegin) + '.*?' + [regex]::Escape($DnsMarkerEnd)
    if (-not [regex]::IsMatch($text, $pattern)) {
        throw "config.yaml 里缺少 DNS 标记（$DnsMarkerBegin … $DnsMarkerEnd），请从备份恢复"
    }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $block = $block -replace "`r`n", "`n"
    if ($nl -eq "`r`n") { $block = $block -replace "`n", "`r`n" }
    $replacement = $DnsMarkerBegin + $nl + $block + $DnsMarkerEnd

    $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
    $text = Set-StrictRouteInText $text ($State -eq 'on')
    Write-ConfigText $text
}

# ---------- API ----------
function Invoke-Api {
    param([string]$Path, [string]$Method = 'GET', [int]$TimeoutSec = 3, $Body = $null)
    $headers = @{ Authorization = 'Bearer ' + (Get-ApiSecret) }
    $p = @{
        Uri = (Get-ApiBase) + $Path
        Headers = $headers
        Method = $Method
        TimeoutSec = $TimeoutSec
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $p['Body'] = ($Body | ConvertTo-Json -Compress -Depth 10)
        $p['ContentType'] = 'application/json'
    }
    return Invoke-RestMethod @p
}

# 只判断内核 API 是否可达（不抛异常）
function Test-ApiAlive {
    try { return [bool](Invoke-Api '/version' -TimeoutSec 3).version } catch { return $false }
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

# ---------- 残留（僵尸）内核 ----------
# mihomo 支持「自己重新拉起自己」：内核重启时会先派生出新进程，再退出旧的。
# 如果这时 WinSW 也判定子进程退出并重启服务，就会留下一个孤儿内核：
# 它由 SYSTEM 启动、父进程已经死掉，却仍占着 mixed-port / external-controller 端口和 TUN 适配器。
# 服务随后启动的内核于是 bind 失败、也建不出 TUN 适配器，看起来「服务在跑但完全不工作」。
# 这种孤儿只能靠占用端口来识别——它的 Path 读不到（SYSTEM 进程），所以不能按路径匹配。

function Get-ConfigPorts {
    $ports = @()
    $mp = Get-ConfigValue 'mixed-port' ''
    if ($mp -match '^\d+$') { $ports += [int]$mp }
    $ec = Get-ConfigValue 'external-controller' ''
    if ($ec -match ':(\d+)\s*$') { $ports += [int]$Matches[1] }
    return $ports
}

# 谁在监听这些端口（返回 pid + 进程名；读不到进程名时为 '?'）
function Get-PortOwners([int[]]$Ports) {
    $found = @()
    $seen = @{}
    try {
        foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            if ($Ports -notcontains [int]$c.LocalPort) { continue }
            $key = "$($c.LocalPort)/$($c.OwningProcess)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            $found += [pscustomobject]@{
                Port = [int]$c.LocalPort
                Pid  = [int]$c.OwningProcess
                Name = if ($p) { $p.ProcessName } else { '?' }
            }
        }
    } catch {
        # 退化路径：解析 netstat（老系统或 WMI 受限时）
        $r = Invoke-Native 'netstat.exe' @('-ano')
        foreach ($line in $r.Output) {
            $m = [regex]::Match($line, '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$')
            if (-not $m.Success) { continue }
            $port = [int]$m.Groups[1].Value
            if ($Ports -notcontains $port) { continue }
            $pid2 = [int]$m.Groups[2].Value
            $key = "$port/$pid2"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $p = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
            $found += [pscustomobject]@{
                Port = $port
                Pid  = $pid2
                Name = if ($p) { $p.ProcessName } else { '?' }
            }
        }
    }
    return $found
}

# 我们服务当前管着的内核 pid（WinSW 的子进程）
function Get-ServiceKernelPids {
    $pids = @()
    try {
        $svcProc = Get-CimInstance Win32_Process -Filter "Name='mihomo-service.exe'" -ErrorAction Stop
        foreach ($sp in $svcProc) {
            foreach ($c in (Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $sp.ProcessId) -ErrorAction Stop)) {
                $pids += [int]$c.ProcessId
            }
        }
    } catch { }
    return $pids
}

# 占用本套件端口的进程分两类，处理方式完全不同：
#   stray    = 名字像 mihomo 的内核，但不是当前服务的子进程 → 本套件的残留内核，可以结束
#   conflict = 别的代理软件（Clash Party / Verge 等）占了同一个端口 → 只能报告，绝不代用户杀
function Get-PortOccupancy {
    $ports = Get-ConfigPorts
    if ($ports.Count -eq 0) { return [pscustomobject]@{ Strays = @(); Conflicts = @() } }

    $managed = Get-ServiceKernelPids
    $strays = @()
    $conflicts = @()
    foreach ($o in (Get-PortOwners $ports)) {
        if ($managed -contains $o.Pid) { continue }
        if ($o.Name -like 'mihomo*') {
            $strays += [pscustomobject]@{ Pid = $o.Pid; Name = $o.Name; Port = $o.Port }
        } else {
            $conflicts += [pscustomobject]@{ Pid = $o.Pid; Name = $o.Name; Port = $o.Port }
        }
    }
    return [pscustomobject]@{ Strays = $strays; Conflicts = $conflicts }
}

function Get-StrayMihomoProcesses { return (Get-PortOccupancy).Strays }

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

    # 兜底一：按可执行文件路径清理残留（能读到 Path 的情况）
    Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $MihomoExe } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue

    # 兜底二：按端口占用清理孤儿内核。
    # 上面那条按 Path 匹配对 SYSTEM 进程无效（Path 读不到），所以必须再按端口找一次，
    # 否则孤儿会一直占着端口，服务重启后新内核 bind 不上，表现为「服务在跑却完全不通」。
    # 只结束名字像 mihomo 的进程；别的代理软件占了端口只报告，绝不代用户杀。
    $occ = Get-PortOccupancy
    foreach ($s in $occ.Strays) {
        try {
            Stop-Process -Id $s.Pid -Force -ErrorAction Stop
            Write-Host ("  [OK]   已清理残留内核：pid {0}（{1}，占用端口 {2}）" -f $s.Pid, $s.Name, $s.Port) -ForegroundColor Green
        } catch {
            Write-Host ("  [失败] 清理不了残留内核 pid {0}（{1}，占用端口 {2}）：{3}" -f `
                $s.Pid, $s.Name, $s.Port, $_.Exception.Message) -ForegroundColor Red
            Write-Host '         它由 SYSTEM 启动，需要用管理员权限运行 clean-stray.cmd' -ForegroundColor Yellow
        }
    }
    foreach ($c in $occ.Conflicts) {
        Write-Host ("  [注意] 端口 {0} 被「{1}」(pid {2}) 占用——这是别的代理软件，不是本套件的残留内核" -f `
            $c.Port, $c.Name, $c.Pid) -ForegroundColor Yellow
        Write-Host '         请自行退出它；本套件不会替你结束其他程序' -ForegroundColor Yellow
    }
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
