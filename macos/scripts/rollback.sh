#!/bin/bash
# 退回“已知可用”版本（mark-good.command 保存的那一份）并重启。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log rollback

[ -f "$LAST_GOOD_DIR/config.yaml" ] || die '还没有“已知可用”版本（验收通过后运行 mark-good.command 才会有）'

title '1/3 存档当前配置'
snap="$HISTORY_DIR/before-rollback-$(date +%Y%m%d-%H%M%S)"
save_snapshot "$snap"
ok "$snap"

title '2/3 恢复已知可用版本'
restore_snapshot "$LAST_GOOD_DIR"
if [ -f "$LAST_GOOD_DIR/marked-at.txt" ]; then ok "已恢复（该版本标记于 $(cat "$LAST_GOOD_DIR/marked-at.txt")）"
else ok '已恢复'; fi

title '3/3 重启'
stop_service
start_service
if ver="$(wait_api 30)"; then
    save_snapshot "$APPLIED_DIR"
    ok "内核已就绪：$ver"
else
    fail '恢复后内核仍无法启动，请运行 rescue.command 恢复直连'
    show_recent_log 20
    exit 1
fi
