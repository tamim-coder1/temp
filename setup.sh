#!/data/data/com.termux/files/usr/bin/bash
# Arena.ai Auto-Bridge for Huawei RNE-L21 (3GB RAM, Android 11)
# Run: bash setup.sh

set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Arena.ai Free Tier Auto-Bridge ===${NC}"
echo -e "${YELLOW}Target: Huawei RNE-L21 | Android 11 | 3GB RAM${NC}"
echo ""

# 1. System deps
echo -e "${GREEN}[1/7] Updating Termux packages...${NC}"
pkg update -y
pkg install -y python python-pip git wget termux-api 2>/dev/null || true

# 2. Python deps
echo -e "${GREEN}[2/7] Installing lightweight Python bridge deps...${NC}"
pip install --upgrade pip -q
pip install flask curl_cffi requests -q

# 3. Working dir
mkdir -p $HOME/arena-bridge
cd $HOME/arena-bridge

# 4. Write bridge server
echo -e "${GREEN}[3/7] Writing bridge server (low-RAM optimized)...${NC}"
cat > arena_bridge.py << 'PYEOF'
#!/data/data/com.termux/files/usr/bin/env python3
"""
Arena.ai -> OpenAI-compatible API bridge
Auto-receives cookies from Kiwi Browser + Tampermonkey
RAM usage: ~40-60 MB
"""
import json, uuid, os, time, sys
from threading import Lock
from flask import Flask, request, Response, jsonify
from curl_cffi import requests as curl_req

app = Flask(__name__)

# ---------- Config ----------
COOKIE_FILE = os.path.expanduser("~/arena-bridge/arena_cookie.json")
ARENA_ENDPOINT = "https://arena.ai/api/v1/chat/completions"  # Adjust if arena changes this
MODEL_MAP = {
    "gpt-4o": "gpt-4o-2024-08-06",
    "gpt-4o-mini": "gpt-4o-mini-2024-07-18",
    "claude-sonnet": "claude-sonnet-4-6",
    "claude-opus": "claude-opus-4-6",
    "gemini-pro": "gemini-1.5-pro-latest",
    "gemini-flash": "gemini-1.5-flash-latest",
    "llama-405b": "llama-3.1-405b",
    "llama-70b": "llama-3.1-70b",
    "deepseek-chat": "deepseek-chat",
}

# ---------- State ----------
cookie_lock = Lock()
current_cookie = None
last_updated = 0
last_error = None

# ---------- Helpers ----------
def load_cookie():
    global current_cookie, last_updated
    try:
        with cookie_lock:
            if os.path.exists(COOKIE_FILE):
                with open(COOKIE_FILE, "r") as f:
                    data = json.load(f)
                current_cookie = data.get("cookie")
                last_updated = data.get("ts", 0)
    except Exception as e:
        print(f"[Cookie] Load error: {e}", file=sys.stderr)

def save_cookie(raw):
    global current_cookie, last_updated
    with cookie_lock:
        current_cookie = raw
        last_updated = time.time()
        os.makedirs(os.path.dirname(COOKIE_FILE), exist_ok=True)
        with open(COOKIE_FILE, "w") as f:
            json.dump({"cookie": raw, "ts": last_updated}, f)

def get_headers():
    load_cookie()
    if not current_cookie:
        raise RuntimeError("No arena cookie. Open Kiwi Browser, log into arena.ai, and keep the Tampermonkey script active.")
    return {
        "User-Agent": "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36",
        "Accept": "text/event-stream",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": "https://arena.ai/",
        "Origin": "https://arena.ai",
        "Cookie": f"arena-auth-prod-v1={current_cookie}",
        "Content-Type": "application/json",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }

# ---------- Routes ----------
@app.route("/update-cookie", methods=["POST"])
def update_cookie():
    body = request.get_json(silent=True) or {}
    token = body.get("cookie")
    if token and len(token) > 20:
        save_cookie(token)
        return jsonify({"ok": True, "age_sec": 0})
    return jsonify({"ok": False, "reason": "bad token"}), 400

@app.route("/v1/models", methods=["GET"])
def list_models():
    return jsonify({
        "object": "list",
        "data": [
            {"id": k, "object": "model", "created": int(time.time()), "owned_by": "arena-free"}
            for k in MODEL_MAP.keys()
        ]
    })

