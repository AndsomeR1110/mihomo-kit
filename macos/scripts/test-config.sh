#!/bin/bash
# 检查配置：占位符、证书指纹格式、mihomo -t 语法校验。不需要管理员权限，不影响正在运行的内核。
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
start_run_log test-config

title '检查配置'
[ -x "$MIHOMO_BIN" ] || die '找不到 bin/mihomo，请先运行 prepare.command'
if test_mihomo_config; then
    print_test_output
    ok '配置检查通过'
else
    print_test_output
    die '配置检查未通过，未做任何改动'
fi
