#!/bin/bash
# 停止 mihomo 守护进程，恢复直连。下次开机仍会自动启动（如不想自启，用 rescue.command）。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log stop

title '停止'
stop_service
if service_loaded || [ -n "$(core_pids)" ]; then die '内核没有停下来，请运行 rescue.command'; fi
ok '已停止，现在是直连状态。'
info '重新开启：start.command；临时改用 Clash Verge：直接打开它并开启系统代理'
