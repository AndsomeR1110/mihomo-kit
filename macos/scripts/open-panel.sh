#!/bin/bash
# 用默认浏览器打开 mihomo 面板（自动带上密钥，免手动登录）
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
NO_PAUSE=1   # 成功时直接关窗口；失败才停下来给人看
start_run_log open-panel

secret="$(api_secret)"
case "$secret" in ''|__*) NO_PAUSE=0; die 'config.yaml 里没有 secret，请先运行 prepare.command' ;; esac
open "$(panel_url)" || { NO_PAUSE=0; die '打开浏览器失败'; }
ok '已在默认浏览器打开面板'
