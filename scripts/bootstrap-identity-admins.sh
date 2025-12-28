#!/usr/bin/env bash
#
# bootstrap-identity-admins.sh
#
# Purpose: Bootstrap admin accounts for FreeIPA and Keycloak
# This script creates or verifies admin accounts and saves credentials securely.
# It is idempotent - will not recreate accounts that already exist.
#
# Usage:
#   sudo ./scripts/bootstrap-identity-admins.sh
#   sudo FREEIPA_ADMIN_PASSWORD=secret KEYCLOAK_ADMIN_PASSWORD=secret ./scripts/bootstrap-identity-admins.sh
#
# Environment Variables:
#   FREEIPA_ADMIN_PASSWORD  - FreeIPA admin password (default: auto-generate)
#   KEYCLOAK_ADMIN_PASSWORD - Keycloak admin password (default: auto-generate)
#   KUBECONFIG              - Path to kubeconfig (default: /etc/kubernetes/admin.conf)
#   NAMESPACE_IDENTITY      - Identity namespace (default: identity)
#   CREDENTIALS_DIR         - Where to save credentials (default: /root/identity-backup)
#   DRY_RUN                 - Set to "1" for dry-run mode (default: 0)
#

set -euo pipefail

# Source common functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/kubespray-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/kubespray-common.sh"
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration with defaults
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE_IDENTITY="${NAMESPACE_IDENTITY:-identity}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-/root/identity-backup}"
FREEIPA_ADMIN_PASSWORD="${FREEIPA_ADMIN_PASSWORD:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-0}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_fatal() {
    log_error "$*"
    exit 1
}

# Generate secure random password
generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
}

# Print banner
print_banner() {
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}Identity Admin Bootstrap Script${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
}

# Preflight checks
preflight_checks() {
    log_info "Running preflight checks..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root (use sudo)"
    fi
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_fatal "kubectl command not found - please install kubectl"
    fi
    
    # Check if kubeconfig exists
    if [[ ! -f "$KUBECONFIG" ]]; then
        log_fatal "Kubeconfig not found at $KUBECONFIG"
    fi
    
    # Test kubectl connectivity
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &> /dev/null; then
        log_fatal "Cannot connect to Kubernetes cluster - check kubeconfig and cluster status"
    fi
    
    # Check if identity namespace exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE_IDENTITY" &> /dev/null; then
        log_fatal "Identity namespace '$NAMESPACE_IDENTITY' does not exist - deploy identity stack first"
    fi
    
    log_success "Preflight checks passed"
}

# Wait for pod to be ready
wait_for_pod() {
    local pod_name="$1"
    local max_wait="${2:-300}"
    local elapsed=0
    
    log_info "Waiting for pod $pod_name to be ready (max ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pod "$pod_name" &> /dev/null; then
            local status
            status=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pod "$pod_name" -o jsonpath='{.status.phase}')
            
            if [[ "$status" == "Running" ]]; then
                # Check if container is ready
                local ready
                ready=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pod "$pod_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
                
                if [[ "$ready" == "True" ]]; then
                    log_success "Pod $pod_name is ready"
                    return 0
                fi
            fi
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Pod $pod_name did not become ready within ${max_wait}s"
    return 1
}

