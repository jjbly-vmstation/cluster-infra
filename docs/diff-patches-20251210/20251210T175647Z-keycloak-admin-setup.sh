#!/bin/bash
# Keycloak Admin User Setup and Desktop Access Configuration
# Created: 2025-12-10T17:56:47Z
# Purpose: Automate Keycloak admin user creation and desktop access configuration

set -euo pipefail

# Configuration
NAMESPACE="identity"
KEYCLOAK_POD="keycloak-0"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
DESKTOP_IP="${DESKTOP_IP:-192.168.4.0/24}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080/auth}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

# Generate strong password if not provided
if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(openssl rand -base64 32)
    log_warn "Generated random admin password: $ADMIN_PASSWORD"
    log_warn "SAVE THIS PASSWORD - it will not be shown again!"
fi

# Wait for Keycloak pod to be ready
log_info "Waiting for Keycloak pod to be ready..."
kubectl wait --for=condition=ready pod/$KEYCLOAK_POD -n $NAMESPACE --timeout=300s

# Check if admin user already exists
log_info "Checking if admin user exists..."
ADMIN_EXISTS=$(kubectl exec -n $NAMESPACE $KEYCLOAK_POD -- \
    /opt/jboss/keycloak/bin/kcadm.sh get users -r master --fields username 2>/dev/null | grep -c "\"$ADMIN_USER\"" || echo "0")

if [ "$ADMIN_EXISTS" -gt 0 ]; then
    log_warn "Admin user '$ADMIN_USER' already exists. Updating password..."
    # Update existing admin user password
    kubectl exec -n $NAMESPACE $KEYCLOAK_POD -- \
        /opt/jboss/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080/auth \
        --realm master \
        --user $ADMIN_USER \
        --password "$ADMIN_PASSWORD" 2>/dev/null || {
            log_error "Failed to authenticate with existing credentials"
            log_info "You may need to manually reset the password via pod console"
            exit 1
        }
else
    log_info "Creating admin user '$ADMIN_USER'..."
    kubectl exec -n $NAMESPACE $KEYCLOAK_POD -- \
        /opt/jboss/keycloak/bin/add-user-keycloak.sh \
        -r master -u $ADMIN_USER -p "$ADMIN_PASSWORD"
    
    # Restart Keycloak to apply changes
    log_info "Restarting Keycloak pod to apply admin user..."
    kubectl delete pod $KEYCLOAK_POD -n $NAMESPACE
    kubectl wait --for=condition=ready pod/$KEYCLOAK_POD -n $NAMESPACE --timeout=300s
fi

# Configure desktop access (via NodePort or Ingress)
log_info "Ensuring NodePort service exists for desktop access..."
kubectl apply -f /opt/vmstation-org/diff-patches/20251210T175647Z-keycloak-nodeport-service.yaml

# Get node IPs for access
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')

log_info "=============================================="
log_info "Keycloak Admin Setup Complete!"
log_info "=============================================="
log_info "Admin User: $ADMIN_USER"
log_info "Admin Password: $ADMIN_PASSWORD"
log_info ""
log_info "Access Keycloak from your desktop:"
for IP in $NODE_IPS; do
    log_info "  - http://$IP:30080/auth"
done
log_info ""
log_info "Admin Console:"
for IP in $NODE_IPS; do
    log_info "  - http://$IP:30080/auth/admin"
done
log_info "=============================================="

# Save credentials to secure location
CREDS_FILE="/root/identity-backup/keycloak-admin-credentials.txt"
mkdir -p /root/identity-backup
cat > "$CREDS_FILE" <<EOF
Keycloak Admin Credentials
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Username: $ADMIN_USER
Password: $ADMIN_PASSWORD

Access URLs:
$(for IP in $NODE_IPS; do echo "- http://$IP:30080/auth"; done)

Admin Console:
$(for IP in $NODE_IPS; do echo "- http://$IP:30080/auth/admin"; done)
EOF
chmod 600 "$CREDS_FILE"
log_info "Credentials saved to: $CREDS_FILE"

exit 0
