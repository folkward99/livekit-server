#!/bin/sh
# ==============================================================================
# LiveKit & Egress Healthcheck Script
# ==============================================================================
# This script is called by Docker Compose to determine container health.
# It automatically uses the best tool available (curl, wget, or netcat).

set -e

SERVICE_TYPE="$1"
PORT="$2"

if [ -z "$SERVICE_TYPE" ]; then
  echo "Usage: $0 {server|egress} [port]"
  exit 1
fi

# Fallback ports if not specified
if [ -z "$PORT" ]; then
  if [ "$SERVICE_TYPE" = "server" ]; then
    PORT=7880
  elif [ "$SERVICE_TYPE" = "egress" ]; then
    PORT=8080
  fi
fi

# Perform check depending on service
if [ "$SERVICE_TYPE" = "server" ]; then
  # For LiveKit server, verify it is listening on the signaling port.
  # LiveKit server does not have a public /health endpoint that returns 200 (root / returns 404).
  # We check if the port is listening using nc, or if curl can connect (ignoring 404).
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT"
    exit $?
  elif command -v curl >/dev/null 2>&1; then
    # curl without -f will succeed (exit 0) if the server responds at all (even 404)
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/"
    exit $?
  else
    # Fallback to checking if the process is running
    pgrep livekit-server >/dev/null || pidof livekit-server >/dev/null
    exit $?
  fi
elif [ "$SERVICE_TYPE" = "egress" ]; then
  # LiveKit Egress exposes health on the root path of the health port (which returns 200)
  TARGET_URL="http://127.0.0.1:${PORT}/"
  
  if command -v curl >/dev/null 2>&1; then
    curl -s -f "$TARGET_URL" > /dev/null
    exit $?
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider "$TARGET_URL" > /dev/null
    exit $?
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT"
    exit $?
  else
    pgrep egress >/dev/null || pidof egress >/dev/null
    exit $?
  fi
else
  echo "Invalid service type: $SERVICE_TYPE. Use 'server' or 'egress'."
  exit 1
fi
