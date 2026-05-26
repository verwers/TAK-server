#!/usr/bin/env bash
# Share generated certs/Data Packages over HTTP.
#
# WARNING: this serves files (CERTIFICATES and KEYS) over plain HTTP with
# *no authentication*. Anyone who can reach the bound address can download
# them. Use only on a trusted network and stop the server as soon as your
# clients have what they need.
#
# Usage:
#   ./shareCerts.sh            # bind to 127.0.0.1:12345 (safe default)
#   ./shareCerts.sh --public   # bind to 0.0.0.0:12345 (LAN sharing)
#   ./shareCerts.sh --public --port 8000
set -euo pipefail

BIND="127.0.0.1"
PORT="12345"
SRC_DIR="${TAK_CERT_DIR:-data/certs}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public) BIND="0.0.0.0"; shift ;;
    --port)   PORT="$2"; shift 2 ;;
    --src)    SRC_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ "${BIND}" != "127.0.0.1" ]]; then
  echo "WARNING: serving ${SRC_DIR}/*.zip on ${BIND}:${PORT} with NO auth."
  echo "         Anyone on this network can download these files."
fi

SHARE_DIR="$(mktemp -d)"
trap 'rm -rf "${SHARE_DIR}"' EXIT

shopt -s nullglob
zips=("${SRC_DIR}"/*.zip)
if [[ ${#zips[@]} -eq 0 ]]; then
  echo "No .zip files found in ${SRC_DIR}" >&2
  exit 1
fi
cp "${zips[@]}" "${SHARE_DIR}/"

echo "Serving ${#zips[@]} file(s) from ${SRC_DIR} on http://${BIND}:${PORT}/"
cd "${SHARE_DIR}"
exec python3 -m http.server --bind "${BIND}" "${PORT}"
