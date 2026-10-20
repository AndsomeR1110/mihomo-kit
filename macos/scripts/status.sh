#!/bin/bash
# 查看状态：守护进程、内存、当前选择、节点延迟、三条出口实测、最近日志。不需要管理员权限。
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"
LOG_LINES=20
while [ $# -gt 0 ]; do
    case "$1" in --log-lines) LOG_LINES="$2"; shift ;; --no-pause) NO_PAUSE=1 ;; esac
    shift
done
start_run_log status

title '守护进程'
state="$(service_state)"
if [ "$state" = missing ]; then
    warn '守护进程未注册'
else
    case "$state" in running) st='Running' ;; starting) st='Starting' ;; *) st='Stopped' ;; esac
    mem="$(core_memory_mb)" && mem="$mem MB" || mem='-'
    info "状态：${st}　启动方式：$(service_autostart)　内核内存：$mem"
fi

title '内核'
if ver="$(api_version)" && [ -n "$ver" ]; then
    ok "运行中 ${ver}　面板：$(api_base)/ui"
    title '当前选择'
    def="$(group_now '默认出口')"
    def_node=''
    if [ "$def" = '香港组' ] || [ "$def" = '美国组' ]; then def_node=" → $(group_now "$def")"; fi
    info "默认出口 → $def$def_node"
    info "美国组（AI 专用） → $(group_now '美国组')"

    title '节点延迟（最近一次自动检测，0 表示不通）'
    if j="$(api_get /providers/proxies/nodes)"; then
        jxa 'JSON.parse(argv[0]).proxies.map(function (n) {
               var h = n.history || []; return n.name + "\t" + (h.length ? h[h.length - 1].delay : 0);
             }).join("\n")' "$j" |
        while IFS="$(printf '\t')" read -r name delay; do
            [ -n "$name" ] || continue
            line="$(printf '%-12s %5s ms' "$name" "$delay")"
            if [ "${delay:-0}" -gt 0 ] 2>/dev/null; then ok "$line"; else warn "$line"; fi
        done
    else
        warn '读取节点状态失败'
    fi
else
    warn '内核未运行或 API 无响应（现在可能是直连状态）'
fi

title '出口实测（经系统路由，与真实应用一致）'
probe "$PROBE_DIRECT"
if [ "$PROBE_CODE" = 200 ]; then info "国内直连：$(printf '%s' "$PROBE_BODY" | tr -s '[:space:]' ' ')"
else warn "国内直连：失败（HTTP ${PROBE_CODE}）"; fi
trace "$PROBE_DEFAULT"
if [ -n "$TRACE_IP" ]; then info "默认出口：ip=$TRACE_IP loc=$TRACE_LOC"
else warn "默认出口：失败（HTTP ${TRACE_CODE}）"; fi
trace "$PROBE_AI"
if [ "$TRACE_LOC" = US ]; then ok "AI 出口（claude.ai）：ip=$TRACE_IP loc=US"
elif [ -n "$TRACE_IP" ]; then fail "AI 出口（claude.ai）：ip=$TRACE_IP loc=${TRACE_LOC}，不是美国！"
else warn "AI 出口（claude.ai）：不通（HTTP ${TRACE_CODE}）。美国两个节点可能都不可用——按设计不会回落到香港"; fi

title "最近日志（$LOG_LINES 行）"
show_recent_log "$LOG_LINES"
