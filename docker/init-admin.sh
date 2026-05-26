#!/usr/bin/env bash
# init-admin.sh
# Admin elevation for TAK Server.
# Attempts to elevate the admin user via UserManager (best-effort).

set -euo pipefail

# Simplified admin elevation (don't source init-env.sh to avoid propagation issues)

elevate_admin_cert() {
  local admin_cert="/opt/tak/certs/files/admin.pem"
  
  if [[ ! -f "$admin_cert" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Admin certificate not found at $admin_cert" | tee -a /opt/tak/logs/init.log
    return 1
  fi
  
  local cmd=(java -jar /opt/tak/utils/UserManager.jar certmod -A "$admin_cert")
  
  # Retry up to 60 times with 10-second intervals (10 minutes total)
  local max_retries=60
  local retry_interval=10
  
  for i in $(seq 1 "$max_retries"); do
    if "${cmd[@]}" 2>&1 | tee -a /opt/tak/logs/init.log; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Admin elevation succeeded after $((i * retry_interval))s" | tee -a /opt/tak/logs/init.log
      return 0
    fi
    
    if [[ $i -lt $max_retries ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Admin elevation failed; retrying in ${retry_interval}s ($i/$max_retries)" | tee -a /opt/tak/logs/init.log
      sleep "$retry_interval"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Admin elevation failed after $((max_retries * retry_interval))s" | tee -a /opt/tak/logs/init.log
      return 1
    fi
  done
  
  return 1
}

# ============================================================================
# Main Initialization (Background Process)
# ============================================================================

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] TAK Server admin elevation initialization (background)" | tee -a /opt/tak/logs/init.log

# Wait a bit for the server to fully initialize before attempting elevation
initial_wait=15
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Waiting ${initial_wait}s for TAK Server to initialize..." | tee -a /opt/tak/logs/init.log
sleep "$initial_wait"

# Attempt admin elevation (best-effort; doesn't block startup)
if elevate_admin_cert; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Admin elevation completed successfully" | tee -a /opt/tak/logs/init.log
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Admin elevation failed (may require manual intervention)" | tee -a /opt/tak/logs/init.log
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Admin elevation process complete" | tee -a /opt/tak/logs/init.log
