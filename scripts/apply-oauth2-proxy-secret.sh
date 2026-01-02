#!/usr/bin/env bash
set -euo pipefail

NS=identity
# Extract Grafana client secret stored by keycloak-create-clients.sh
CLIENT_SECRET=$(kubectl -n "$NS" get secret keycloak-grafana-client-secret -o jsonpath='{.data.client_secret}' 2>/dev/null | base64 --decode || true)
if [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: client secret not found in k8s secret keycloak-grafana-client-secret in namespace $NS"
  echo "Ensure the Keycloak clients were created (scripts/keycloak-create-clients.sh) or run the identity playbook to create them." >&2
  exit 1
fi

# Generate a 16-byte random AES key and base64-encode it (results in a 24-char base64 string)
COOKIE_SECRET=$(python3 - <<'PY'
import os,base64
print(base64.b64encode(os.urandom(16)).decode())
PY
)

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
