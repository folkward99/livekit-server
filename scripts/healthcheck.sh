#!/bin/sh
# ==============================================================================
# LiveKit & Egress Healthcheck Script
# ==============================================================================
# This script is called by Docker Compose to determine container health.
# It avoids HTTP root checks because LiveKit can correctly return 404 on /.

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
  if command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    timeout 3 bash -c "</dev/tcp/127.0.0.1/${PORT}" || exit 1
    exit 0
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT"
    exit $?
  else
    # Fallback to checking if the process is running
    pgrep livekit-server >/dev/null || pidof livekit-server >/dev/null
    exit $?
  fi
elif [ "$SERVICE_TYPE" = "egress" ]; then
  pgrep -x egress >/dev/null || pidof egress >/dev/null || pgrep -f "[e]gress" >/dev/null
  exit $?
else
  echo "Invalid service type: $SERVICE_TYPE. Use 'server' or 'egress'."
  exit 1
fi
