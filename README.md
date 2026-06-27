# Production-Ready Self-Hosted LiveKit & Egress Stack for Dokploy

This repository contains the complete, production-ready configuration for self-hosting **LiveKit Server** and **LiveKit Egress** using Docker Compose. It is designed to work seamlessly within a **Dokploy** environment without requiring manual post-deployment edits.

---

## Table of Contents
1. [Project Overview](#project-overview)
2. [Folder Structure](#folder-structure)
3. [Networking & Firewall Configuration](#networking--firewall-configuration)
4. [Environment Variables Reference](#environment-variables-reference)
5. [Step-by-Step Dokploy Deployment](#step-by-step-dokploy-deployment)
6. [Egress & MinIO Integration (Phase 2)](#egress--minio-integration-phase-2)
7. [Operational Guide (Backups & Restores)](#operational-guide-backups--restores)
8. [Updating LiveKit](#updating-livekit)
9. [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)
10. [Scaling Recommendations](#scaling-recommendations)

---

## Project Overview

LiveKit is an open-source Selective Forwarding Unit (SFU) for building real-time audio, video, and screen-sharing applications. 
This deployment stack pins LiveKit Server `v1.13.2` and LiveKit Egress `v1.13.0` for compatibility with Aritte frontend packages `livekit-client 2.19.2`, `@livekit/components-react 2.9.21`, and `@livekit/components-styles 1.2.0`.

This deployment stack contains:
- **LiveKit Server**: Manages rooms, handles signaling, and forwards WebRTC media.
- **LiveKit Egress**: Captures room media (recording/streaming) using a headless Chrome process inside a container.
- **Redis (Optional)**: Provides high-performance state storage required for Egress coordination. The stack is configurable to use either this internal Redis or an external (Dokploy-managed) Redis instance.

---

## Folder Structure

```
livekit-server/
├── docker-compose.yml       # Docker Compose service definition
├── .env.example             # Template for environment variables
├── README.md                # This operational guide
├── backups/                 # Directory to store local Redis/config backups
├── storage/                 # Shared persistent volume for recordings & cache
├── scripts/
│   ├── init.sh              # Container startup script (generates configs)
│   └── healthcheck.sh       # Multi-service health monitoring script
└── config/                  # Generated & template configuration files
    ├── livekit.template.yaml # Template for LiveKit server
    ├── egress.template.yaml  # Template for Egress service
    ├── livekit.yaml          # Generated at runtime (DO NOT EDIT DIRECTLY)
    └── egress.yaml           # Generated at runtime (DO NOT EDIT DIRECTLY)
```

---

## Networking & Firewall Configuration

Unlike standard web applications, WebRTC media traffic (audio/video) is carried over **UDP** and bypasses Dokploy's HTTP reverse proxy (Traefik).

To support this, the stack is configured by default to use **UDP Mux (Single Port)**:
- **Direct Signaling/API**: Exposes port `7880` (TCP). Dokploy/Traefik routes `LIVEKIT_DOMAIN` directly to this internal port.
- **WebRTC UDP Mux**: Exposes port `7882` (UDP). You **must** open `7882/UDP` in your VPS firewall.
- **WebRTC TCP Fallback**: Exposes port `7881` (TCP). Used when UDP is blocked.
- **TURN Server**: Exposes port `3478` (UDP & TCP). Used for NAT traversal when direct WebRTC is blocked.

### VPS Firewall Setup (UFW Example)
Run the following commands on your Ubuntu Server to open the required ports:
```bash
sudo ufw allow 7881/tcp
sudo ufw allow 7882/udp
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw reload
sudo ufw status
```

If you enable a TURN relay UDP range, also open that range:
```bash
sudo ufw allow 30000:40000/udp
sudo ufw reload
```

Port `7880` is normally internal to Dokploy/Traefik. You do not need to expose it on the public firewall unless you intentionally want direct host-level troubleshooting.

### VPS Sysctl Setup
Run these host-level settings on the VPS:
```bash
sudo tee /etc/sysctl.d/99-livekit.conf > /dev/null <<'EOF'
net.core.rmem_max=5000000
net.core.wmem_max=5000000
vm.overcommit_memory=1
EOF

sudo sysctl --system
```

`vm.overcommit_memory=1` fixes the Redis warning. `net.core.rmem_max` and `net.core.wmem_max` fix LiveKit UDP buffer warnings.

---

## Environment Variables Reference

Copy `.env.example` to `.env` (or configure these inside the Dokploy Environment Variables dashboard):

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `LIVEKIT_PORT` | `7880` | Internal port for signaling (HTTP/WS). |
| `LIVEKIT_DOMAIN` | `livekit.example.com` | Public domain routed by Dokploy/Traefik to `livekit-server`. |
| `LIVEKIT_ALLOWED_ORIGINS` | `https://app.example.com,...` | Comma-separated frontend origins allowed to call browser LiveKit endpoints. |
| `LOG_LEVEL` | `info` | Server logging level (`debug`, `info`, `warn`, `error`). |
| `LIVEKIT_API_KEY` | *(set in `.env`)* | Unique identifier key used by your backend to sign JWTs. |
| `LIVEKIT_API_SECRET` | *(set in `.env`)* | Shared secret used to sign/verify JWT tokens. |
| `REDIS_URL` | `redis://redis:6379/0` | Redis connection URL. Set to an external Redis if using Option A. |
| `RTC_USE_EXTERNAL_IP` | `true` | Enables auto-discovery of the VPS public IP. |
| `RTC_TCP_PORT` | `7881` | Port for WebRTC fallback over TCP. |
| `RTC_UDP_PORT` | `7882` | Single UDP port for WebRTC UDP Mux. |
| `TURN_ENABLED` | `true` | Enable built-in TURN server for NAT bypass. |
| `TURN_DOMAIN` | `turn.example.com` | Public subdomain pointing to the TURN server. |
| `TURN_UDP_PORT` | `3478` | Plain UDP TURN port. |
| `TURN_TLS_PORT` | `5349` | TURN over TLS port (requires certs). |
| `TURN_CERT_FILE` | *(empty)* | Optional path to TURN TLS certificate inside container. |
| `TURN_KEY_FILE` | *(empty)* | Optional path to TURN TLS key inside container. |
| `LIVEKIT_WS_URL` | `ws://livekit-server:7880` | Internal WS URL used by the Egress service. |
| `EGRESS_MINIO_ENDPOINT` | `http://minio:9000` | S3 API endpoint of your MinIO server. |
| `EGRESS_MINIO_ACCESS_KEY`| *(set in `.env`)* | MinIO admin access key. |
| `EGRESS_MINIO_SECRET_KEY`| *(set in `.env`)* | MinIO admin secret key. |
| `EGRESS_MINIO_BUCKET` | `livekit-recordings`| MinIO bucket for storing meeting recordings. |
| `EGRESS_MINIO_FORCE_PATH_STYLE` | `true` | Mandatory `true` value for MinIO/S3-compatible APIs. |

Do not commit a real `.env` file. Keep API secrets, storage credentials, production domains, and project-specific frontend origins in `.env` or Dokploy environment variables.

---

## Step-by-Step Dokploy Deployment

Dokploy handles deployments automatically from your Git repository. Follow these steps:

1. **Push Code to Git**: Push this folder (with its configs and scripts) to a private GitHub repository.
2. **Create Service in Dokploy**:
   - Open your Dokploy dashboard.
   - Go to **Compose** -> **Create Compose**.
   - Connect your GitHub repository and select the path pointing to this directory.
3. **Configure Environment Variables**:
   - In Dokploy, navigate to the **Environment** tab of the Compose service.
   - Add all environment variables from `.env.example` using your production values.
   - **Important**: To use your existing Dokploy-managed Redis (Option A), change `REDIS_URL` to your external Redis address (e.g. `redis://:pass@dokploy-redis.internal:6379/0`).
4. **Deploy**:
   - Click **Deploy** in the Dokploy dashboard.
   - The containers will pull, execute the automated `init.sh` script to parse configuration parameters, and start up cleanly.
5. **Set up Domain & SSL**:
   - In the Dokploy Compose dashboard under the `livekit-server` service configuration, add the domain from `LIVEKIT_DOMAIN`.
   - Set the internal port to route to as `7880` or your configured `LIVEKIT_PORT`.
   - Enable SSL. Dokploy will generate the certificate via Let's Encrypt and handle HTTPS/WSS termination.
   - Do not route this domain to egress, Redis, your frontend, or your backend.

---

## Egress & MinIO Integration (Phase 2)

The LiveKit Egress container includes pre-mapped environment variables for MinIO connectivity.
When initiating a recording or streaming task from your backend using the LiveKit SDK, pass the S3/MinIO upload settings from environment variables.

### Go SDK Recording Example
```go
import (
	"context"
	"os"

	"github.com/livekit/protocol/livekit"
	lksdk "github.com/livekit/server-sdk-go"
)

func StartRoomRecording(roomName string) error {
	livekitURL := os.Getenv("LIVEKIT_URL")
	apiKey := os.Getenv("LIVEKIT_API_KEY")
	apiSecret := os.Getenv("LIVEKIT_API_SECRET")
	minioAccessKey := os.Getenv("EGRESS_MINIO_ACCESS_KEY")
	minioSecretKey := os.Getenv("EGRESS_MINIO_SECRET_KEY")
	minioBucket := os.Getenv("EGRESS_MINIO_BUCKET")
	minioEndpoint := os.Getenv("EGRESS_MINIO_ENDPOINT")

	egressClient := lksdk.NewEgressClient(livekitURL, apiKey, apiSecret)

	// Define MinIO output settings
	s3Output := &livekit.S3Upload{
		AccessKey:      minioAccessKey,
		Secret:         minioSecretKey,
		Bucket:         minioBucket,
		Endpoint:       minioEndpoint,
		ForcePathStyle: true,
	}

	request := &livekit.RoomCompositeEgressRequest{
		RoomName:  roomName,
		Layout:    "speaker",
		FileOutputs: []*livekit.EncodedFileOutput{
			{
				Filepath: "recordings/" + roomName + "-{time}.mp4",
				FileType: livekit.FileType_FILE_MP4,
				Upload:   &livekit.EncodedFileOutput_S3{S3: s3Output},
			},
		},
	}

	_, err := egressClient.StartRoomCompositeEgress(context.Background(), request)
	return err
}
```

---

## Operational Guide (Backups & Restores)

### 1. Backup Strategy
If you are using the **local Redis** container, you should back up the Redis dump database periodically. If you use an external Redis, this is handled by your external database provider.

#### Manual Redis Backup
Run this command (can be cron-scheduled) to copy the Redis database dump to the backups folder:
```bash
docker exec -t livekit-redis redis-cli SAVE
docker cp livekit-redis:/data/dump.rdb ./backups/redis_dump_$(date +%F_%T).rdb
```

#### Configuration Backup
All active configuration files reside in the `./config` folder. Since they are generated dynamically from environment variables, backing up the `.env` file (or Dokploy dashboard settings) is sufficient.

### 2. Restore Strategy
To restore the stack:
1. Re-deploy the stack on Dokploy using the compose configuration.
2. If using local Redis, stop the Redis container, copy your backup `rdb` file back, and restart it:
   ```bash
   docker compose stop redis
   docker cp ./backups/redis_dump_xyz.rdb livekit-redis:/data/dump.rdb
   docker compose start redis
   ```

---

## Updating LiveKit

To update the LiveKit Server or Egress components to newer versions:
1. Open `docker-compose.yml`.
2. Locate the `image:` tags for `livekit-server` and `livekit-egress`.
3. Update the versions to explicit pinned tags after checking LiveKit release notes. Do not use `latest` for production. Current pins are `livekit/livekit-server:v1.13.2` and `livekit/egress:v1.13.0`.
4. Commit and push the changes to GitHub. Dokploy will pull the changes and redeploy.

---

## Troubleshooting & Diagnostics

### 1. Automated Diagnostics Script
A comprehensive diagnostics tool is provided under `scripts/diagnose.sh` to analyze the deployment on the host. Run it directly on the VPS host:
```bash
./scripts/diagnose.sh
```
This script automates checking:
- Container status for `livekit-server` and `livekit-egress`.
- Host port binding conflicts.
- Redacted `/tmp/livekit.yaml` and `/tmp/egress.yaml` files.
- Redis container-to-container network resolution over the shared `dokploy-network`.
- Core server and egress logs.
- LiveKit image versions and reported server version.
- Browser RTC validation path `/rtc/v1/validate` and CORS headers.

### 2. Manual Diagnostics
You can manually check configurations and logs using standard Docker Compose commands:
```bash
# Inspect generated config files inside containers (contains secrets)
docker exec -it livekit-server cat /tmp/livekit.yaml
docker exec -it livekit-egress cat /tmp/egress.yaml

# View startup and service logs
docker compose logs --tail=100 -f livekit-server
docker compose logs --tail=100 -f livekit-egress
```

### 3. Connection Testing & WebRTC Verification
> [!IMPORTANT]
> **Root URL HTTP 404 is Normal**: Opening `https://<LIVEKIT_DOMAIN>` in a browser may return `404 page not found`. This is expected because the LiveKit core server does not expose a standard website/homepage. It only accepts WebSocket upgrades and API calls. Do not treat a root 404 as a deployment failure.

To test the server connection correctly:
1. **Client Connection URL**: Your clients/frontend apps must connect using the WebSocket secure protocol:
   ```text
   wss://<LIVEKIT_DOMAIN>
   ```
2. **Generate a Test Token**: Generate a participant token using a LiveKit SDK on your backend. Make sure the token is signed with the same `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` used to deploy the server.
3. **Use the Connection Tester**:
   - Go to the official [LiveKit Connection Test tool](https://connection-test.livekit.io/).
   - Enter your public LiveKit WebSocket URL: `wss://<LIVEKIT_DOMAIN>`.
   - Paste your generated test token and click **Start Test** to verify connectivity, TCP fallback, and UDP media relay.

---

## Integration Details for Client Projects

To connect an application stack to this LiveKit deployment, configure the following parameters in that application's environment.

### Backend Integration
Ensure your backend uses these environment variables:
- `LIVEKIT_API_KEY`: Must match the api key deployed on the server.
- `LIVEKIT_API_SECRET`: Must match the secret deployed on the server.
- `LIVEKIT_URL`: Set to `https://<LIVEKIT_DOMAIN>` for HTTP API calls.

### Frontend Integration
Ensure the Web/Client application uses the WebSocket protocol for real-time room communication:
- `NEXT_PUBLIC_LIVEKIT_URL` / `REACT_APP_LIVEKIT_URL`: Set to `wss://<LIVEKIT_DOMAIN>`.
- The frontend origin must be included in `LIVEKIT_ALLOWED_ORIGINS`.

### Egress Service Integration
- **Internal WS URL**: The egress container connects internally inside the Docker network. Ensure it is configured with:
  `LIVEKIT_WS_URL=ws://livekit-server:7880`
- **Shared Redis Database**: Egress connects to the exact same Redis database as LiveKit Server through `REDIS_URL`.

---

## Scaling Recommendations

1. **Egress Isolation**: Egress requires high CPU and RAM because it spawns a headless Chrome instance to render layout and record. In a high-traffic production environment, we recommend deploying the `livekit-egress` service on a **dedicated CPU-optimized instance** separate from the main signaling server.
2. **Bandwidth constraints**: WebRTC is bandwidth-heavy. Ensure the VPS network interface is uncapped (minimum 1 Gbps recommended for large production rooms).
3. **Clustering**: For multi-server scaling, LiveKit requires multiple server instances connected to a shared Redis cluster. The Redis server coordinates routing. You can spin up additional `livekit-server` containers across multiple VMs, pointing them to the same `REDIS_URL`.
