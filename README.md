# TAK Server — Docker template

A minimal, opinionated Docker Compose setup for [TAK Server](https://tak.gov/).
Brings up TAK Server + its PostgreSQL/PostGIS database, generates a root CA, a
single server cert covering every hostname you list, one client cert per user,
and a ready-to-import Data Package (`.dp.zip`) per user.

## Compliance & Security Notice

**TAK Server** is official software distributed by the U.S. government via
<https://tak.gov/>. This repository contains **only deployment tooling** — it
does **not** redistribute the TAK Server release. You must download the release
zip yourself from tak.gov (registration required). U.S. export control rules
(EAR/ITAR) may apply to how you use and distribute TAK Server; you are
responsible for compliance.

**Default passwords (`atakatak`) in `.env.example` are well known and intended
only for local, throwaway testing.** Always change `POSTGRES_PASSWORD` and
`TAK_CERT_PASSWORD` to strong, unique values before exposing the server to any
network. Generated certificates and private keys under `data/certs/` are
secrets — keep them off version control (this repo's `.gitignore` already
excludes them).

## Prerequisites

- Docker + Docker Compose v2
- The official TAK Server Docker release zip from <https://tak.gov/products/tak-server>,
  e.g. `takserver-docker-5.7-RELEASE-43.zip`. **Drop it at the repository
  root** — the Dockerfile picks it up from the build context.

## Quick Start (All Platforms)

**Recommended:** Use the platform-appropriate helper for setup and deployment:

### Windows
```powershell
# Native PowerShell (recommended)
.\make.ps1 setup
.\make.ps1 deploy
.\make.ps1 verify

# OR via the batch wrapper (forwards to make.ps1)
.\make.cmd setup
.\make.cmd deploy
.\make.cmd verify

# OR call the individual scripts directly
# (PowerShell accepts either .\ or ./ as the path prefix)
.\setup.ps1
.\verify-deployment.ps1
.\status.ps1
.\validate-env.ps1

# OR use the Docker wrapper (no local PowerShell/bash needed)
.\scripts\run-in-docker.ps1 setup
.\scripts\run-in-docker.ps1 deploy
.\scripts\run-in-docker.ps1 verify
```

### macOS / Linux
```bash
# Bash (native)
make setup
make deploy
make verify

# OR use Docker wrapper (maximum compatibility)
./scripts/run-in-docker.sh setup
./scripts/run-in-docker.sh deploy
./scripts/run-in-docker.sh verify
```

All three approaches work on all platforms. Choose based on your preference:
- **Windows:** Use `.\make.ps1` or `.\make.cmd` (native PowerShell, no Docker overhead), or call the per-task `*.ps1` scripts at the repo root directly.
- **macOS/Linux:** Use `make` (native Makefile + bash scripts under `scripts/`).
- **Any OS:** Use `run-in-docker.*` (Docker wrapper, most compatible).

## First-run

```sh
cp .env.example .env
# Edit .env: set SERVER_HOSTNAMES, CLIENT_NAMES, passwords, TAK_VERSION.

docker compose up -d --build
docker compose logs -f takserver   # watch cert generation + startup
```

On first boot the `takserver` container will:

1. Generate a root CA (`CA_NAME`).
2. Generate **one** server certificate whose CN is the first entry in
   `SERVER_HOSTNAMES` and whose SANs cover every entry — so clients can connect
   to any of those addresses with the same cert.
3. Generate a client cert for every name in `CLIENT_NAMES`, plus `admin`.
4. Build a Data Package per user as
   `data/certs/<user>-<canonical-host>.dp.zip`. Set `MULTI_HOST_DP=true` in
   `.env` to also produce one DP per `(user, host)` pair.
5. Try to elevate the `admin` cert via TAK's `UserManager` (best-effort, in
   the background).

Re-runs are idempotent: existing certs and DPs are not regenerated. To add a
user, append their name to `CLIENT_NAMES` and restart the `takserver` service.

## Ports

| Port | Purpose                              |
| ---- | ------------------------------------ |
| 8089 | CoT streaming (TLS, used by ATAK)    |
| 8443 | Marti / Web UI (TLS)                 |
| 8444 | Federation (TLS)                     |
| 8446 | Cert enrollment (TLS)                |
| 9000 | Federation v2                        |
| 9001 | Federation v2 (alt)                  |

Postgres is **not** exposed to the host by default — uncomment the `ports:`
block under `takserver-db` in [docker-compose.yml](docker-compose.yml) if you
need direct DB access.

## Persistence

