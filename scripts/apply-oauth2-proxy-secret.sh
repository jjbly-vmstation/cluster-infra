#!/usr/bin/env bash
set -euo pipefail

NS=identity

# WARNING: Do NOT create the oauth2-proxy-secrets secret manually. Always use this script to ensure correct formatting and values.

# Extract Grafana client secret stored by keycloak-create-clients.sh
CLIENT_SECRET=$(kubectl -n "$NS" get secret keycloak-grafana-client-secret -o jsonpath='{.data.client_secret}' 2>/dev/null |
  { base64 -d 2>/dev/null || base64 --decode 2>/dev/null; } || true)
if [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: client secret not found in k8s secret keycloak-grafana-client-secret in namespace $NS" >&2
  echo "Ensure the Keycloak clients were created (scripts/keycloak-create-clients.sh) or run the identity playbook to create them." >&2
  exit 1
fi

# Generate 32 random bytes as hex (64 hex chars = 32 bytes when oauth2-proxy decodes)
# oauth2-proxy expects exactly 32 bytes for AES cipher, hex encoding provides this
COOKIE_SECRET=$(openssl rand -hex 32)

# Validate cookie secret length (should be 64 hex chars = 32 bytes)
LEN=${#COOKIE_SECRET}
if [[ "$LEN" != "64" ]]; then
  echo "ERROR: Generated cookie secret is invalid length ($LEN chars). Must be 64 hex chars (32 bytes)." >&2
  exit 2
fi

# Validate client secret is non-empty
if [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: Client secret is empty. Aborting." >&2
  exit 3
fi

echo "Applying oauth2-proxy secret in namespace $NS"
kubectl -n "$NS" create secret generic oauth2-proxy-secrets \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Restarting oauth2-proxy deployment"
kubectl -n "$NS" rollout restart deployment/oauth2-proxy || true
kubectl -n "$NS" rollout status deployment/oauth2-proxy --timeout=120s || true

echo "Done. If the deployment still fails, check pods and logs:"
echo "  kubectl -n $NS get pods -l app=oauth2-proxy -o wide"
echo "  kubectl -n $NS logs -l app=oauth2-proxy --tail=200"
