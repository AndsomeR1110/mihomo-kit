#!/bin/bash
# mihomo 菜单栏管家：编译 MihomoBar.app → 授予免密启停 → 登录自启 → 启动
#   bash build.sh               编译 + 部署（可重复运行，用于升级）
#   bash build.sh --uninstall   卸载：菜单栏图标、登录自启、免密授权（内核不受影响）
#   --no-sudoers                不写免密授权（每次启停弹系统密码框）
#   --no-pause                  结束时不等回车
# shellcheck source=../scripts/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../scripts/common.sh"

UNINSTALL=0; NO_SUDOERS=0
for a in "$@"; do
    case "$a" in --uninstall) UNINSTALL=1 ;; --no-sudoers) NO_SUDOERS=1 ;; --no-pause) NO_PAUSE=1 ;; esac
done

MENU_DIR="$MAC_DIR/menubar"
APP="$MENU_DIR/MihomoBar.app"
BUILD_DIR="$MENU_DIR/build"
AGENT_LABEL='com.mihomo-kit.menubar'
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
# 免密只放行这三条固定命令（不含任何套件内的路径）
SUDO_CMDS="/bin/launchctl enable system/$LABEL
/bin/launchctl bootstrap system $PLIST
/bin/launchctl bootout system/$LABEL"

start_run_log menubar

if is_root; then die '请不要用 sudo 运行：菜单栏图标装在当前用户下，需要密码时脚本会自己问'; fi

stop_old() {
    launchctl bootout "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1
    pkill -x MihomoBar 2>/dev/null
    sleep 0.5
}

sudoers_ok() {
    local c
    while IFS= read -r c; do
        # shellcheck disable=SC2086  # 故意按空格拆成命令与参数
        /usr/bin/sudo -n -l $c >/dev/null 2>&1 || return 1
    done <<LIST
$SUDO_CMDS
LIST
}

# ── 卸载 ─────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
    title '卸载菜单栏图标'
    stop_old
    rm -f "$AGENT_PLIST"
    rm -rf "$APP" "$BUILD_DIR"
    ok '已移除菜单栏图标与登录自启'
    if [ -e "$SUDOERS_FILE" ]; then
        info '撤销免密启停授权需要管理员权限：请输入本机登录密码（输入时不显示）'
        if /usr/bin/sudo rm -f "$SUDOERS_FILE"; then ok '已撤销免密启停授权'
        else warn "没能删除 ${SUDOERS_FILE}，可稍后手动删除"; fi
    fi
    info '内核守护进程不受影响；需要时用 stop.command / uninstall-service.command'
    exit 0
fi

title '1/5 检查环境'
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${major:-0}" -ge 12 ] || die "需要 macOS 12 或更新版本（当前 $(sw_vers -productVersion)）"
check_kit_path
[ -f "$CONFIG_FILE" ] || die "找不到 ${CONFIG_FILE}，请确认 macos 文件夹在套件根目录下"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    fail '没有找到 Swift 编译器（Xcode 命令行工具）'
    info '系统会弹出安装窗口（几百 MB），装完后重新双击 menubar/install.command 即可。'
    info '不想装也没关系：菜单栏图标是可选的，status.command / start.command 等照常可用。'
    xcode-select --install >/dev/null 2>&1
    exit 1
fi
ok "macOS $(sw_vers -productVersion)，$(xcrun swiftc --version 2>/dev/null | head -n 1)"
service_registered || warn '内核守护进程还没安装（先运行 install.command）；菜单栏图标会显示“未安装”'

title '2/5 编译'
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then ARCH='arm64'; else ARCH='x86_64'; fi
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/MihomoBar.app/Contents/MacOS" "$BUILD_DIR/MihomoBar.app/Contents/Resources"
# 先编译到 build/，失败不影响正在运行的旧版
if ! xcrun swiftc -O -target "$ARCH-apple-macos12.0" -o "$BUILD_DIR/MihomoBar.app/Contents/MacOS/MihomoBar" \
        "$MENU_DIR/MihomoBar.swift"; then
    die '编译失败（正在运行的旧版不受影响）'
fi
sed "s|__KIT_ROOT__|$ROOT|g" "$MENU_DIR/Info.plist" > "$BUILD_DIR/MihomoBar.app/Contents/Info.plist"
plutil -lint -s "$BUILD_DIR/MihomoBar.app/Contents/Info.plist" || die 'Info.plist 格式不对'
sips -s format icns "$ROOT/panel-icon.ico" --out "$BUILD_DIR/MihomoBar.app/Contents/Resources/AppIcon.icns" \
    >/dev/null 2>&1 || warn '程序图标转换失败（不影响使用）'
codesign --force --sign - "$BUILD_DIR/MihomoBar.app" >/dev/null 2>&1 || warn '本机签名失败（一般不影响使用）'
ok "已编译（${ARCH}）"

title '3/5 免密启停授权'
if [ "$NO_SUDOERS" = 1 ]; then
    ok '已跳过（--no-sudoers）：启停时会弹系统密码框'
elif sudoers_ok; then
    ok '已授权，跳过'
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"; finish_run' EXIT
    u="$(id -un)"
    {
        echo "# mihomo-kit：允许 $u 不输密码启停 mihomo 内核守护进程（由 macos/menubar/build.sh 写入）"
        echo "# 只放行下面固定的 launchctl 命令；撤销：bash macos/menubar/build.sh --uninstall"
        printf 'Cmnd_Alias MIHOMO_KIT_CTL = %s\n' "$(printf '%s' "$SUDO_CMDS" | sed 's/:/\\:/g' | paste -sd ',' - | sed 's/,/, /g')"
        echo "$u ALL = (root) NOPASSWD: MIHOMO_KIT_CTL"
    } > "$TMP/sudoers"
    info '菜单栏启停免密需要写一次系统授权：请输入本机登录密码（输入时不显示）'
    if /usr/bin/sudo /usr/sbin/visudo -cf "$TMP/sudoers" >/dev/null &&
       /usr/bin/sudo mkdir -p /etc/sudoers.d &&
       /usr/bin/sudo install -m 0440 -o root -g wheel "$TMP/sudoers" "$SUDOERS_FILE" &&
       sudoers_ok; then
        ok "已授权（${SUDOERS_FILE}）"
    else
        /usr/bin/sudo rm -f "$SUDOERS_FILE" 2>/dev/null
        warn '授权没有成功：菜单栏仍可用，启停时会弹系统密码框'
    fi
fi

title '4/5 部署'
stop_old
rm -rf "$APP"
mv "$BUILD_DIR/MihomoBar.app" "$APP" || die "无法写入 $APP"
rm -rf "$BUILD_DIR"
mkdir -p "$(dirname "$AGENT_PLIST")"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/MihomoBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST
plutil -lint -s "$AGENT_PLIST" || die '登录自启配置格式不对'
ok "$APP"
ok "登录自启：$AGENT_PLIST"

title '5/5 启动'
if launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null || open "$APP"; then
    ok '菜单栏右上角出现小环图标即成功：点击展开菜单，⌥ + 点击直接打开面板'
else
    die "启动失败，可手动双击 $APP"
fi
