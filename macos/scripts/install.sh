#!/bin/bash
# 一键安装：检查 → 下载补齐（prepare）→ 私有文件检查 → 询问快捷方式/系统调整
#           → 配置检查 → 注册并启动守护进程 → 创建桌面面板快捷方式
# 全程可重复运行（已完成的步骤自动跳过）。--dry-run 只检查和下载，不装守护进程。
#   --yes           无人值守：快捷方式=是、系统调整=否
#   --no-shortcut   无人值守也不要快捷方式
#   --apply-tweaks  无人值守也关闭 IPv6
#   --proxy URL     下载走指定代理，如 http://127.0.0.1:7890
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

YES=0; NO_SHORTCUT=0; APPLY_TWEAKS=0; DRY_RUN=0; PROXY=''
ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1 ;;
        --no-shortcut) NO_SHORTCUT=1 ;;
        --apply-tweaks) APPLY_TWEAKS=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --proxy) PROXY="$2"; shift ;;
        --no-pause) NO_PAUSE=1 ;;
    esac
    shift
done
require_root "${ARGS[@]}"
start_run_log install

title '1/7 安装位置检查'
check_kit_path
# 从浏览器下载的 ZIP 解压出来的文件带“隔离”标记，会被 Gatekeeper 拦下；用户既然决定安装，就统一解除
xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null
ok "$ROOT"

title '2/7 冲突检查'
if app="$(conflict_app_running)"; then
    die "检测到 $app 正在运行。请先在它里面关闭系统代理 / TUN，并从菜单栏彻底退出（两者不能同时用），然后重试"
fi
svc_running=0
if service_registered; then
    [ "$(service_state)" = running ] && svc_running=1
    ok "守护进程已存在（$(service_state)），本次将重新应用配置"
fi
taken=''
if [ "$svc_running" = 0 ]; then
    for p in "$(mixed_port)" "$(api_port)"; do
        port_listening "$p" && taken="$taken $p"
    done
fi
[ -z "$taken" ] || die "端口$taken 已被其他程序占用（常见于其他代理软件）。请先退出占用程序，或改 config.yaml 里的 mixed-port / external-controller 后重试"
ok '没有端口冲突'

title '3/7 下载补齐（已有文件自动跳过）'
prep_args=(--no-pause)
[ -n "$PROXY" ] && prep_args+=(--proxy "$PROXY")
run_as_user /bin/bash "$SCRIPT_DIR/prepare.sh" "${prep_args[@]}"
for f in "$MIHOMO_BIN" "$CONF_DIR/ui/index.html"; do
    [ -e "$f" ] || die "缺少 ${f}，下载没有完成。请检查网络后重试 install.command"
done
for n in private-domain anthropic ai cn-domain global-domain cn-ip; do
    [ -s "$CONF_DIR/ruleset/$n.mrs" ] || die "缺少 ruleset/$n.mrs，请重试 install.command"
done
ok '程序文件齐全'

title '4/7 私有文件检查'
ph="$(list_placeholders)"
if [ -n "$ph" ]; then
    printf '%s\n' "$ph" | while IFS= read -r l; do warn "$l"; done
    echo ''
    info '说明：节点信息没有就位。两种解决方式：'
    info '  A. 拿到分享者给的 nodes.yaml 和 infra-direct.yaml → 直接放进 config/private/ 覆盖'
    info '  B. 自建节点 → 按 config/private/nodes.example.yaml 顶部的说明填写'
    info '填好后重新运行 install.command（之前的进度都会保留）'
    die '私有文件未就绪'
fi
ok 'nodes.yaml / infra-direct.yaml 已就绪'

title '5/7 安装选项'
if [ "$NO_SHORTCUT" = 1 ]; then want_shortcut=0
elif [ "$YES" = 1 ]; then want_shortcut=1
else
    read -r -p '在桌面创建「mihomo 面板」快捷方式（免密自动登录）？[Y/n] ' ans
    case "$ans" in [nN]*) want_shortcut=0 ;; *) want_shortcut=1 ;; esac
fi
if [ "$APPLY_TWEAKS" = 1 ]; then want_tweaks=1
elif [ "$YES" = 1 ]; then want_tweaks=0
else
    read -r -p '关闭各网络服务的 IPv6，防止流量绕过代理（校园网建议 Y，随时可用 system-tweaks-revert 恢复）？[y/N] ' ans2
    case "$ans2" in [yY]*) want_tweaks=1 ;; *) want_tweaks=0 ;; esac
fi
yn() { if [ "$1" = 1 ]; then echo '是'; else echo '否'; fi; }
info "桌面快捷方式：$(yn "$want_shortcut")　系统调整：$(yn "$want_tweaks")"

if [ "$want_tweaks" = 1 ]; then
    title '6/7 系统调整'
    /bin/bash "$SCRIPT_DIR/system-tweaks.sh" --apply --no-pause
else
    title '6/7 系统调整（跳过）'
fi

title '7/7 配置检查与守护进程安装'
if ! test_mihomo_config; then
    print_test_output
    die '配置检查未通过'
fi
ok '配置检查通过'

if [ "$DRY_RUN" = 1 ]; then
    warn '--dry-run：到此为止，不注册守护进程、不改动网络'
    exit 0
fi

/bin/bash "$SCRIPT_DIR/install-service.sh" --no-pause

if [ "$(service_state)" != running ]; then
    die '守护进程没有运行起来。可运行 rescue.command 恢复直连，然后看日志排查（logs.command）'
fi
ok '守护进程运行中'
[ "$want_shortcut" = 1 ] && run_as_user /bin/bash "$SCRIPT_DIR/make-panel-shortcut.sh" --no-pause

echo ''
ok "安装完成。面板：$(api_base)/ui （桌面快捷方式免密直达，或双击 panel.command）"
info '建议：正常使用几天后双击 mark-good.command，把当前配置存为「已知可用」版本'
info '可选：双击 macos/menubar/install.command 安装菜单栏图标（一键启停、看出口，需要 Xcode 命令行工具）'
