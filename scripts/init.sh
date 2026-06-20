#!/bin/sh
# ==============================================================================
# LiveKit & Egress Initialization Script
# ==============================================================================
# This script runs inside the container on startup. It parses environment
# variables (like REDIS_URL) and generates the active configuration files
# from templates.

set -e

echo "===================================================================="
echo "Starting LiveKit Configuration Initialization..."
echo "===================================================================="

# Ensure config directory exists
mkdir -p /config

# 1. Parse REDIS_URL
# Expected format: redis://[:password]@host[:port][/db]
if [ -n "$REDIS_URL" ]; then
  # Strip prefix
  clean_url="${REDIS_URL#redis://}"
  
  # Extract credentials and host info
  if echo "$clean_url" | grep -q "@"; then
    credentials="${clean_url%%@*}"
    host_db_part="${clean_url#*@}"
    REDIS_PASSWORD="${credentials#*:}"
  else
    host_db_part="$clean_url"
    REDIS_PASSWORD=""
  fi
  
  # Extract host/port and db
  host_port_part="${host_db_part%%/*}"
  REDIS_DB="${host_db_part#*/}"
  # If no slash/db index was specified, default to 0
  if [ "$REDIS_DB" = "$host_db_part" ]; then
    REDIS_DB="0"
  fi
  # Clean up DB index if it has query params (e.g. ?pool_size=100)
  REDIS_DB="${REDIS_DB%%?*}"
  
  # Extract host and port
  REDIS_HOST="${host_port_part%%:*}"
  REDIS_PORT="${host_port_part#*:}"
  if [ "$REDIS_PORT" = "$host_port_part" ]; then
    REDIS_PORT="6379"
  fi
  
  echo "Parsed Redis configuration:"
  echo "  Host:     $REDIS_HOST"
  echo "  Port:     $REDIS_PORT"
  echo "  Database: $REDIS_DB"
  if [ -n "$REDIS_PASSWORD" ]; then
    echo "  Password: [PROVIDED]"
  else
    echo "  Password: [NONE]"
  fi
else
  echo "ERROR: REDIS_URL environment variable is not set."
  exit 1
fi

# 2. Set default values for other optional variables
LIVEKIT_PORT="${LIVEKIT_PORT:-7880}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-devkey}"
LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-secret}"
RTC_USE_EXTERNAL_IP="${RTC_USE_EXTERNAL_IP:-true}"
RTC_TCP_PORT="${RTC_TCP_PORT:-7881}"
RTC_UDP_PORT="${RTC_UDP_PORT:-7882}"
LIVEKIT_WS_URL="${LIVEKIT_WS_URL:-ws://livekit-server:7880}"

TURN_ENABLED="${TURN_ENABLED:-true}"
TURN_DOMAIN="${TURN_DOMAIN:-turn.yourdomain.com}"
TURN_UDP_PORT="${TURN_UDP_PORT:-3478}"
TURN_TLS_PORT="${TURN_TLS_PORT:-5349}"

# 3. Generate livekit.yaml
if [ -f "/config/livekit.template.yaml" ]; then
  echo "Generating livekit.yaml from template..."
  
  # Step 1: Base replacement
  sed -e "s|\${LIVEKIT_PORT}|$LIVEKIT_PORT|g" \
      -e "s|\${LOG_LEVEL}|$LOG_LEVEL|g" \
      -e "s|\${RTC_UDP_PORT}|$RTC_UDP_PORT|g" \
      -e "s|\${RTC_TCP_PORT}|$RTC_TCP_PORT|g" \
      -e "s|\${RTC_USE_EXTERNAL_IP}|$RTC_USE_EXTERNAL_IP|g" \
      -e "s|\${REDIS_HOST}|$REDIS_HOST|g" \
      -e "s|\${REDIS_PORT}|$REDIS_PORT|g" \
      -e "s|\${REDIS_PASSWORD}|$REDIS_PASSWORD|g" \
      -e "s|\${REDIS_DB}|$REDIS_DB|g" \
      -e "s|\${TURN_ENABLED}|$TURN_ENABLED|g" \
      -e "s|\${TURN_DOMAIN}|$TURN_DOMAIN|g" \
      -e "s|\${TURN_UDP_PORT}|$TURN_UDP_PORT|g" \
      -e "s|\${TURN_TLS_PORT}|$TURN_TLS_PORT|g" \
      -e "s|\${LIVEKIT_API_KEY}|$LIVEKIT_API_KEY|g" \
      -e "s|\${LIVEKIT_API_SECRET}|$LIVEKIT_API_SECRET|g" \
      /config/livekit.template.yaml > /tmp/livekit.yaml.tmp

  # Step 2: Handle TURN TLS Certificates
  if [ -n "$TURN_CERT_FILE" ] && [ -n "$TURN_KEY_FILE" ]; then
    echo "Injecting TURN TLS certificate paths..."
    sed -e "s|\${TURN_CERT_FILE}|$TURN_CERT_FILE|g" \
        -e "s|\${TURN_KEY_FILE}|$TURN_KEY_FILE|g" \
        /tmp/livekit.yaml.tmp > /tmp/livekit.yaml.tmp2
    mv /tmp/livekit.yaml.tmp2 /tmp/livekit.yaml.tmp
  else
    echo "Removing TURN TLS cert_file, key_file, and tls_port from configuration (not provided)..."
    sed -e "/TURN_CERT_FILE/d" \
        -e "/TURN_KEY_FILE/d" \
        -e "/TURN_TLS_PORT/d" \
        -e "/tls_port/d" \
        /tmp/livekit.yaml.tmp > /tmp/livekit.yaml.tmp2
    mv /tmp/livekit.yaml.tmp2 /tmp/livekit.yaml.tmp
  fi

  mv /tmp/livekit.yaml.tmp /tmp/livekit.yaml
  echo "Created active config: /tmp/livekit.yaml"
else
  echo "ERROR: /config/livekit.template.yaml not found!"
  exit 1
fi

# 4. Generate egress.yaml
if [ -f "/config/egress.template.yaml" ]; then
  echo "Generating egress.yaml from template..."
  
  sed -e "s|\${LIVEKIT_API_KEY}|$LIVEKIT_API_KEY|g" \
      -e "s|\${LIVEKIT_API_SECRET}|$LIVEKIT_API_SECRET|g" \
      -e "s|\${LIVEKIT_WS_URL}|$LIVEKIT_WS_URL|g" \
      -e "s|\${REDIS_HOST}|$REDIS_HOST|g" \
      -e "s|\${REDIS_PORT}|$REDIS_PORT|g" \
      -e "s|\${REDIS_PASSWORD}|$REDIS_PASSWORD|g" \
      -e "s|\${REDIS_DB}|$REDIS_DB|g" \
      -e "s|\${LOG_LEVEL}|$LOG_LEVEL|g" \
      /config/egress.template.yaml > /tmp/egress.yaml.tmp
      
  mv /tmp/egress.yaml.tmp /tmp/egress.yaml
  echo "Created active config: /tmp/egress.yaml"
else
  echo "ERROR: /config/egress.template.yaml not found!"
  exit 1
fi

echo "===================================================================="
echo "Initialization Script Completed Successfully!"
echo "===================================================================="
