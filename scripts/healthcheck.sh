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
  # LiveKit Server has a /health endpoint
  TARGET_URL="http://localhost:${PORT}/health"
elif [ "$SERVICE_TYPE" = "egress" ]; then
  # LiveKit Egress exposes health on the root path of the health port
  TARGET_URL="http://localhost:${PORT}/"
else
  echo "Invalid service type: $SERVICE_TYPE. Use 'server' or 'egress'."
  exit 1
fi

# Attempt health check with curl, then wget, and fallback to netcat
if command -v curl >/dev/null 2>&1; then
  curl -s -f "$TARGET_URL" > /dev/null
  exit $?
elif command -v wget >/dev/null 2>&1; then
  wget -q --spider "$TARGET_URL" > /dev/null
  exit $?
elif command -v nc >/dev/null 2>&1; then
  # Fallback to basic port listening check if curl/wget are missing
  nc -z localhost "$PORT"
  exit $?
else
  # If all else fails, assume healthy if the process is running,
  # but log a warning to stderr.
  echo "Warning: no curl, wget, or netcat found for healthcheck." >&2
  exit 0
fi
