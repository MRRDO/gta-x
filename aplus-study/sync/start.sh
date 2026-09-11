#!/usr/bin/env bash
# Start the Bench Test sync server and open an ngrok tunnel to it.
#
#   chmod +x start.sh
#   ./start.sh
#
# Needs: node 18+, and ngrok (brew install ngrok, then `ngrok config add-authtoken <token>`)

set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8787}"

if ! command -v node >/dev/null 2>&1; then
  echo "node is not installed. Install it from https://nodejs.org or: brew install node"
  exit 1
fi
if ! command -v ngrok >/dev/null 2>&1; then
  echo "ngrok is not installed. Install it: brew install ngrok"
  echo "Then sign up at ngrok.com and run: ngrok config add-authtoken <your token>"
  exit 1
fi

echo "Starting sync server on port $PORT..."
PORT="$PORT" node sync-server.js &
SERVER_PID=$!
# Stop the server when this script exits, however it exits.
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT INT TERM

sleep 1
if ! kill -0 $SERVER_PID 2>/dev/null; then
  echo "Server failed to start. Is port $PORT already in use?"
  exit 1
fi

echo ""
echo "Opening tunnel. Your public URL appears below as 'Forwarding'."
echo "Open it on any device with your code on the end, for example:"
echo "    https://<id>.ngrok-free.app/#code=your-secret-code"
echo ""
echo "Keep this window open and this Mac awake — the tunnel dies when it sleeps."
echo ""

ngrok http "$PORT"
