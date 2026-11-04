#!/bin/bash
# 把当前配置保存为“已知可用”版本（rollback.command 会退回到这里）。不需要管理员权限。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
start_run_log mark-good

title '保存为已知可用版本'
test_mihomo_config || die '当前配置检查未通过，不能标记为可用'
[ -n "$(api_version)" ] || die '内核没有运行，无法确认当前配置可用'
if [ -d "$LAST_GOOD_DIR" ]; then
    old="$HISTORY_DIR/last-good-before-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HISTORY_DIR"
    mv "$LAST_GOOD_DIR" "$old" || die "无法移动旧版本（$LAST_GOOD_DIR 的权限不对？）"
    info "旧的已知可用版本移到：$old"
fi
save_snapshot "$LAST_GOOD_DIR"
date +%Y-%m-%dT%H:%M:%S > "$LAST_GOOD_DIR/marked-at.txt"
ok "已保存到 $LAST_GOOD_DIR"