@app.route("/v1/chat/completions", methods=["POST"])
def chat():
    global last_error
    body = request.get_json(silent=True) or {}
    model_key = body.get("model", "gpt-4o")
    model = MODEL_MAP.get(model_key, model_key)
    messages = body.get("messages", [])
    stream = body.get("stream", False)

    arena_payload = {
        "model": model,
        "messages": messages,
        "conversation_id": f"conv_{uuid.uuid4().hex[:10]}",
        "stream": True,
    }

    try:
        headers = get_headers()
    except RuntimeError as e:
        return jsonify({"error": {"message": str(e), "type": "auth_error", "code": "no_cookie"}}), 503

    if not stream:
        try:
            r = curl_req.post(
                ARENA_ENDPOINT,
                headers=headers,
                json=arena_payload,
                impersonate="chrome124",
                timeout=120
            )
            return Response(r.content, status=r.status_code, content_type="application/json")
        except Exception as e:
            last_error = str(e)
            return jsonify({"error": {"message": str(e), "type": "arena_error"}}), 502

    def generate():
        try:
            r = curl_req.post(
                ARENA_ENDPOINT,
                headers=headers,
                json=arena_payload,
                impersonate="chrome124",
                stream=True,
                timeout=120
            )
            for line in r.iter_lines():
                if line:
                    decoded = line.decode("utf-8", errors="ignore")
                    if decoded.startswith("data:") or decoded == "[DONE]":
                        yield decoded + "\n\n"
                    else:
                        yield f"data: {decoded}\n\n"
        except Exception as e:
            yield f"data: {{"error": "{str(e)}"}}\n\n"

    return Response(generate(), mimetype="text/event-stream")

@app.route("/health", methods=["GET"])
def health():
    load_cookie()
    age = int(time.time() - last_updated) if last_updated else None
    return jsonify({
        "status": "ok",
        "cookie_alive": current_cookie is not None,
        "cookie_age_sec": age,
        "models_loaded": len(MODEL_MAP),
        "last_error": last_error,
        "arena_endpoint": ARENA_ENDPOINT,
    })

