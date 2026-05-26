#!/usr/bin/env bash
# Build a TAK Data Package (DP) for a given user against a given server host.
#
# Layout of the resulting zip:
#   manifest.xml          - TAK DP manifest
#   server.pref           - ATAK/iTAK preferences (server URL, cert refs)
#   truststore-root.p12   - CA truststore the client uses to validate the
#                           server (this is the *standard* TAK pattern; do NOT
#                           ship the server's own .p12 here)
#   <user>.p12            - the user's client certificate
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <user> [<host>]

  user   client cert name (must exist as \${TAK_CERT_DIR}/<user>.p12)
  host   server hostname/IP clients should connect to
         (defaults to first entry of \${SERVER_HOSTNAMES})
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage

USER="$1"
HOST="${2:-}"

CERT_DIR="${TAK_CERT_DIR:-/opt/tak/certs/files}"
CERT_PASS="${TAK_CERT_PASSWORD:-atakatak}"

if [[ -z "${HOST}" ]]; then
  if [[ -n "${SERVER_HOSTNAMES:-}" ]]; then
    HOST="${SERVER_HOSTNAMES%%,*}"
    HOST="${HOST#"${HOST%%[![:space:]]*}"}"
    HOST="${HOST%"${HOST##*[![:space:]]}"}"
  fi
fi
[[ -n "${HOST}" ]] || { echo "ERROR: no host given and SERVER_HOSTNAMES unset" >&2; exit 1; }

# Locate the CA truststore produced by makeRootCa.sh / makeCert.sh. Different
# TAK releases have used slightly different filenames; accept the common ones.
TRUSTSTORE=""
for candidate in \
    "${CERT_DIR}/truststore-${CA_NAME:-root}.p12" \
    "${CERT_DIR}/truststore-root.p12" \
    "${CERT_DIR}/truststore-intermediate.p12" \
    "${CERT_DIR}/truststore-ROOT.p12"; do
  if [[ -f "${candidate}" ]]; then
    TRUSTSTORE="${candidate}"
    break
  fi
done
if [[ -z "${TRUSTSTORE}" ]]; then
  # Fall back to the first truststore-*.p12 we can find.
  TRUSTSTORE="$(find "${CERT_DIR}" -maxdepth 1 -type f -name 'truststore-*.p12' | head -n 1 || true)"
fi
[[ -n "${TRUSTSTORE}" && -f "${TRUSTSTORE}" ]] \
  || { echo "ERROR: no CA truststore (truststore-*.p12) found in ${CERT_DIR}" >&2; exit 2; }

USER_P12="${CERT_DIR}/${USER}.p12"
[[ -f "${USER_P12}" ]] || { echo "ERROR: missing ${USER_P12}" >&2; exit 2; }

TRUST_NAME="$(basename "${TRUSTSTORE}")"
USER_NAME="$(basename "${USER_P12}")"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

SERVER_PREF="${STAGE_DIR}/server.pref"
MANIFEST="${STAGE_DIR}/manifest.xml"

UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${USER}-${HOST}-$(date +%s)")"

cat > "${SERVER_PREF}" <<EOF
<?xml version='1.0' encoding='ASCII' standalone='yes'?>
<preferences>
  <preference version="1" name="cot_streams">
    <entry key="count" class="class java.lang.Integer">1</entry>
    <entry key="description0" class="class java.lang.String">TAK Server (${HOST})</entry>
    <entry key="enabled0" class="class java.lang.Boolean">true</entry>
    <entry key="connectString0" class="class java.lang.String">${HOST}:8089:ssl</entry>
  </preference>
  <preference version="1" name="com.atakmap.app_preferences">
    <entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>
    <entry key="caLocation" class="class java.lang.String">cert/${TRUST_NAME}</entry>
    <entry key="caPassword" class="class java.lang.String">${CERT_PASS}</entry>
    <entry key="clientPassword" class="class java.lang.String">${CERT_PASS}</entry>
    <entry key="certificateLocation" class="class java.lang.String">cert/${USER_NAME}</entry>
  </preference>
</preferences>
EOF

cat > "${MANIFEST}" <<EOF
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid" value="${UUID}"/>
    <Parameter name="name" value="${USER}@${HOST} TAK DP"/>
    <Parameter name="onReceiveDelete" value="true"/>
  </Configuration>
  <Contents>
    <Content ignore="false" zipEntry="server.pref"/>
    <Content ignore="false" zipEntry="${TRUST_NAME}"/>
    <Content ignore="false" zipEntry="${USER_NAME}"/>
  </Contents>
</MissionPackageManifest>
EOF

OUT_ZIP="${CERT_DIR}/${USER}-${HOST}.dp.zip"

# -j => store everything at the top level of the zip (TAK requirement).
zip -j "${OUT_ZIP}" \
  "${MANIFEST}" \
  "${SERVER_PREF}" \
  "${TRUSTSTORE}" \
  "${USER_P12}"

echo "-------------------------------------------------------------"
echo "Created Data Package for ${USER} @ ${HOST}: ${OUT_ZIP}"
