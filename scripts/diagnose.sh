#!/bin/sh
# ==============================================================================
# LiveKit Stack Diagnostics Tool
# ==============================================================================
# Run this script on your VPS host to inspect container health, network bindings,
# generated configs (redacted), database connectivity, and logs.

set -e

# Formatting utilities
print_header() {
  echo ""
  echo "===================================================================="
  echo " $1"
  echo "===================================================================="
}

print_header "LiveKit Diagnostics - Check Status"

# 1. Check Docker Daemon
if ! command -v docker >/dev/null 2>&1; then
  echo "[-] ERROR: docker CLI is not installed or not in the PATH."
  echo "    Please run this script on the target VPS host."
  exit 1
fi

# 2. Check Container Health and State
print_header "1. Running Containers (livekit-server, egress, redis)"
docker ps -a --filter name=livekit --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 3. Check Network Ports on Host
print_header "2. Network Port Binding Check (Listening on Host)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn 2>/dev/null | grep -E "7880|7881|7882|3478|5349" || echo "[!] No active ports detected on host via ss. Check container bindings."
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulpn 2>/dev/null | grep -E "7880|7881|7882|3478|5349" || echo "[!] No active ports detected on host via netstat. Check container bindings."
else
  echo "[!] Neither ss nor netstat command found. Skipping port listing."
fi

# 4. Redis Connectivity Check (Internal Network)
print_header "3. Redis Connectivity (Internal Network resolution)"
if docker ps --filter name=livekit-server --filter status=running -q >/dev/null 2>&1; then
  echo "[*] Checking if livekit-server container can resolve/ping Redis host..."
  # Try to extract the Redis host from environment of the container
  REDIS_URL_ENV=$(docker exec livekit-server env | grep REDIS_URL || true)
  if [ -n "$REDIS_URL_ENV" ]; then
    # Parse host
    CLEAN_URL="${REDIS_URL_ENV#*redis://}"
    CLEAN_URL="${CLEAN_URL#*@}"
    REDIS_HOST="${CLEAN_URL%%:*}"
    REDIS_HOST="${REDIS_HOST%%/*}"
    echo "    Detected Redis Host from env: $REDIS_HOST"
    
    # Try pinging Redis from livekit-server container
    if docker exec livekit-server ping -c 1 "$REDIS_HOST" >/dev/null 2>&1; then
      echo "[+] SUCCESS: livekit-server container can ping Redis ($REDIS_HOST)."
    else
      echo "[-] FAILURE: livekit-server container cannot resolve/ping Redis ($REDIS_HOST)."
      echo "    Check if they are in the same docker networks."
    fi
  else
    echo "[!] REDIS_URL environment variable is not defined on livekit-server container."
  fi
else
  echo "[!] livekit-server container is not running. Skipping database network check."
fi

if docker ps --filter name=livekit-egress --filter status=running -q >/dev/null 2>&1; then
  echo "[*] Checking if livekit-egress container can resolve/ping Redis host..."
  REDIS_URL_ENV=$(docker exec livekit-egress env | grep REDIS_URL || true)
  if [ -n "$REDIS_URL_ENV" ]; then
    CLEAN_URL="${REDIS_URL_ENV#*redis://}"
    CLEAN_URL="${CLEAN_URL#*@}"
    REDIS_HOST="${CLEAN_URL%%:*}"
    REDIS_HOST="${REDIS_HOST%%/*}"
    
    if docker exec livekit-egress ping -c 1 "$REDIS_HOST" >/dev/null 2>&1; then
      echo "[+] SUCCESS: livekit-egress container can ping Redis ($REDIS_HOST)."
    else
      echo "[-] FAILURE: livekit-egress container cannot resolve/ping Redis ($REDIS_HOST)."
      echo "    Please verify that 'dokploy-network' is declared as an external network and"
      echo "    attached to both livekit-server and livekit-egress in your docker-compose.yml."
    fi
  else
    echo "[!] REDIS_URL environment variable is not defined on livekit-egress container."
  fi
else
  echo "[!] livekit-egress container is not running."
fi

# 5. Redacted Configurations
print_header "4. Active LiveKit Config (/tmp/livekit.yaml - REDACTED)"
if docker ps --filter name=livekit-server --filter status=running -q >/dev/null 2>&1; then
  docker exec livekit-server cat /tmp/livekit.yaml 2>/dev/null | \
    sed -E 's/(password:\s*")[^"]*(")/\1[REDACTED]\2/g' | \
    sed -E 's/(api_secret:\s*)\S+/\1[REDACTED]/g' | \
    awk '/keys:/{print;print "  [REDACTED_API_KEY]: [REDACTED_API_SECRET]";flag=1;next} /^[a-zA-Z]/{flag=0} flag{next} 1' || \
    echo "[-] Cannot read /tmp/livekit.yaml from livekit-server."
else
  echo "[!] livekit-server container is not running."
fi

print_header "5. Active Egress Config (/tmp/egress.yaml - REDACTED)"
if docker ps --filter name=livekit-egress --filter status=running -q >/dev/null 2>&1; then
  docker exec livekit-egress cat /tmp/egress.yaml 2>/dev/null | \
    sed -E 's/(password:\s*")[^"]*(")/\1[REDACTED]\2/g' | \
    sed -E 's/(api_secret:\s*)\S+/\1[REDACTED]/g' | \
    sed -E 's/(api_key:\s*)\S+/\1[REDACTED]/g' || \
    echo "[-] Cannot read /tmp/egress.yaml from livekit-egress."
else
  echo "[!] livekit-egress container is not running."
fi

# 6. Service Logs
print_header "6. Recent LiveKit Server Logs"
docker logs --tail=30 livekit-server || echo "[-] Cannot read livekit-server logs."

print_header "7. Recent LiveKit Egress Logs"
docker logs --tail=30 livekit-egress || echo "[-] Cannot read livekit-egress logs."

# 7. Testing Reminders
print_header "7. Troubleshooting & Testing Guidelines"
echo "1. HTTP Root 404 is NORMAL: Opening https://livekit.unfolk.com in a browser"
echo "   will return '404 page not found'. Do not treat this as a failure."
echo "2. Real connection URL for clients/SDKs is WebSocket-based:"
echo "   wss://livekit.unfolk.com"
echo "3. Use the official LiveKit connection tester to verify client reachability:"
echo "   https://connection-test.livekit.io/"
echo "4. Generate a test participant JWT token using your backend SDK with the same"
echo "   LIVEKIT_API_KEY and LIVEKIT_API_SECRET configured in livekit-server."
echo "===================================================================="
