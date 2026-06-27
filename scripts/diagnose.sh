#!/bin/sh
# ==============================================================================
# LiveKit Stack Diagnostics Tool
# ==============================================================================
# Run this script on your VPS host to inspect container health, network bindings,
# generated configs (redacted), Redis connectivity, logs, and CORS behavior.

set -e

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

LIVEKIT_PORT="${LIVEKIT_PORT:-7880}"
RTC_TCP_PORT="${RTC_TCP_PORT:-7881}"
RTC_UDP_PORT="${RTC_UDP_PORT:-7882}"
TURN_UDP_PORT="${TURN_UDP_PORT:-3478}"
TURN_TLS_PORT="${TURN_TLS_PORT:-5349}"
LIVEKIT_DOMAIN="${LIVEKIT_DOMAIN:-livekit.example.com}"
LIVEKIT_ALLOWED_ORIGINS="${LIVEKIT_ALLOWED_ORIGINS:-https://app.example.com,http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173}"
LIVEKIT_CORS_TEST_ORIGIN="${LIVEKIT_CORS_TEST_ORIGIN:-${LIVEKIT_ALLOWED_ORIGINS%%,*}}"
LIVEKIT_PUBLIC_URL="${LIVEKIT_PUBLIC_URL:-https://${LIVEKIT_DOMAIN}}"

print_header() {
  echo ""
  echo "===================================================================="
  echo " $1"
  echo "===================================================================="
}

container_running() {
  docker ps --filter "name=$1" --filter status=running -q | grep -q .
}

redact_yaml() {
  sed -E 's/(password:\s*")[^"]*(")/\1[REDACTED]\2/g' | \
    sed -E 's/(api_secret:\s*)\S+/\1[REDACTED]/g' | \
    sed -E 's/(api_key:\s*)\S+/\1[REDACTED]/g' | \
    awk '/keys:/{print;print "  [REDACTED_API_KEY]: [REDACTED_API_SECRET]";flag=1;next} /^[a-zA-Z]/{flag=0} flag{next} 1'
}

print_header "LiveKit Diagnostics"
echo "LiveKit public URL: ${LIVEKIT_PUBLIC_URL}"
echo "CORS test origin:   ${LIVEKIT_CORS_TEST_ORIGIN}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[-] ERROR: docker CLI is not installed or not in the PATH."
  echo "    Please run this script on the target VPS host."
  exit 1
fi

print_header "1. Running Containers"
docker ps -a --filter name=livekit --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

print_header "2. Container Health"
for name in livekit-server livekit-egress livekit-redis; do
  if docker ps -a --filter "name=${name}" -q | grep -q .; then
    docker inspect --format '{{.Name}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} status={{.State.Status}}' "$name"
  else
    echo "[!] ${name} not found."
  fi
done

print_header "3. Host Port Bindings"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn 2>/dev/null | grep -E "${LIVEKIT_PORT}|${RTC_TCP_PORT}|${RTC_UDP_PORT}|${TURN_UDP_PORT}|${TURN_TLS_PORT}" || echo "[!] No matching host port bindings found via ss."
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulpn 2>/dev/null | grep -E "${LIVEKIT_PORT}|${RTC_TCP_PORT}|${RTC_UDP_PORT}|${TURN_UDP_PORT}|${TURN_TLS_PORT}" || echo "[!] No matching host port bindings found via netstat."
else
  echo "[!] Neither ss nor netstat is available."
fi

print_header "4. Required Port Checks"
echo "Signaling/API TCP ${LIVEKIT_PORT}: should be routed by Dokploy/Traefik to livekit-server."
echo "RTC TCP ${RTC_TCP_PORT}: should be open on the VPS firewall."
echo "RTC UDP mux ${RTC_UDP_PORT}: should be open on the VPS firewall."
echo "TURN TCP/UDP ${TURN_UDP_PORT}: should be open on the VPS firewall."
if [ -n "$TURN_TLS_PORT" ]; then
  echo "TURN TLS TCP/UDP ${TURN_TLS_PORT}: open only if TURN TLS certs are configured."
fi

print_header "5. Redis Connectivity"
for name in livekit-server livekit-egress; do
  if container_running "$name"; then
    REDIS_URL_ENV=$(docker exec "$name" env | grep '^REDIS_URL=' || true)
    if [ -n "$REDIS_URL_ENV" ]; then
      CLEAN_URL="${REDIS_URL_ENV#REDIS_URL=}"
      CLEAN_URL="${CLEAN_URL#redis://}"
      CLEAN_URL="${CLEAN_URL#*@}"
      REDIS_HOST="${CLEAN_URL%%:*}"
      REDIS_HOST="${REDIS_HOST%%/*}"
      echo "[*] ${name} Redis host: ${REDIS_HOST}"
      if docker exec "$name" ping -c 1 "$REDIS_HOST" >/dev/null 2>&1; then
        echo "[+] ${name} can resolve/ping Redis."
      else
        echo "[-] ${name} cannot resolve/ping Redis. Check Docker networks and REDIS_URL."
      fi
    else
      echo "[!] REDIS_URL is not defined in ${name}."
    fi
  else
    echo "[!] ${name} is not running."
  fi
done

if container_running livekit-redis; then
  if docker exec livekit-redis redis-cli ping >/dev/null 2>&1; then
    echo "[+] livekit-redis responds to redis-cli ping."
  else
    echo "[-] livekit-redis did not respond to redis-cli ping."
  fi
fi

print_header "6. Active LiveKit Config (/tmp/livekit.yaml - redacted)"
if container_running livekit-server; then
  docker exec livekit-server cat /tmp/livekit.yaml 2>/dev/null | redact_yaml || echo "[-] Cannot read /tmp/livekit.yaml."
else
  echo "[!] livekit-server is not running."
fi

print_header "7. Active Egress Config (/tmp/egress.yaml - redacted)"
if container_running livekit-egress; then
  docker exec livekit-egress cat /tmp/egress.yaml 2>/dev/null | redact_yaml || echo "[-] Cannot read /tmp/egress.yaml."
else
  echo "[!] livekit-egress is not running."
fi

print_header "8. Recent LiveKit Server Logs"
docker logs --tail=40 livekit-server || echo "[-] Cannot read livekit-server logs."

print_header "9. Recent LiveKit Egress Logs"
docker logs --tail=40 livekit-egress || echo "[-] Cannot read livekit-egress logs."

print_header "10. CORS Test"
if command -v curl >/dev/null 2>&1; then
  echo "Running:"
  echo "curl -i -H \"Origin: ${LIVEKIT_CORS_TEST_ORIGIN}\" \"${LIVEKIT_PUBLIC_URL}/rtc/v1/validate\""
  curl -i -H "Origin: ${LIVEKIT_CORS_TEST_ORIGIN}" "${LIVEKIT_PUBLIC_URL}/rtc/v1/validate" || true
  echo ""
  echo "Expected: Access-Control-Allow-Origin should match ${LIVEKIT_CORS_TEST_ORIGIN}, even when the token is missing or invalid."
else
  echo "[!] curl is not installed. Skipping CORS test."
fi

print_header "11. Testing Guidelines"
echo "1. HTTP root 404 is normal for LiveKit."
echo "2. Clients should connect to wss://${LIVEKIT_DOMAIN}."
echo "3. Dokploy domain routing should target service livekit-server on internal port ${LIVEKIT_PORT} with SSL enabled."
echo "4. Do not route the LiveKit domain to egress, Redis, frontend, or backend services."
echo "5. Use https://connection-test.livekit.io/ with a valid participant token to verify WebRTC connectivity."
