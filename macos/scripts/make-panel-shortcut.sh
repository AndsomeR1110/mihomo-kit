#!/bin/bash
# 在桌面创建「mihomo 面板」快捷方式（.webloc 免密自动登录 + 套件自带图标）
# 面板密钥从 config.yaml 的 secret 读取；--dest 目录 供测试用
. "$(dirname "$0")/common.sh"
DEST=''
while [ $# -gt 0 ]; do
    case "$1" in --dest) DEST="$2"; shift ;; --no-pause) NO_PAUSE=1 ;; esac
    shift
done
start_run_log make-panel-shortcut

[ -n "$DEST" ] || DEST="$HOME/Desktop"
secret="$(api_secret)"
case "$secret" in ''|__*) die 'config.yaml 里没有 secret，请先运行 prepare.command' ;; esac
url="$(panel_url)"
lnk="$DEST/mihomo 面板.webloc"
xml_url="$(printf '%s' "$url" | sed 's/&/\&amp;/g')"
cat > "$lnk" <<PLIST || die "无法写入 $lnk"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>URL</key>
    <string>$xml_url</string>
</dict>
</plist>
PLIST
# 换上套件图标（NSImage 能直接读 .ico）；失败不影响使用
icon="$ROOT/panel-icon.ico"
if [ -f "$icon" ]; then
    jxa 'ObjC.import("AppKit");
         $.NSWorkspace.sharedWorkspace.setIconForFileOptions($.NSImage.alloc.initWithContentsOfFile(argv[0]), argv[1], 0)' \
        "$icon" "$lnk" >/dev/null || warn '自定义图标设置失败（不影响使用）'
else
    warn '没找到 panel-icon.ico，快捷方式将没有自定义图标'
fi
ok "已创建 $lnk"
info "双击即可免密进入面板（地址 $(api_base)/ui ）"
