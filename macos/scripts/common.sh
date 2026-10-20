# shellcheck shell=bash
# shellcheck disable=SC2034  # 本文件是函数库，变量由 source 它的脚本使用
# 公共定义与函数（macOS 版）。所有脚本都先 source 本文件。
# 只用 macOS 自带的 bash 3.2 与系统命令（curl、launchctl、networksetup、osascript），不需要装任何东西。
# 与 Windows 版 scripts/common.ps1 一一对应；本文件及所有 .sh 保存为 UTF-8（无 BOM）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
ROOT="$(dirname "$MAC_DIR")"
BIN_DIR="$ROOT/bin"
CONF_DIR="$ROOT/config"
PRIV_DIR="$CONF_DIR/private"
LOG_DIR="$ROOT/logs"
SCRIPT_LOG_DIR="$LOG_DIR/scripts"
BACKUP_DIR="$ROOT/backup"
APPLIED_DIR="$BACKUP_DIR/applied"
LAST_GOOD_DIR="$BACKUP_DIR/last-good"
HISTORY_DIR="$BACKUP_DIR/history"
MIHOMO_BIN="$BIN_DIR/mihomo"
CONFIG_FILE="$CONF_DIR/config.yaml"
CORE_LOG="$LOG_DIR/mihomo.out.log"

# launchd 系统守护进程（相当于 Windows 服务）与日志滚动任务
LABEL='com.mihomo-kit.mihomo'
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ROTATE_LABEL='com.mihomo-kit.logrotate'
ROTATE_PLIST="/Library/LaunchDaemons/$ROTATE_LABEL.plist"
# 菜单栏免密启停授权（menubar/build.sh 写入，uninstall-service 一并删除）
SUDOERS_FILE='/etc/sudoers.d/mihomo-kit'

# 需要一起备份/回滚的文件（相对 config 目录）
MANAGED_FILES='config.yaml private/nodes.yaml private/infra-direct.yaml'

# 出口实测地址
PROBE_DIRECT='https://myip.ipip.net'                     # 国内直连，返回本机直连 IP
PROBE_DEFAULT='https://www.cloudflare.com/cdn-cgi/trace'  # 走“默认出口”
PROBE_AI='https://claude.ai/cdn-cgi/trace'                # 走“美国组”
PROBE_204='https://www.gstatic.com/generate_204'

NO_PAUSE=0
RUN_LOG_ON=0