# Bootstrap Keycloak admin account
bootstrap_keycloak_admin() {
    log_info "Bootstrapping Keycloak admin account..."
    
    # Find Keycloak pod
    local keycloak_pod
    keycloak_pod=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$keycloak_pod" ]]; then
        log_warn "Keycloak pod not found - skipping Keycloak admin bootstrap"
        return 0
    fi
    
    # Wait for Keycloak to be ready
    if ! wait_for_pod "$keycloak_pod" 300; then
        log_warn "Keycloak pod not ready - skipping admin bootstrap"
        return 0
    fi
    
    # Check if admin password secret exists
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret keycloak-admin-creds &> /dev/null; then
        log_info "Keycloak admin credentials secret already exists"
        
        # Try to retrieve existing password
        local existing_password
        existing_password=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret keycloak-admin-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        
        if [[ -n "$existing_password" ]]; then
            KEYCLOAK_ADMIN_PASSWORD="$existing_password"
            log_success "Retrieved existing Keycloak admin password from secret"
        fi
    else
        # Generate password if not provided
        if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
            KEYCLOAK_ADMIN_PASSWORD=$(generate_password)
            log_info "Generated new Keycloak admin password"
        fi
        
        # Create secret
        if [[ "$DRY_RUN" != "1" ]]; then
            kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" create secret generic keycloak-admin-creds \
                --from-literal=username=admin \
                --from-literal=password="$KEYCLOAK_ADMIN_PASSWORD" \
                2>/dev/null || log_warn "Could not create Keycloak admin secret"
            
            log_success "Created Keycloak admin credentials secret"
        else
            log_info "[DRY-RUN] Would create Keycloak admin credentials secret"
        fi
    fi
    
    # Save credentials to file
    local creds_file="$CREDENTIALS_DIR/keycloak-admin-credentials.txt"
    if [[ "$DRY_RUN" != "1" ]]; then
        cat > "$creds_file" << EOF
Keycloak Administrator Credentials
Generated: $(date -Iseconds)

Username: admin
Password: $KEYCLOAK_ADMIN_PASSWORD

Access URL: http://<node-ip>:30180/auth

SECURITY NOTICE:
- This file contains sensitive credentials
- Keep it secure and backed up
- Change default passwords immediately in production

EOF
        chmod 600 "$creds_file"
        log_success "Saved Keycloak credentials to: $creds_file"
    else
        log_info "[DRY-RUN] Would save Keycloak credentials to: $creds_file"
    fi
    
    log_success "Keycloak admin bootstrap completed"
}

# Bootstrap FreeIPA admin account
bootstrap_freeipa_admin() {
    log_info "Bootstrapping FreeIPA admin account..."
    
    # Find FreeIPA pod
    local freeipa_pod
    freeipa_pod=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods -l app=freeipa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$freeipa_pod" ]]; then
        log_warn "FreeIPA pod not found - skipping FreeIPA admin bootstrap"
        return 0
    fi
    
    # Wait for FreeIPA to be ready (first install can take a long time)
    if ! wait_for_pod "$freeipa_pod" 1800; then
        log_warn "FreeIPA pod did not become ready in time - collecting diagnostics and skipping admin bootstrap"
        if [[ "$DRY_RUN" != "1" ]]; then
            kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" describe pod "$freeipa_pod" 2>/dev/null || true
            kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" logs "$freeipa_pod" -c freeipa-server --tail=200 2>/dev/null || true
            kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" exec "$freeipa_pod" -c freeipa-server -- \
                bash -lc 'systemctl status ipa --no-pager || true; tail -n 200 /var/log/ipa-server-configure-first.log 2>/dev/null || true; tail -n 200 /var/log/ipaserver-install.log 2>/dev/null || true' 2>/dev/null || true
        fi
        return 0
    fi
    
    # Generate password if not provided
    if [[ -z "$FREEIPA_ADMIN_PASSWORD" ]]; then
        # Check if password already exists in secret
        if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds &> /dev/null; then
            local existing_password
            existing_password=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
            
            if [[ -n "$existing_password" ]]; then
                FREEIPA_ADMIN_PASSWORD="$existing_password"
                log_info "Retrieved existing FreeIPA admin password from secret"
            fi
        fi
        
        # Generate if still not set
        if [[ -z "$FREEIPA_ADMIN_PASSWORD" ]]; then
            FREEIPA_ADMIN_PASSWORD=$(generate_password)
            log_info "Generated new FreeIPA admin password"
        fi
    fi
    
    # Try to authenticate with existing password
    log_info "Verifying FreeIPA admin authentication..."
    if [[ "$DRY_RUN" != "1" ]]; then
        local auth_result
        auth_result=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" exec "$freeipa_pod" -- \
            bash -c "echo '$FREEIPA_ADMIN_PASSWORD' | kinit admin 2>&1" || echo "FAILED")
        
        if [[ "$auth_result" == *"FAILED"* ]] || [[ "$auth_result" == *"incorrect"* ]]; then
            log_warn "Cannot authenticate with provided password - admin account may need manual setup"
            log_info "FreeIPA admin password should be set during initial deployment"
        else
            log_success "FreeIPA admin authentication successful"
        fi
    else
        log_info "[DRY-RUN] Would verify FreeIPA admin authentication"
    fi
    
    # Save/update secret
    if [[ "$DRY_RUN" != "1" ]]; then
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" create secret generic freeipa-admin-creds \
            --from-literal=username=admin \
            --from-literal=password="$FREEIPA_ADMIN_PASSWORD" \
            --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
        
        log_success "Saved/updated FreeIPA admin credentials secret"
    else
        log_info "[DRY-RUN] Would save FreeIPA admin credentials secret"
    fi
    
    # Save credentials to file
    local creds_file="$CREDENTIALS_DIR/freeipa-admin-credentials.txt"
    if [[ "$DRY_RUN" != "1" ]]; then
        cat > "$creds_file" << EOF
FreeIPA Administrator Credentials
Generated: $(date -Iseconds)

Username: admin
Password: $FREEIPA_ADMIN_PASSWORD

Access: 
  Server: ipa.vmstation.local
  Domain: vmstation.local
  Realm: VMSTATION.LOCAL

SECURITY NOTICE:
- This file contains sensitive credentials
- Keep it secure and backed up
- Change default passwords immediately in production
- FreeIPA admin password is set during initial deployment
- If authentication fails, reset via FreeIPA container or redeploy

EOF
        chmod 600 "$creds_file"
        log_success "Saved FreeIPA credentials to: $creds_file"
    else
        log_info "[DRY-RUN] Would save FreeIPA credentials to: $creds_file"
    fi
    
    log_success "FreeIPA admin bootstrap completed"
}

