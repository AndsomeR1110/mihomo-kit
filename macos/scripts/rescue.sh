#!/bin/bash
# 恢复联网（面板打不开、网络全断时用）
# 停止 mihomo 并取消开机自启、关闭残留的系统代理、刷新 DNS，然后测试直连。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
for a in "$@"; do [ "$a" = --no-pause ] && NO_PAUSE=1; done
require_root "$@"
start_run_log rescue

title '1/4 停止 mihomo'
if service_registered || service_loaded; then
    stop_service
    disable_service
    ok '已停止，并取消开机自启（重启电脑也不会自动开启；start.command 会恢复自启）'
else
    stop_service
    ok '守护进程未注册，跳过'
fi

title '2/4 关闭残留系统代理'
if disable_local_system_proxy; then ok '已关闭指向本机的系统代理'; else ok '没有指向本机的系统代理'; fi

title '3/4 刷新 DNS 缓存'
flush_dns
ok '完成'

title '4/4 测试直连'
probe 'https://www.baidu.com' '' 8
if [ "$PROBE_CODE" = 200 ]; then
    ok '直连正常（百度可访问）'
else
    warn "直连仍不通（HTTP ${PROBE_CODE}）。可能需要重新登录校园网，或检查 Wi-Fi 本身"
    info '如果之前关闭过 IPv6，也可以双击 system-tweaks-revert.command 排除 IPv6 设置的影响'
fi
echo ''
info '下一步：排查后用 start.command 恢复代理；或打开 Clash Verge 并开启系统代理临时替代'
