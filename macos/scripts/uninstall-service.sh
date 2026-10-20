#!/bin/bash
# 停止并注销 mihomo 守护进程（文件保留）。彻底不用时再删除整个套件目录。
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log uninstall-service

title '注销守护进程'
if ! service_registered && ! service_loaded; then
    ok '守护进程本来就没有注册'
else
    stop_service
    rm -f "$PLIST"
    launchctl enable "system/$LABEL" 2>/dev/null   # 清掉 rescue 留下的禁用记录
    if service_loaded; then warn '守护进程仍显示已加载，重启电脑后会消失'
    else ok '守护进程已注销，现在是直连状态'; fi
fi
launchctl bootout "system/$ROTATE_LABEL" >/dev/null 2>&1
rm -f "$ROTATE_PLIST"
if [ -e "$SUDOERS_FILE" ]; then
    rm -f "$SUDOERS_FILE"
    ok '已撤销菜单栏的免密启停授权'
fi
info '菜单栏图标如果装过：双击 macos/menubar/uninstall.command 卸载'
info '如需恢复 IPv6：双击 system-tweaks-revert.command'