# ---------- 输出 ----------
if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi
title() { printf '\n%s== %s%s\n' "$C_CYAN" "$1" "$C_RESET"; }
ok()    { printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()  { printf '  %s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail()  { printf '  %s[失败]%s %s\n' "$C_RED" "$C_RESET" "$1"; }
info()  { printf '  %s\n' "$1"; }
die()   { fail "$1"; exit 1; }

# ---------- 权限与运行记录 ----------
is_root() { [ "$(id -u)" -eq 0 ]; }

# 非 root 时用 sudo 重新运行当前脚本（终端里输入一次开机密码），相当于 Windows 的 UAC 提权
require_root() {
    is_root && return 0
    printf '%s需要管理员权限：请输入本机登录密码（输入时不显示），然后回车%s\n' "$C_YELLOW" "$C_RESET"
    exec /usr/bin/sudo /bin/bash "$SCRIPT_DIR/$(basename "$0")" "$@"
}

# 实际登录用户（sudo 下取 SUDO_USER；直接以 root 运行时取套件目录的所有者）
real_user() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then echo "$SUDO_USER"; else stat -f %Su "$ROOT"; fi
}

real_home() {
    dscl . -read "/Users/$(real_user)" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# 以实际登录用户身份运行（root 下降权，避免产生 root 所有的文件）
run_as_user() {
    if is_root; then /usr/bin/sudo -u "$(real_user)" -H "$@"; else "$@"; fi
}

# root 运行后把套件内由脚本写出的文件交还给用户，否则之后不带 sudo 的脚本写不进去
fix_owner() {
    is_root || return 0
    local u rel
    u="$(real_user)"
    [ -n "$u" ] && [ "$u" != root ] || return 0
    [ -d "$LOG_DIR" ] && chown "$u" "$LOG_DIR" 2>/dev/null
    [ -d "$SCRIPT_LOG_DIR" ] && chown -R "$u" "$SCRIPT_LOG_DIR" 2>/dev/null
    [ -d "$BACKUP_DIR" ] && chown -R "$u" "$BACKUP_DIR" 2>/dev/null
    for rel in $MANAGED_FILES; do
        [ -f "$CONF_DIR/$rel" ] && chown "$u" "$CONF_DIR/$rel" 2>/dev/null
    done
    return 0
}

# 每次运行写一份记录到 logs/scripts/，方便 agent 或事后查看；退出时自动收尾
start_run_log() {
    trap finish_run EXIT
    mkdir -p "$SCRIPT_LOG_DIR" 2>/dev/null
    RUN_LOG="$SCRIPT_LOG_DIR/$1-$(date +%Y%m%d-%H%M%S).log"
    if touch "$RUN_LOG" 2>/dev/null; then
        exec 3>&1 4>&2
        exec > >(tee -a "$RUN_LOG") 2>&1
        RUN_LOG_ON=1
    fi
}

stop_run_log() {
    if [ "$RUN_LOG_ON" = 1 ]; then
        exec 1>&3 2>&4 3>&- 4>&-
        RUN_LOG_ON=0
        sleep 0.2   # 让 tee 把最后几行写完
    fi
}

wait_close() {
    if [ "$NO_PAUSE" != 1 ] && [ -t 0 ]; then
        echo ''
        read -r -p '按回车键关闭窗口' _
    fi
}

finish_run() {
    local rc=$?
    fix_owner
    stop_run_log
    wait_close
    exit "$rc"
}

# 套件路径检查：路径会写进 launchd plist / Info.plist，不能有空格和特殊字符；
# 桌面、文稿、下载、iCloud 目录受 macOS 隐私保护，root 守护进程读不到
check_kit_path() {
    local home
    case "$ROOT" in
        *[[:space:]]*) die "目录路径里有空格：$ROOT
  请把整个文件夹移到没有空格的路径（例如 ~/mihomo）后重试" ;;
        *[\'\"\\\$\`\&\<\>\|\;\*\?]*) die "目录路径里有特殊字符：${ROOT}（请改成纯英文路径，例如 ~/mihomo）" ;;
    esac
    home="$(real_home)"
    if [ -n "$home" ]; then
        case "$ROOT/" in
            "$home/Desktop/"*|"$home/Documents/"*|"$home/Downloads/"*|"$home/Library/Mobile Documents/"*)
                die "套件放在了受隐私保护的目录：$ROOT
  macOS 不允许后台服务读取「桌面 / 文稿 / 下载 / iCloud」里的文件，内核会起不来。
  请把整个文件夹移到 ~/mihomo（个人文件夹下）后重试" ;;
        esac
    fi
    case "$ROOT" in
        /Volumes/*) warn "套件在外置磁盘上：开机时磁盘没挂载会导致内核起不来，建议放到 ~/mihomo" ;;
    esac
    if printf '%s' "$ROOT" | LC_ALL=C grep -q '[^ -~]'; then
        warn "目录路径里有中文：${ROOT}（一般可用，遇到问题就改成纯英文路径）"
    fi
    return 0
}

# ---------- JSON / URL 编码（用系统自带的 JavaScript for Automation，无需 jq/python） ----------
JXA_SRC='function run(argv) {
  var expr = argv.shift();
  var r = (new Function("argv", "return (" + expr + ");"))(argv);
  return (r === undefined || r === null) ? "" : String(r);
}'
# 用法：jxa '<JS 表达式，参数为 argv[0..]>' 参数...
jxa() { osascript -l JavaScript -e "$JXA_SRC" "$@" 2>/dev/null; }
json_field() { jxa 'JSON.parse(argv[0])[argv[1]]' "$1" "$2"; }
urlencode()  { jxa 'encodeURIComponent(argv[0])' "$1"; }

# ---------- 读配置 ----------
config_value() {
    local line v
    line="$(grep -m 1 "^$1:" "$CONFIG_FILE" 2>/dev/null)"
    if [ -z "$line" ]; then echo "$2"; return; fi
    v="${line#*:}"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    v="${v#\"}"; v="${v%\"}"
    if [ -z "$v" ]; then echo "$2"; else echo "$v"; fi
}

api_base()   { echo "http://$(config_value external-controller 127.0.0.1:9097)"; }
api_port()   { local b; b="$(api_base)"; echo "${b##*:}"; }
api_secret() { config_value secret ''; }
mixed_port() { config_value mixed-port 7897; }
panel_url()  { echo "$(api_base)/ui/?hostname=127.0.0.1&port=$(api_port)&secret=$(api_secret)"; }

# ---------- API ----------
api_get() {
    curl -s --fail --noproxy '*' -m "${2:-3}" -H "Authorization: Bearer $(api_secret)" "$(api_base)$1"
}

api_version() {
    local j
    j="$(api_get /version)" || return 1
    json_field "$j" version
}

wait_api() {
    local deadline v
    deadline=$(( $(date +%s) + ${1:-25} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        v="$(api_version)"
        if [ -n "$v" ]; then echo "$v"; return 0; fi
        sleep 0.8
    done
    return 1
}

group_now() {
    local j
    j="$(api_get "/proxies/$(urlencode "$1")")" || { echo '?'; return; }
    json_field "$j" now
}

# ---------- 出口实测 ----------
# 第二个参数为 mixed 时经 mixed-port 代理；否则走系统路由（即 TUN），和真实应用看到的一致
probe() {
    local out args
    args=(-s --max-time "${3:-10}" -w $'\n__HTTP__%{http_code}')
    if [ "$2" = mixed ]; then args+=(-x "http://127.0.0.1:$(mixed_port)"); else args+=(--noproxy '*'); fi
    out="$(curl "${args[@]}" "$1" 2>/dev/null)"
    case "$out" in
        *__HTTP__*) PROBE_CODE="${out##*__HTTP__}"; PROBE_BODY="${out%__HTTP__*}" ;;
        *) PROBE_CODE='000'; PROBE_BODY="$out" ;;
    esac
    PROBE_BODY="$(printf '%s' "$PROBE_BODY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

trace() {
    probe "$1" "$2"
    TRACE_CODE="$PROBE_CODE"
    TRACE_IP="$(printf '%s\n' "$PROBE_BODY" | sed -n 's/^ip=//p' | head -n 1)"
    TRACE_LOC="$(printf '%s\n' "$PROBE_BODY" | sed -n 's/^loc=//p' | head -n 1)"
}

test_egress() {
    probe "$PROBE_204" mixed
    [ "$PROBE_CODE" = 204 ]
}

# ---------- 服务（launchd） ----------
service_registered() { [ -f "$PLIST" ]; }
service_loaded()     { launchctl print "system/$LABEL" >/dev/null 2>&1; }

service_pid() {
    launchctl print "system/$LABEL" 2>/dev/null | awk -F' = ' '/^\tpid = /{print $2; exit}'
}

# missing / stopped / starting / running
service_state() {
    local s
    service_registered || { echo missing; return; }
    s="$(launchctl print "system/$LABEL" 2>/dev/null | awk -F' = ' '/^\tstate = /{print $2; exit}')"
    case "$s" in
        running) echo running ;;
        'spawn scheduled') echo starting ;;
        *) echo stopped ;;
    esac
}

# 开机自启是否开着（rescue 会关掉，start 会恢复）
service_autostart() {
    if launchctl print-disabled system 2>/dev/null | grep -Eq "\"$LABEL\" => (true|disabled)"; then
        echo '已关闭（rescue 后的状态，start 会恢复）'
    else
        echo '开机自启'
    fi
}

# 本套件 bin/mihomo 的进程（不会误伤 Clash Verge 自带的内核）
core_pids() {
    local pid
    for pid in $(pgrep -x mihomo 2>/dev/null); do
        [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "$MIHOMO_BIN" ] && echo "$pid"
    done
}

start_service() {
    launchctl enable "system/$LABEL"
    if service_loaded; then
        [ "$(service_state)" = running ] && return 0
        launchctl kickstart "system/$LABEL" >/dev/null 2>&1 && return 0
        launchctl bootout "system/$LABEL" >/dev/null 2>&1
        wait_unloaded 20
    fi
    launchctl bootstrap system "$PLIST"
}

wait_unloaded() {
    local i=0
    while service_loaded && [ "$i" -lt $(( ${1:-20} * 2 )) ]; do sleep 0.5; i=$((i + 1)); done
    ! service_loaded
}

stop_service() {
    local pids i
    if service_loaded; then
        launchctl bootout "system/$LABEL" >/dev/null 2>&1
        wait_unloaded 20
    fi
    # 兜底：守护进程卸了但内核进程残留时强制结束（只针对本目录下的 bin/mihomo）
    pids="$(core_pids)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        i=0
        while [ -n "$(core_pids)" ] && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
        pids="$(core_pids)"
        # shellcheck disable=SC2086
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    fi
    return 0
}

disable_service() { launchctl disable "system/$LABEL"; }

core_memory_mb() {
    local pid kb
    pid="$(service_pid)"
    [ -n "$pid" ] || pid="$(core_pids | head -n 1)"
    [ -n "$pid" ] || return 1
    kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$kb" ] || return 1
    awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1024 }'
}

# 其他代理软件（与本套件端口相同、TUN 互相抢路由，不能同时开）
conflict_app_running() {
    local n
    for n in clash-verge verge-mihomo verge-mihomo-alpha 'Clash Verge' ClashX 'ClashX Pro' 'ClashX Meta'; do
        if pgrep -x "$n" >/dev/null 2>&1; then echo "$n"; return 0; fi
    done
    return 1
}

port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ---------- 系统代理 / DNS ----------
list_network_services() {
    networksetup -listallnetworkservices 2>/dev/null | sed '1d' | grep -v '^\*'
}

# 关闭指向本机的系统代理（Clash Verge 等残留）。关掉了至少一个返回 0
disable_local_system_proxy() {
    local changed=1 svc kind out
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        for kind in webproxy securewebproxy socksfirewallproxy; do
            out="$(networksetup -get$kind "$svc" 2>/dev/null)"
            if printf '%s\n' "$out" | grep -q '^Enabled: Yes' &&
               printf '%s\n' "$out" | grep -Eq '^Server: (127\.0\.0\.1|localhost|::1)$'; then
                networksetup -set${kind}state "$svc" off && changed=0
            fi
        done
        out="$(networksetup -getautoproxyurl "$svc" 2>/dev/null)"
        if printf '%s\n' "$out" | grep -q '^Enabled: Yes' &&
           printf '%s\n' "$out" | grep -Eq '^URL: .*(127\.0\.0\.1|localhost)'; then
            networksetup -setautoproxystate "$svc" off && changed=0
        fi
    done <<EOF
$(list_network_services)
EOF
    return $changed
}

flush_dns() {
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    return 0
}

# ---------- 配置检查 ----------
list_placeholders() {
    local rel p m
    for rel in $MANAGED_FILES; do
        p="$CONF_DIR/$rel"
        if [ ! -f "$p" ]; then echo "缺少文件 config/$rel"; continue; fi
        for m in $(grep -oE '__[A-Z0-9_]+__' "$p" | sort -u); do
            echo "config/$rel 中仍有占位符 $m"
        done
    done
}

# mihomo -t 不检查 Hy2 证书指纹格式，这里补一道
list_fingerprint_problems() {
    local p="$PRIV_DIR/nodes.yaml" v hex
    [ -f "$p" ] || return 0
    grep -E '^[[:space:]]*fingerprint:' "$p" | while IFS= read -r v; do
        v="${v#*fingerprint:}"
        v="${v%%#*}"
        v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        v="${v#\"}"; v="${v%\"}"
        hex="$(printf '%s' "$v" | tr -d ':')"
        printf '%s' "$hex" | grep -Eq '^[0-9A-Fa-f]{64}$' || echo "证书指纹格式不对：$v"
    done
}

# 结果：返回码 0 = 通过；检查输出存入 TEST_OUTPUT
test_mihomo_config() {
    local problems
    problems="$(list_placeholders; list_fingerprint_problems)"
    if [ -n "$problems" ]; then TEST_OUTPUT="$problems"; return 1; fi
    if [ ! -x "$MIHOMO_BIN" ]; then TEST_OUTPUT='找不到 bin/mihomo，请先运行 prepare.command'; return 1; fi
    TEST_OUTPUT="$("$MIHOMO_BIN" -t -d "$CONF_DIR" 2>&1)"
    local rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$TEST_OUTPUT" | grep -q 'test is successful'
}

print_test_output() {
    printf '%s\n' "$TEST_OUTPUT" | tail -n "${1:-8}" | while IFS= read -r l; do info "$l"; done
}

# ---------- 快照 ----------
save_snapshot() {
    local rel
    for rel in $MANAGED_FILES; do
        if [ -f "$CONF_DIR/$rel" ]; then
            mkdir -p "$(dirname "$1/$rel")"
            cp -f "$CONF_DIR/$rel" "$1/$rel"
        fi
    done
}

restore_snapshot() {
    local rel
    for rel in $MANAGED_FILES; do
        if [ -f "$1/$rel" ]; then
            mkdir -p "$(dirname "$CONF_DIR/$rel")"
            cp -f "$1/$rel" "$CONF_DIR/$rel"
        fi
    done
}

# ---------- 日志 ----------
show_recent_log() {
    if [ ! -f "$CORE_LOG" ]; then info '（还没有内核日志）'; return; fi
    info "日志文件：$CORE_LOG"
    tail -n "${1:-30}" "$CORE_LOG" | sed 's/^/    /'
}
