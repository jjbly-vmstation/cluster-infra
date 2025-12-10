#!/bin/bash
# Apply All Identity Stack Automation Changes
# Created: 2025-12-10T17:56:47Z
# Purpose: One-command application of all identity stack fixes and automation

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

PATCH_DIR="/opt/vmstation-org/diff-patches"

log_info "============================================================"
log_info "Identity Stack Automation - Apply All Changes"
log_info "============================================================"

# 1. Apply cert-manager patches
log_info "Step 1: Patching cert-manager deployments for masternode..."
kubectl patch deployment cert-manager-cainjector -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"masternode"}}}}}' 2>&1 | grep -v "no changes"|| true

kubectl patch deployment cert-manager-webhook -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"masternode"}}}}}' 2>&1 | grep -v "no changes" || true

log_info "Waiting for pods to reschedule..."
sleep 10

# 2. Deploy NodePort service
log_info "Step 2: Deploying Keycloak NodePort service..."
kubectl apply -f "${PATCH_DIR}/20251210T175647Z-keycloak-nodeport-service.yaml"

# 3. Setup admin user
log_info "Step 3: Setting up Keycloak admin user..."
"${PATCH_DIR}/20251210T175647Z-keycloak-admin-setup.sh"

# 4. Verify everything
log_info "============================================================"
log_info "Verification"
log_info "============================================================"

log_info "Cert-Manager Pods:"
kubectl get pods -n cert-manager -o wide

log_info ""
log_info "Identity Stack:"
kubectl get pods -n identity -o wide

log_info ""
log_info "NodePort Service:"
kubectl get svc -n identity keycloak-nodeport

log_info ""
log_info "ClusterIssuer:"
kubectl get clusterissuers

log_info ""
log_info "============================================================"
log_info "✅ All changes applied successfully!"
log_info "============================================================"
log_info ""
log_info "Admin credentials: /root/identity-backup/keycloak-admin-credentials.txt"
log_info ""
log_info "Access Keycloak from your desktop:"
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for IP in $NODE_IPS; do
    log_info "  - http://$IP:30080/auth"
done
log_info "============================================================"

exit 0
