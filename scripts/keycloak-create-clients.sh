#!/usr/bin/env bash
set -euo pipefail

# Usage: keycloak-create-clients.sh --realm <realm> --namespace <ns> --clients '<json array>'
# This script execs into the Keycloak pod and uses kcadm.sh to create/update clients

REALM=master
KEYCLOAK_NS=identity
CLIENTS_JSON=

usage(){
  cat <<EOF
Usage: $0 --realm <realm> --namespace <namespace> --clients '<json array>'
Clients JSON example:
  '[{"name":"grafana","redirectUris":["https://grafana.vmstation.local/"]}]'
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --realm) REALM="$2"; shift 2;;
    --namespace) KEYCLOAK_NS="$2"; shift 2;;
    --clients) CLIENTS_JSON="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg $1"; usage;;
  esac
done

if [ -z "$CLIENTS_JSON" ]; then
  echo "clients JSON required" >&2
  usage
fi

POD=$(kubectl -n "$KEYCLOAK_NS" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "No Keycloak pod found in namespace $KEYCLOAK_NS" >&2
  exit 2
fi

kc_exec(){
  kubectl -n "$KEYCLOAK_NS" exec "$POD" -- bash -lc "$1"
}

KC_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-secret}"

# Find kcadm.sh inside the Keycloak pod (try common locations, which, then find)
echo "Detecting kcadm.sh path inside Keycloak pod $POD"
KCADM_PATH=$(kubectl -n "$KEYCLOAK_NS" exec "$POD" -- sh -lc '
  for p in /opt/keycloak/bin/kcadm.sh /opt/jboss/keycloak/bin/kcadm.sh /opt/keycloak/bin/kcadm /usr/local/bin/kcadm.sh; do
    [ -x "$p" ] && echo "$p" && exit 0
  done
  if command -v kcadm.sh >/dev/null 2>&1; then
    command -v kcadm.sh && exit 0
  fi
  find / -name kcadm.sh -type f 2>/dev/null | head -n1 || true
'  2>/dev/null || true)

if [ -z "$KCADM_PATH" ]; then
  echo "Failed to locate kcadm.sh inside Keycloak pod $POD" >&2
  exit 3
fi

echo "Using kcadm at: $KCADM_PATH"

echo "Logging into Keycloak pod $POD"

# Robust login: try several times with backoff and try both server forms (/ and /auth)
try_login(){
  local attempt=1
  local max_attempts=12
  local sleep_s=5
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: kcadm login..."
    # Try without specifying a client (server will accept username/password for admin)
    if kc_exec "$KCADM_PATH config credentials --server http://localhost:8080 --realm master --user ${KC_ADMIN_USER} --password ${KC_ADMIN_PASS}" 2>/dev/null; then
      return 0
    fi
    # Try using the common admin CLI client name
    if kc_exec "$KCADM_PATH config credentials --server http://localhost:8080 --realm master --user ${KC_ADMIN_USER} --client admin-cli --password ${KC_ADMIN_PASS}" 2>/dev/null; then
      return 0
    fi
    # try legacy /auth path variants
    if kc_exec "$KCADM_PATH config credentials --server http://localhost:8080/auth --realm master --user ${KC_ADMIN_USER} --password ${KC_ADMIN_PASS}" 2>/dev/null; then
      return 0
    fi
    if kc_exec "$KCADM_PATH config credentials --server http://localhost:8080/auth --realm master --user ${KC_ADMIN_USER} --client admin-cli --password ${KC_ADMIN_PASS}" 2>/dev/null; then
      return 0
    fi
    echo "Login attempt $attempt failed, sleeping ${sleep_s}s..."
    sleep $sleep_s
    attempt=$((attempt+1))
  done
  return 1
}

if ! try_login; then
  echo "Failed to authenticate to Keycloak admin after retries; ensure admin credentials exist and Keycloak admin API is reachable" >&2
  echo "Showing last 200 lines of Keycloak pod logs for debugging:" >&2
  kubectl -n "$KEYCLOAK_NS" logs "$POD" --tail=200 >&2 || true
  exit 3
fi

echo "$CLIENTS_JSON" | jq -c '.[]' -r | while read -r client; do
  name=$(echo "$client" | jq -r '.name')
  redirects=$(echo "$client" | jq -c '.redirectUris')
  # Optional fields: baseUrl, webOrigins, adminUrl
  baseUrl=$(echo "$client" | jq -r '.baseUrl // empty')
  webOrigins=$(echo "$client" | jq -c '.webOrigins // empty')
  adminUrl=$(echo "$client" | jq -r '.adminUrl // empty')

  # If baseUrl not provided, use first redirect URI (if any)
  if [ -z "$baseUrl" ] && [ "$redirects" != "null" ] && [ -n "$redirects" ]; then
    baseUrl=$(echo "$redirects" | jq -r '.[0] // empty' 2>/dev/null || true)
  fi

  # If webOrigins not provided, derive from redirectUris by stripping trailing slash
  if [ "$webOrigins" = "null" ] || [ -z "$webOrigins" ]; then
    if [ "$redirects" != "null" ] && [ -n "$redirects" ]; then
      webOrigins=$(echo "$redirects" | jq -c 'map(sub("/$"; ""))' 2>/dev/null || echo "[]")
    else
      webOrigins="[]"
    fi
  fi

  echo "Creating/updating client: $name"
  # remove existing client if present to simplify idempotency
  # Query existing client (suppress stderr that may contain non-JSON warnings)
  EXIST=$(kc_exec "$KCADM_PATH get clients -r ${REALM} -q clientId=${name} -o json" 2>/dev/null || true)
  if [ -n "$EXIST" ] && [ "$EXIST" != "[]" ]; then
    ID=$(echo "$EXIST" | jq -r '.[0].id' 2>/dev/null || true)
    if [ -n "$ID" ]; then
      kc_exec "$KCADM_PATH delete clients/$ID -r ${REALM} || true" || true
    fi
  fi

  # Create client (don't fail the whole script on a non-zero exit here so we can attempt to recover)
  kc_exec "$KCADM_PATH create clients -r ${REALM} -s clientId=${name} -s 'directAccessGrantsEnabled=true' -s 'publicClient=false' -s 'serviceAccountsEnabled=true' -s 'standardFlowEnabled=true'" || true

  # Read back the new client id; tolerate non-JSON noise on stderr
  NEW_ID=$(kc_exec "$KCADM_PATH get clients -r ${REALM} -q clientId=${name} -o json" 2>/dev/null | jq -r '.[0].id' 2>/dev/null || true)
  if [ -z "$NEW_ID" ]; then
    echo "Failed to determine new client id for $name; skipping redirectUris and secret extraction" >&2
    continue
  fi

  # Build update options for redirectUris, baseUrl, webOrigins, adminUrl
  update_opts="-s 'redirectUris=${redirects}'"
  if [ -n "$baseUrl" ] && [ "$baseUrl" != "null" ]; then
    update_opts="$update_opts -s 'baseUrl=${baseUrl}'"
  fi
  if [ -n "$webOrigins" ] && [ "$webOrigins" != "null" ]; then
    update_opts="$update_opts -s 'webOrigins=${webOrigins}'"
  fi
  if [ -n "$adminUrl" ] && [ "$adminUrl" != "null" ]; then
    update_opts="$update_opts -s 'adminUrl=${adminUrl}'"
  fi

  # Update client with constructed options (tolerate noisy stderr)
  kc_exec "$KCADM_PATH update clients/${NEW_ID} -r ${REALM} $update_opts" 2>/dev/null || true

  # obtain secret (suppress noisy stderr)
  SECRET_JSON=$(kc_exec "$KCADM_PATH get clients/${NEW_ID}/client-secret -r ${REALM}" 2>/dev/null || true)
  SECRET=$(echo "$SECRET_JSON" | jq -r '.value' 2>/dev/null || true)

  if [ -z "$SECRET" ] || [ "$SECRET" = "null" ]; then
    echo "Warning: could not extract client secret for $name; skipping secret creation" >&2
  else
    echo "Storing secret for $name as k8s Secret keycloak-${name}-client-secret"
    kubectl -n "$KEYCLOAK_NS" create secret generic "keycloak-${name}-client-secret" --from-literal=client_secret="$SECRET" --dry-run=client -o yaml | kubectl apply -f -
  fi
done

echo "Keycloak client creation complete"