The Postgres database and server logs live in **external** Docker volumes
named `takserver-db-data` and `takserver-logs`, plus a shared
`takserver-net` network. The `make deploy` / `.\make.ps1 deploy` targets
create them automatically on first run.

Because they are external:

- `docker compose down` and even `docker compose down -v` leave them intact.
- Bumping `TAK_VERSION` (which renames the Compose project) does **not**
  recreate them — your database survives TAK Server upgrades.
- The only command that actually wipes them is `make reset` /
  `.\make.ps1 reset`, which is intentionally destructive.

If you need to inspect or back up the data:

```sh
docker run --rm -v takserver-db-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/takserver-db-backup.tgz -C /data .
```

## Handing out Data Packages

The generated `.dp.zip` files live in [data/certs/](data/certs/). Get them onto
your end-user devices however you like (USB, AirDrop, ATAK's "Import" flow,
etc.). For quick LAN sharing there's a helper:

```sh
# Safe default: serves on http://127.0.0.1:12345/
./scripts/shareCerts.sh

# Explicitly opt in to LAN-wide sharing:
./scripts/shareCerts.sh --public --port 8000
```

Note that this serves the files over plain HTTP with no authentication. Stop
the server (`Ctrl-C`) once clients have downloaded what they need.

## Configuration reference

See [.env.example](.env.example) for the full list of variables and what they
do. The most important ones:

- `TAK_VERSION` — must match the zip filename you placed at the repo root.
- `SERVER_HOSTNAMES` — comma-separated; first entry is the cert CN, every
  entry becomes a SAN.
- `CLIENT_NAMES` — comma-separated list of users to provision.
- `TAK_CERT_PASSWORD` / `POSTGRES_PASSWORD` — **change these** before exposing
  the server anywhere non-trivial.

## Platform-Specific Setup

### Windows Requirements

**PowerShell 5.1+ (built-in) or PowerShell 7+ (recommended)**

To check your PowerShell version:
```powershell
$PSVersionTable.PSVersion
```

**Execution Policy:** If you get "cannot be loaded because running scripts is disabled," run this once:
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
```

Then you can use:
```powershell
.\make.ps1 setup
# OR simply
make setup              # (requires make.cmd)
```

**Alternative: Use WSL 2 (Windows Subsystem for Linux)**

If you have WSL 2 installed, you can use the native bash scripts:
```bash
wsl
make setup
make deploy
make verify
```

### macOS Requirements

**Python 3 and pip** (for Docker Compose if needed):
```bash
brew install python3 docker-compose
```

Or install **Docker Desktop for Mac** which includes Docker Compose:
https://www.docker.com/products/docker-desktop

### Linux

All tools are typically pre-installed. Standard make + bash work natively.

## Improved Workflow (Recommended)

**TL;DR:** Use the interactive setup wizard and Makefile/PowerShell commands for a streamlined experience:

**Windows:**
```powershell
make setup                # Interactive .env configuration
make deploy               # Build, start, and verify
make verify               # Check if everything is working
make test-client          # Test actual client connection
make status               # Show deployment health
```

**macOS/Linux:**
```bash
make setup                # Interactive .env configuration
make deploy               # Build, start, and verify
make verify               # Check if everything is working
make test-client          # Test actual client connection
make status               # Show deployment health
```

The new tooling provides better error messages, validation, and verification to confirm clients can actually connect.

## Quick Reference: Make Commands

```makefile
make help                 # Show all commands
make setup                # Run interactive setup wizard
make validate             # Pre-flight .env validation
make deploy               # Full deployment with verification
make verify               # Post-deployment health check
make status               # Detailed status report
make test-client          # Attempt client TLS connection
make logs                 # Watch TAK Server logs
make restart              # Restart containers
```

For complete documentation, see the [Makefile](Makefile) or run `make help`.

## Layout

```
docker-compose.yml              compose definition (db + takserver)
Makefile                        convenience commands (macOS / Linux / WSL)
make.cmd                        Windows entry point — forwards to make.ps1
make.ps1                        PowerShell implementation of the make targets
.env.example                    copy to .env and edit
setup.ps1                       interactive setup wizard (Windows)
validate-env.ps1                pre-flight .env validation (Windows)
verify-deployment.ps1           post-deployment verification (Windows)
status.ps1                      health check & monitoring (Windows)
docker/
  Dockerfile.tak                multi-stage build: tak-dist -> takserver / takserver-db
  takserver-entrypoint.sh       orchestrator: calls init-*.sh then starts TAK
  init-env.sh                   environment setup & validation
  init-config.sh                CoreConfig setup (DB password injection)
  init-certs.sh                 certificate generation (root CA, server, client)
  init-datapackages.sh          create .dp.zip Data Packages
  init-admin.sh                 admin elevation (background, best-effort)
  validate-env.sh               pre-flight .env validation (in-container)
  test-client-connection.sh     test client TLS connection (in-container)
  certDP.sh                     builds one .dp.zip from CA truststore + user cert
  tools.dockerfile              optional image with helper CLI tools