# Generate combined credentials file
generate_combined_credentials() {
    log_info "Generating combined credentials file..."
    
    local combined_file="$CREDENTIALS_DIR/cluster-admin-credentials.txt"
    
    if [[ "$DRY_RUN" != "1" ]]; then
        cat > "$combined_file" << EOF
============================================================
Cluster Administrator Credentials
============================================================
Generated: $(date -Iseconds)

Keycloak Admin:
  Username: admin
  Password: ${KEYCLOAK_ADMIN_PASSWORD:-<not set>}
  URL: http://<node-ip>:30180/auth

FreeIPA Admin:
  Username: admin
  Password: ${FREEIPA_ADMIN_PASSWORD:-<not set>}
  Server: ipa.vmstation.local
  Domain: vmstation.local
  Realm: VMSTATION.LOCAL

Individual credential files:
  - $CREDENTIALS_DIR/keycloak-admin-credentials.txt
  - $CREDENTIALS_DIR/freeipa-admin-credentials.txt

SECURITY NOTICE:
- This file contains sensitive credentials
- Keep it secure and backed up
- Change default passwords immediately in production
- Consider using Ansible Vault or external secret management
============================================================
EOF
        chmod 600 "$combined_file"
        log_success "Combined credentials saved to: $combined_file"
    else
        log_info "[DRY-RUN] Would save combined credentials to: $combined_file"
    fi
}

# Main execution
main() {
    print_banner
    
    # Run preflight checks
    preflight_checks
    
    echo ""
    log_info "Starting admin account bootstrap..."
    echo ""
    
    # Ensure credentials directory exists
    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "$CREDENTIALS_DIR"
        chmod 700 "$CREDENTIALS_DIR"
    else
        log_info "[DRY-RUN] Would create credentials directory: $CREDENTIALS_DIR"
    fi
    
    # Bootstrap Keycloak admin
    bootstrap_keycloak_admin
    echo ""
    
    # Bootstrap FreeIPA admin
    bootstrap_freeipa_admin
    echo ""
    
    # Generate combined credentials
    generate_combined_credentials
    
    echo ""
    log_success "============================================================"
    log_success "Admin Bootstrap Complete!"
    log_success "============================================================"
    echo ""
    log_info "Credentials saved to: $CREDENTIALS_DIR"
    log_info "  - cluster-admin-credentials.txt (combined)"
    log_info "  - keycloak-admin-credentials.txt"
    log_info "  - freeipa-admin-credentials.txt"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "This was a DRY-RUN - no actual changes were made"
    else
        log_warn "IMPORTANT: Keep these credentials secure and change them in production!"
    fi
    echo ""
}

# Run main function
main "$@"
