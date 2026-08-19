#!/usr/bin/env bash
# stop.sh — start.sh가 켠 것을 전부 끈다.
#
#     ./stop.sh            워치독 + 백엔드 + 외부 접속 주소 + Ollama + Neo4j
#     ./stop.sh --백엔드만  백엔드와 접속 주소만 (Ollama·Neo4j는 남긴다)
#
# 워치독을 먼저 죽이지 않으면 15초 뒤에 런처가 다시 돌아 전부 되살아난다.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$ROOT/data/run"

BACKEND_ONLY=0
case "${1:-}" in --백엔드만|--backend-only) BACKEND_ONLY=1 ;; esac

# TERM 후 종료를 기다린다. Neo4j는 종료에 몇 초 걸리고, 중간에 KILL하면 DB가 깨진다.
wait_gone() {
    local pid="$1" secs="${2:-20}"
    for _ in $(seq 1 $((secs * 2))); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
    return 1
}

stop_pidfile() {
    local name="$1" file="$RUN_DIR/$2"
    if [ -f "$file" ] && kill -0 "$(cat "$file")" 2>/dev/null; then
        local pid; pid="$(cat "$file")"
        kill "$pid" 2>/dev/null
        wait_gone "$pid" && echo "  $name 종료" || echo "  $name 종료 안 됨 (PID $pid)"
    else
        echo "  $name 이미 꺼짐"
    fi
    rm -f "$file"
}

# Ollama·Neo4j는 pidfile을 안 남기므로 포트로 찾는다.
stop_port() {
    local name="$1" port="$2" secs="${3:-20}" pid
    pid="$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    if [ -z "$pid" ]; then
        echo "  $name 이미 꺼짐"
    elif kill "$pid" 2>/dev/null && wait_gone "$pid" "$secs"; then
        echo "  $name 종료 (PID $pid)"
    else
        echo "  $name 종료 안 됨 (PID $pid) — 직접 확인하세요"
    fi
}

# 워치독이 살아 있으면 나머지를 꺼도 곧바로 되살린다. 반드시 먼저.
if pkill -f 'backend_watchdog\.sh' 2>/dev/null; then
    sleep 2
    echo "  워치독 종료"
else
    echo "  워치독 이미 꺼짐"
fi

stop_pidfile "외부 접속 주소" cloudflared.pid
stop_pidfile "백엔드" backend.pid

if [ "$BACKEND_ONLY" -eq 0 ]; then
    stop_port "Ollama" 11434
    stop_port "Neo4j" 7687 60   # 종료(체크포인트)에 오래 걸릴 수 있다
fi

echo ""
echo "다시 켜기:  ./start.sh"
exit 0