scripts/
  setup.sh                      interactive setup wizard (macOS / Linux)
  verify-deployment.sh          post-deployment verification (macOS / Linux)
  status.sh                     health check & monitoring (macOS / Linux)
  shareCerts.sh                 quick LAN HTTP server for distributing DPs
  run-in-docker.sh              run any target in a throwaway container (bash)
  run-in-docker.ps1             run any target in a throwaway container (PowerShell)
datapackages/                   example map source DPs you can import in ATAK
data/certs/                     generated certs + DPs (gitignored)
```

Windows users get native PowerShell equivalents at the repo root for the
scripts that would otherwise require bash; macOS and Linux users use the
`.sh` versions under `scripts/`. The `make` targets dispatch to the right
implementation automatically.


## Troubleshooting

### "Cannot connect to server" / "Certificate error"

**Root cause:** Client cert or connection isn't working.

**Diagnosis:**
```sh
make verify               # Check if infrastructure is ready
make test-client          # Attempt actual TLS connection
docker logs $(docker ps -q -f name=takserver) | grep -i error
```

**Fixes:**
- Ensure port 8089 is reachable: `nc -zv <hostname> 8089`
- Verify certificate generation: `ls -la data/certs/files/ | grep .p12`
- Check Data Package contents: `unzip -l data/certs/<user>-*.dp.zip`
- Recreate client cert: `CLIENT_NAMES=<user> docker compose restart takserver`

### "Containers stuck / not starting"

**Diagnosis:**
```sh
make logs                 # Watch real-time logs
docker ps -a              # Check container status
docker logs takserver-db  # Check database startup
```

**Fixes:**
- Wait 30+ seconds (DB initialization takes time)
- Check logs for port conflicts: `nc -zv localhost 8089`
- Reset and restart: `make reset && make deploy`

### "Database connection refused"

**Diagnosis:**
```sh
make status               # Check DB health
docker exec $(docker ps -q -f name=takserver-db) pg_isready -U postgres
```

**Fixes:**
- Ensure `POSTGRES_PASSWORD` matches `TAK_DB_PASSWORD` in `.env`
- Check firewall/port binding: `make logs-db | tail -20`
- Reset DB: `make reset && make deploy` (note: `docker compose down -v` no
  longer wipes the database — the `takserver-db-data` volume is external on
  purpose, so it survives version bumps. Use `make reset` to fully wipe.)

### ".env validation fails"

**Diagnosis:**
```sh
make validate             # Shows which fields failed
cat .env                  # Review configuration
```

**Fixes:**
- Ensure `TAK_VERSION` matches a .zip file in project root
- Check `SERVER_HOSTNAMES` is non-empty (e.g., `takserver.example.com`)
- Verify `CLIENT_NAMES` use alphanumeric, underscore, hyphen only
- Re-run: `make setup`

### "Admin elevation failed"

**Status:** This is usually non-fatal. The server runs fine; admin just won't have elevated privileges initially.

**Manual fix:**
```sh
docker exec $(docker ps -q -f name=takserver) \
  java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem
```

### "How do I regenerate certificates?"

**For a single user:**
```sh
CLIENT_NAMES=<username> docker compose restart takserver
```

**For all users:**
```sh
rm -rf data/certs/files/*
docker compose restart takserver
```

### "How do I check initialization logs?"

```sh
docker exec $(docker ps -q -f name=takserver) tail -50 /opt/tak/logs/init.log
```

### "Ports seem blocked / connection timeout"

```sh
# Check which ports are listening
netstat -tulpn 2>/dev/null | grep 8089    # Linux
netstat -an | grep 8089                   # macOS / Windows

# Verify from inside container
docker exec $(docker ps -q -f name=takserver) nc -zv localhost 8089
```

## Verification Workflow

After deployment, verify everything is working:

```sh
# 1. Check infrastructure health
make verify

# 2. Show detailed status
make status

# 3. Test actual client connection
make test-client

# 4. If all pass, try importing a Data Package into ATAK
ls data/certs/*.dp.zip
```

If all checks pass, clients should be able to:
1. Import the `.dp.zip` Data Package into ATAK
2. Connect to the server on port 8089
3. See the server in the list of known contacts
