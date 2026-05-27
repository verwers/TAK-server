#!/usr/bin/env bash
# init-admin.sh
# Admin elevation for TAK Server.
# Waits for TAK Server to be healthy, then attempts to elevate the admin
# user via UserManager (best-effort).

set -euo pipefail

# UserManager certmod talks to the database via Hibernate, so it only
# succeeds once TAK Server has finished bootstrapping the schema. The
# easiest readiness signal we have inside the container is the Marti API
# port (8443) accepting TCP connections.

TAK_READY_HOST="${TAK_READY_HOST:-127.0.0.1}"
TAK_READY_PORT="${TAK_READY_PORT:-8443}"
TAK_READY_TIMEOUT="${TAK_READY_TIMEOUT:-600}"
TAK_READY_INTERVAL="${TAK_READY_INTERVAL:-5}"

log_admin() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [admin] $*" | tee -a /opt/tak/logs/init.log
}

wait_for_tak_ready() {
  local deadline=$(( $(date +%s) + TAK_READY_TIMEOUT ))
  log_admin INFO "Waiting up to ${TAK_READY_TIMEOUT}s for TAK Server on ${TAK_READY_HOST}:${TAK_READY_PORT}..."
  while (( $(date +%s) < deadline )); do
    if (exec 3<>"/dev/tcp/${TAK_READY_HOST}/${TAK_READY_PORT}") 2>/dev/null; then
      exec 3>&- 3<&- || true
      log_admin INFO "TAK Server is accepting connections on ${TAK_READY_HOST}:${TAK_READY_PORT}"
      return 0
    fi
    sleep "$TAK_READY_INTERVAL"
  done
  log_admin WARN "TAK Server did not become ready within ${TAK_READY_TIMEOUT}s; attempting elevation anyway"
  return 1
}

elevate_admin_cert() {
  local admin_cert="/opt/tak/certs/files/admin.pem"

  if [[ ! -f "$admin_cert" ]]; then
    log_admin WARN "Admin certificate not found at $admin_cert"
    return 1
  fi

  local cmd=(java -jar /opt/tak/utils/UserManager.jar certmod -A "$admin_cert")

  local max_retries=12
  local retry_interval=5

  for i in $(seq 1 "$max_retries"); do
    if "${cmd[@]}" 2>&1 | tee -a /opt/tak/logs/init.log; then
      log_admin INFO "Admin elevation succeeded on attempt $i"
      return 0
    fi

    if (( i < max_retries )); then
      log_admin INFO "Admin elevation attempt $i/$max_retries failed; retrying in ${retry_interval}s"
      sleep "$retry_interval"
    else
      log_admin WARN "Admin elevation failed after ${max_retries} attempts"
      return 1
    fi
  done

  return 1
}

log_admin INFO "TAK Server admin elevation initialization (background)"

wait_for_tak_ready || true

if elevate_admin_cert; then
  log_admin INFO "Admin elevation completed successfully"
else
  log_admin WARN "Admin elevation failed (may require manual intervention)"
fi

log_admin INFO "Admin elevation process complete"