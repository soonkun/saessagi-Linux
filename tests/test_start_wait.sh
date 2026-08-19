#!/usr/bin/env bash
# start.sh의 백엔드 대기 루프 검사 — 실제 루프를 start.sh에서 그대로 떼어내 돌린다.
#
# 지키는 것 두 가지:
#   1) 백엔드가 늦게 떠도 기다린다 (180초 벽에 걸려 멀쩡한 기동을 실패로 만들지 않는다)
#   2) 백엔드가 죽었으면 600초를 채우지 않고 바로 포기한다
#
# 프로세스 패턴만 app.main → app.maintest 로 바꿔 돌린다. 안 그러면 지금 돌고 있는
# 진짜 백엔드에 pgrep이 걸려 죽음 판정을 영영 못 한다. 검사 대상 로직은 그대로다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -f "app[.]maintest" 2>/dev/null' EXIT

sed -n '/^BE_READY=0$/,/^done$/p' "$ROOT/start.sh" | sed 's/app\\\.main/app\\.maintest/' > "$TMP/loop.sh"
grep -q 'seq 1 600' "$TMP/loop.sh" || { echo "FAIL: 대기 루프를 못 찾았다"; exit 1; }

mkdir -p "$TMP/app"
cat > "$TMP/app/maintest.py" <<'PY'
import http.server, os, sys, time
time.sleep(float(os.environ["DELAY"]))
if os.environ["MODE"] == "die":
    sys.exit(1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY

run_case() {  # mode delay port -> "초 BE_READY"
    ( cd "$TMP" && MODE="$1" DELAY="$2" PORT="$3" setsid --fork nohup \
        python3 -m app.maintest >/dev/null 2>&1 </dev/null & )
    local t0=$SECONDS
    PORT="$3" BE_READY=0
    . "$TMP/loop.sh"
    echo "$((SECONDS - t0)) $BE_READY"
}

# 1) 늦게 뜨는 백엔드 — 기다렸다가 성공해야 한다
read -r secs ready <<< "$(run_case serve 20 51771)"
[ "$ready" = "1" ] || { echo "FAIL: 20초 후 뜬 백엔드를 놓쳤다 (${secs}초)"; exit 1; }
# 다음 검사의 pgrep에 걸리지 않게 치운다.
# 패턴을 app[.]maintest로 쓰는 이유: pkill -f는 자기 명령줄까지 매칭한다. 대괄호를 쓰면
# 정규식은 app.maintest에 걸리지만 명령줄에 적힌 app[.]maintest 자신에는 안 걸린다.
pkill -f 'app[.]maintest'; sleep 1
echo "ok  늦은 기동 대기: ${secs}초 만에 준비 감지"

# 2) 죽은 백엔드 — 600초를 채우지 않고 포기해야 한다
read -r secs ready <<< "$(run_case die 2 51772)"
[ "$ready" = "0" ] || { echo "FAIL: 죽은 백엔드를 준비됐다고 했다"; exit 1; }
[ "$secs" -lt 60 ] || { echo "FAIL: 죽음을 ${secs}초나 걸려 알아챘다"; exit 1; }
echo "ok  죽은 기동 조기 포기: ${secs}초"

echo "PASS"
