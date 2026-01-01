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

echo "Logging into Keycloak pod $POD"
if ! kc_exec "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user ${KC_ADMIN_USER} --password ${KC_ADMIN_PASS}" 2>/dev/null; then
  if ! kc_exec "/opt/jboss/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user ${KC_ADMIN_USER} --password ${KC_ADMIN_PASS}"; then
    echo "Failed to run kcadm.sh inside Keycloak pod; ensure admin credentials and kcadm path" >&2
    exit 3
  fi
fi

echo "$CLIENTS_JSON" | jq -c '.[]' -r | while read -r client; do
  name=$(echo "$client" | jq -r '.name')
  redirects=$(echo "$client" | jq -c '.redirectUris')

  echo "Creating/updating client: $name"
  # remove existing client if present to simplify idempotency
  EXIST=$(kc_exec "/opt/keycloak/bin/kcadm.sh get clients -r ${REALM} -q clientId=${name} -o json" || true)
  if [ -n "$EXIST" ] && [ "$EXIST" != "[]" ]; then
    ID=$(echo "$EXIST" | jq -r '.[0].id')
    kc_exec "/opt/keycloak/bin/kcadm.sh delete clients/$ID -r ${REALM} || true"
  fi

  kc_exec "/opt/keycloak/bin/kcadm.sh create clients -r ${REALM} -s clientId=${name} -s 'directAccessGrantsEnabled=true' -s 'publicClient=false' -s 'serviceAccountsEnabled=true' -s 'standardFlowEnabled=true'"
  NEW_ID=$(kc_exec "/opt/keycloak/bin/kcadm.sh get clients -r ${REALM} -q clientId=${name} -o json" | jq -r '.[0].id')
  kc_exec "/opt/keycloak/bin/kcadm.sh update clients/${NEW_ID} -r ${REALM} -s redirectUris=${redirects}"

  # obtain secret
  SECRET_JSON=$(kc_exec "/opt/keycloak/bin/kcadm.sh get clients/${NEW_ID}/client-secret -r ${REALM}")
  SECRET=$(echo "$SECRET_JSON" | jq -r '.value')

  echo "Storing secret for $name as k8s Secret keycloak-${name}-client-secret"
  kubectl -n "$KEYCLOAK_NS" create secret generic "keycloak-${name}-client-secret" --from-literal=client_secret="$SECRET" --dry-run=client -o yaml | kubectl apply -f -
done

echo "Keycloak client creation complete"
