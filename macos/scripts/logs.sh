#!/bin/bash
# 实时查看内核日志（Ctrl+C 退出）。不需要管理员权限。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
TAIL=50
[ "$1" = --tail ] && TAIL="$2"

if [ ! -f "$CORE_LOG" ]; then
    warn '还没有内核日志（守护进程可能从未启动过）'
    wait_close
    exit 1
fi
printf '%s正在跟踪 %s，按 Ctrl+C 退出%s\n' "$C_CYAN" "$CORE_LOG" "$C_RESET"
exec tail -n "$TAIL" -F "$CORE_LOG"