@app.route("/debug", methods=["POST"])
def debug_proxy():
    """Forward raw request to arena.ai for debugging endpoint discovery."""
    body = request.get_json(silent=True) or {}
    target = body.get("url", ARENA_ENDPOINT)
    method = body.get("method", "GET")
    try:
        headers = get_headers()
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 503
    try:
        if method == "GET":
            r = curl_req.get(target, headers=headers, impersonate="chrome124", timeout=30)
        else:
            r = curl_req.post(target, headers=headers, json=body.get("payload"), impersonate="chrome124", timeout=30)
        return jsonify({"status": r.status_code, "headers": dict(r.headers), "text": r.text[:2000]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    print("[ArenaBridge] Starting on 0.0.0.0:8000")
    print("[ArenaBridge] Waiting for cookie from Kiwi Browser...")
    app.run(host="0.0.0.0", port=8000, threaded=True)
PYEOF

# 5. Write launcher
echo -e "${GREEN}[4/7] Creating auto-launcher...${NC}"
cat > start.sh << 'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
cd $HOME/arena-bridge
termux-wake-lock 2>/dev/null || true
echo "[*] Starting Arena Bridge on :8000 ..."
nohup python arena_bridge.py > bridge.log 2>&1 &
sleep 4
echo "[*] Starting Cloudflare ephemeral tunnel (zero auth)..."
nohup cloudflared tunnel --url http://localhost:8000 > tunnel.log 2>&1 &
sleep 8
URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' tunnel.log | head -1)
if [ -n "$URL" ]; then
    echo "$URL" > public.url
    echo -e "\033[0;32m[+] PUBLIC API URL: $URL\033[0m"
    echo -e "\033[0;32m[+] Use this in your OpenAI client\033[0m"
    termux-notification --title "Arena Bridge LIVE" --content "$URL" 2>/dev/null || true
else
    echo -e "\033[1;33m[!] Tunnel warming up... check tunnel.log\033[0m"
fi
echo "[*] Local:  http://127.0.0.1:8000"
echo "[*] Health: http://127.0.0.1:8000/health"
echo "[*] Logs:   bridge.log | tunnel.log"
echo "[*] Run ./stop.sh to kill everything."
SHEOF
chmod +x start.sh

cat > stop.sh << 'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -f "arena_bridge.py" 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true
echo "[*] Stopped."
SHEOF
chmod +x stop.sh

# 6. Install cloudflared (zero-auth ephemeral tunnels)
echo -e "${GREEN}[5/7] Installing cloudflared tunnel...${NC}"
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
elif [[ "$ARCH" == "armv7l" || "$ARCH" == "armv8l" ]]; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
else
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
fi
wget -q --show-progress "$CF_URL" -O cloudflared-bin
chmod +x cloudflared-bin
mv cloudflared-bin $PREFIX/bin/cloudflared

# 7. Boot auto-start (if Termux:Boot is installed)
echo -e "${GREEN}[6/7] Configuring auto-start...${NC}"
mkdir -p $HOME/.termux/boot 2>/dev/null || true
if [ -d "$HOME/.termux/boot" ]; then
    cat > $HOME/.termux/boot/start-arena << 'BOOTEof'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
cd /data/data/com.termux/files/home/arena-bridge
./start.sh
BOOTEof
    chmod +x $HOME/.termux/boot/start-arena
    echo -e "${GREEN}[+] Termux:Boot auto-start installed.${NC}"
else
    echo -e "${YELLOW}[!] Termux:Boot not found. Install from F-Droid for boot auto-start.${NC}"
fi

# 8. Tampermonkey script file for convenience
echo -e "${GREEN}[7/7] Writing Tampermonkey script to tampermonkey.js...${NC}"
cat > tampermonkey.js << 'TMEOF'
// ==UserScript==
// @name         Arena Cookie Auto-Feeder
// @namespace    http://tampermonkey.net/
// @version      1.0
// @description  Auto-steals arena.ai auth cookie and feeds it to the local bridge
// @author       You
// @match        https://arena.ai/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// ==/UserScript==

(function() {
    'use strict';
    const BRIDGE_URL = 'http://127.0.0.1:8000/update-cookie';

    function feedCookie() {
        const cookieRow = document.cookie.split('; ')
            .find(row => row.startsWith('arena-auth-prod-v1='));
        if (!cookieRow) {
            console.log('[ArenaFeeder] Cookie not found yet');
            return;
        }
        const token = cookieRow.split('=')[1];
        if (!token || token.length < 20) return;

        GM_xmlhttpRequest({
            method: "POST",
            url: BRIDGE_URL,
            headers: { "Content-Type": "application/json" },
            data: JSON.stringify({ cookie: token }),
            onload: function(res) {
                if (res.status === 200) {
                    console.log('[ArenaFeeder] Cookie fed OK');
                } else {
                    console.log('[ArenaFeeder] Feed failed:', res.status);
                }
            },
            onerror: function(err) {
                console.log('[ArenaFeeder] Network error:', err);
            }
        });
    }

    // Feed immediately and every 25 seconds
    feedCookie();
    setInterval(feedCookie, 25000);

    // Also feed when user sends a message (cookie might refresh)
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter') setTimeout(feedCookie, 2000);
    });
})();
TMEOF

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}MANUAL STEPS (do once):${NC}"
echo "1. Install Kiwi Browser from Play Store / APK"
echo "2. Open Kiwi Browser, go to https://arena.ai"
echo "3. Log into arena.ai (Google/GitHub/whatever)"
echo "4. Install Tampermonkey extension inside Kiwi"
echo "5. Create NEW script, paste contents of: ${GREEN}~/arena-bridge/tampermonkey.js${NC}"
echo "6. Keep Kiwi Browser open on arena.ai (background is OK)"
echo ""
echo -e "${GREEN}THEN RUN:${NC}"
echo "   cd ~/arena-bridge && ./start.sh"
echo ""
echo -e "${GREEN}Your public URL will appear above.${NC}"
echo -e "${GREEN}Use that URL as 'base_url' in any OpenAI client.${NC}"
echo ""
echo -e "${YELLOW}TIPS:${NC}"
echo "- If arena.ai changes their API endpoint, edit ARENA_ENDPOINT in arena_bridge.py"
echo "- Use /debug endpoint to probe new endpoints if needed"
echo "- Run 'tail -f bridge.log' to see live traffic"
echo "========================================"
