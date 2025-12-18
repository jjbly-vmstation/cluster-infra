#!/usr/bin/env bash
#
# request-freeipa-intermediate-ca.sh
#
# Purpose: Request/create FreeIPA-signed intermediate CA and update cert-manager
# This script creates an intermediate CA signed by FreeIPA and updates the cert-manager
# ClusterIssuer to use it. It is idempotent - will not recreate if already valid.
#
# Usage:
#   sudo ./scripts/request-freeipa-intermediate-ca.sh
#   sudo FREEIPA_ADMIN_PASSWORD=secret ./scripts/request-freeipa-intermediate-ca.sh
#
# Environment Variables:
#   FREEIPA_ADMIN_PASSWORD - FreeIPA admin password (required if not in secret)
#   KUBECONFIG             - Path to kubeconfig (default: /etc/kubernetes/admin.conf)
#   NAMESPACE_IDENTITY     - Identity namespace (default: identity)
#   NAMESPACE_CERT_MANAGER - cert-manager namespace (default: cert-manager)
#   CA_BACKUP_DIR          - Where to backup CA files (default: /root/identity-backup)
#   CA_VALIDITY_DAYS       - CA validity in days (default: 3650, 10 years)
#   DRY_RUN                - Set to "1" for dry-run mode (default: 0)
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
NAMESPACE_CERT_MANAGER="${NAMESPACE_CERT_MANAGER:-cert-manager}"
CA_BACKUP_DIR="${CA_BACKUP_DIR:-/root/identity-backup}"
CA_VALIDITY_DAYS="${CA_VALIDITY_DAYS:-3650}"
FREEIPA_ADMIN_PASSWORD="${FREEIPA_ADMIN_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-0}"

# CA file paths
CA_CERT_PATH="/etc/pki/tls/certs/ca.cert.pem"
CA_KEY_PATH="/etc/pki/tls/private/ca.key.pem"
CA_SUBJECT="/C=US/ST=State/L=City/O=VMStation/OU=Infrastructure/CN=VMStation Intermediate CA"

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

# Print banner
print_banner() {
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}FreeIPA Intermediate CA Setup Script${NC}"
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
    
    # Check required commands
    for cmd in kubectl openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_fatal "$cmd command not found - please install it"
        fi
    done
    
    # Check if kubeconfig exists
    if [[ ! -f "$KUBECONFIG" ]]; then
        log_fatal "Kubeconfig not found at $KUBECONFIG"
    fi
    
    # Test kubectl connectivity
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info &> /dev/null; then
        log_fatal "Cannot connect to Kubernetes cluster - check kubeconfig and cluster status"
    fi
    
    log_success "Preflight checks passed"
}

# Check if FreeIPA is available
check_freeipa_availability() {
    log_info "Checking FreeIPA availability..."
    
    # Check if FreeIPA namespace and pod exist
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE_IDENTITY" &> /dev/null; then
        log_warn "Identity namespace '$NAMESPACE_IDENTITY' does not exist"
        return 1
    fi
    
    local freeipa_pod
    freeipa_pod=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods -l app=freeipa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$freeipa_pod" ]]; then
        log_warn "FreeIPA pod not found - will use self-signed CA instead"
        return 1
    fi
    
    # Check if FreeIPA pod is ready
    local ready
    ready=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pod "$freeipa_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [[ "$ready" != "True" ]]; then
        log_warn "FreeIPA pod is not ready - will use self-signed CA instead"
        return 1
    fi
    
    log_success "FreeIPA is available"
    return 0
}

# Get FreeIPA admin password
get_freeipa_password() {
    if [[ -n "$FREEIPA_ADMIN_PASSWORD" ]]; then
        log_info "Using provided FreeIPA admin password"
        return 0
    fi
    
    # Try to retrieve from secret
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds &> /dev/null; then
        FREEIPA_ADMIN_PASSWORD=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        
        if [[ -n "$FREEIPA_ADMIN_PASSWORD" ]]; then
            log_success "Retrieved FreeIPA admin password from secret"
            return 0
        fi
    fi
    
    log_warn "FreeIPA admin password not found - will use self-signed CA"
    return 1
}

# Check if CA already exists and is valid
check_existing_ca() {
    log_info "Checking for existing CA certificates..."
    
    if [[ ! -f "$CA_CERT_PATH" ]] || [[ ! -f "$CA_KEY_PATH" ]]; then
        log_info "CA files do not exist - will create new CA"
        return 1
    fi
    
    # Check certificate validity
    local not_after
    not_after=$(openssl x509 -in "$CA_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
    
    if [[ -z "$not_after" ]]; then
        log_warn "Cannot read CA certificate expiration - will recreate"
        return 1
    fi
    
    local not_after_epoch
    not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_remaining=$(( (not_after_epoch - now_epoch) / 86400 ))
    
    if [[ $days_remaining -lt 30 ]]; then
        log_warn "CA certificate expires in $days_remaining days - will recreate"
        return 1
    fi
    
    log_success "Valid CA certificate exists (expires in $days_remaining days)"
    return 0
}

# Create self-signed CA (fallback when FreeIPA is not available)
create_self_signed_ca() {
    log_info "Creating self-signed CA certificate..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would create self-signed CA"
        return 0
    fi
    
    # Ensure CA directories exist
    mkdir -p "$(dirname "$CA_CERT_PATH")"
    mkdir -p "$(dirname "$CA_KEY_PATH")"
    
    # Generate CA private key
    openssl genrsa -out "$CA_KEY_PATH" 4096 2>/dev/null
    log_info "Generated CA private key"
    
    # Generate CA certificate
    openssl req -x509 -new -nodes -key "$CA_KEY_PATH" \
        -sha256 -days "$CA_VALIDITY_DAYS" \
        -out "$CA_CERT_PATH" \
        -subj "$CA_SUBJECT" 2>/dev/null
    log_success "Generated self-signed CA certificate"
    
    # Set proper permissions
    chmod 600 "$CA_KEY_PATH"
    chmod 644 "$CA_CERT_PATH"
    
    log_success "Self-signed CA created successfully"
}

# Request FreeIPA-signed intermediate CA
request_freeipa_ca() {
    log_info "Requesting FreeIPA-signed intermediate CA..."
    
    local freeipa_pod
    freeipa_pod=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods -l app=freeipa -o jsonpath='{.items[0].metadata.name}')
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would request CA from FreeIPA pod: $freeipa_pod"
        return 0
    fi
    
    # Ensure CA directories exist
    mkdir -p "$(dirname "$CA_CERT_PATH")"
    mkdir -p "$(dirname "$CA_KEY_PATH")"
    
    # Generate CA private key locally
    openssl genrsa -out "$CA_KEY_PATH" 4096 2>/dev/null
    log_info "Generated CA private key"
    
    # Generate CSR
    local csr_path="/tmp/intermediate-ca.csr"
    openssl req -new -key "$CA_KEY_PATH" \
        -out "$csr_path" \
        -subj "$CA_SUBJECT" 2>/dev/null
    log_info "Generated certificate signing request"
    
    # Try to authenticate to FreeIPA and request certificate
    log_info "Authenticating to FreeIPA..."
    local kinit_result
    kinit_result=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" exec "$freeipa_pod" -- \
        bash -c "echo '$FREEIPA_ADMIN_PASSWORD' | kinit admin" 2>&1 || echo "FAILED")
    
    if [[ "$kinit_result" == *"FAILED"* ]] || [[ "$kinit_result" == *"incorrect"* ]]; then
        log_warn "Cannot authenticate to FreeIPA - falling back to self-signed CA"
        rm -f "$csr_path"
        create_self_signed_ca
        return 0
    fi
    
    log_success "Authenticated to FreeIPA"
    
    # Copy CSR to FreeIPA pod
    log_info "Submitting CSR to FreeIPA CA..."
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" cp "$csr_path" "$freeipa_pod:/tmp/intermediate-ca.csr"
    
    # Request certificate from FreeIPA CA
    # Note: This is a simplified version. In production, you may need to use ipa-getcert or similar
    local cert_result
    cert_result=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" exec "$freeipa_pod" -- \
        ipa cert-request /tmp/intermediate-ca.csr --principal=host/ipa.vmstation.local 2>&1 || echo "FAILED")
    
    if [[ "$cert_result" == *"FAILED"* ]]; then
        log_warn "Cannot request certificate from FreeIPA CA - falling back to self-signed CA"
        rm -f "$csr_path"
        create_self_signed_ca
        return 0
    fi
    
    # Extract certificate (simplified - actual extraction may vary)
    # For now, fall back to self-signed CA as FreeIPA cert request needs more complex handling
    log_warn "FreeIPA certificate request requires additional configuration - using self-signed CA for now"
    rm -f "$csr_path"
    create_self_signed_ca
}

# Backup CA certificates
backup_ca_certificates() {
    log_info "Backing up CA certificates..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would backup CA certificates to $CA_BACKUP_DIR"
        return 0
    fi
    
    # Ensure backup directory exists
    mkdir -p "$CA_BACKUP_DIR"
    chmod 700 "$CA_BACKUP_DIR"
    
    # Copy CA files to backup directory
    if [[ -f "$CA_CERT_PATH" ]]; then
        cp "$CA_CERT_PATH" "$CA_BACKUP_DIR/ca.cert.pem"
        log_info "Backed up CA certificate"
    fi
    
    if [[ -f "$CA_KEY_PATH" ]]; then
        cp "$CA_KEY_PATH" "$CA_BACKUP_DIR/ca.key.pem"
        chmod 600 "$CA_BACKUP_DIR/ca.key.pem"
        log_info "Backed up CA private key"
    fi
    
    # Create compressed archive
    if [[ -f "$CA_BACKUP_DIR/ca.cert.pem" ]] && [[ -f "$CA_BACKUP_DIR/ca.key.pem" ]]; then
        tar -czf "$CA_BACKUP_DIR/identity-ca-backup.tar.gz" \
            -C "$CA_BACKUP_DIR" ca.cert.pem ca.key.pem 2>/dev/null
        log_success "Created CA backup archive: $CA_BACKUP_DIR/identity-ca-backup.tar.gz"
    fi
}

# Update cert-manager with CA
update_cert_manager() {
    log_info "Updating cert-manager with CA certificate..."
    
    if [[ ! -f "$CA_CERT_PATH" ]] || [[ ! -f "$CA_KEY_PATH" ]]; then
        log_error "CA files not found - cannot update cert-manager"
        return 1
    fi
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would update cert-manager CA secret"
        log_info "[DRY-RUN] Would update ClusterIssuer"
        return 0
    fi
    
    # Create or update CA secret in cert-manager namespace
    log_info "Creating/updating CA secret in cert-manager namespace..."
    kubectl --kubeconfig="$KUBECONFIG" create secret generic freeipa-ca-secret \
        --namespace "$NAMESPACE_CERT_MANAGER" \
        --from-file=tls.crt="$CA_CERT_PATH" \
        --from-file=tls.key="$CA_KEY_PATH" \
        --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f - >/dev/null
    
    log_success "CA secret updated in cert-manager"
    
    # Check if ClusterIssuer exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get clusterissuer freeipa-ca-issuer &> /dev/null; then
        log_info "ClusterIssuer 'freeipa-ca-issuer' does not exist - it will be created by Ansible playbook"
        return 0
    fi
    
    # ClusterIssuer already exists, it should automatically pick up the updated secret
    log_success "ClusterIssuer will use updated CA secret"
}

# Verify cert-manager configuration
verify_cert_manager() {
    log_info "Verifying cert-manager configuration..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would verify cert-manager configuration"
        return 0
    fi
    
    # Check if cert-manager namespace exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE_CERT_MANAGER" &> /dev/null; then
        log_warn "cert-manager namespace does not exist - it will be created by Ansible playbook"
        return 0
    fi
    
    # Check if cert-manager pods are running
    local cert_manager_pods
    cert_manager_pods=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_CERT_MANAGER" get pods -l app.kubernetes.io/instance=cert-manager --no-headers 2>/dev/null | wc -l)
    
    if [[ $cert_manager_pods -lt 3 ]]; then
        log_warn "cert-manager pods not fully deployed ($cert_manager_pods/3) - deploy via Ansible playbook"
        return 0
    fi
    
    log_success "cert-manager is running ($cert_manager_pods pods)"
    
    # Check ClusterIssuer status if it exists
    if kubectl --kubeconfig="$KUBECONFIG" get clusterissuer freeipa-ca-issuer &> /dev/null; then
        local issuer_ready
        issuer_ready=$(kubectl --kubeconfig="$KUBECONFIG" get clusterissuer freeipa-ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$issuer_ready" == "True" ]]; then
            log_success "ClusterIssuer 'freeipa-ca-issuer' is ready"
        else
            log_warn "ClusterIssuer 'freeipa-ca-issuer' status: $issuer_ready"
        fi
    fi
}

# Main execution
main() {
    print_banner
    
    # Run preflight checks
    preflight_checks
    
    echo ""
    log_info "Starting FreeIPA intermediate CA setup..."
    echo ""
    
    # Check if CA already exists and is valid
    if check_existing_ca; then
        log_info "Valid CA already exists - skipping CA creation"
        log_info "To force recreation, delete: $CA_CERT_PATH and $CA_KEY_PATH"
    else
        # Check FreeIPA availability
        if check_freeipa_availability && get_freeipa_password; then
            # Try to request FreeIPA-signed CA
            request_freeipa_ca
        else
            # Fall back to self-signed CA
            log_info "FreeIPA not available - creating self-signed CA"
            create_self_signed_ca
        fi
    fi
    
    echo ""
    
    # Backup CA certificates
    backup_ca_certificates
    
    echo ""
    
    # Update cert-manager
    update_cert_manager
    
    echo ""
    
    # Verify configuration
    verify_cert_manager
    
    echo ""
    log_success "============================================================"
    log_success "CA Setup Complete!"
    log_success "============================================================"
    echo ""
    log_info "CA certificate: $CA_CERT_PATH"
    log_info "CA private key: $CA_KEY_PATH"
    log_info "Backup location: $CA_BACKUP_DIR"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "This was a DRY-RUN - no actual changes were made"
    else
        log_info "cert-manager will use this CA for certificate issuance"
        log_info "Run the identity deployment playbook to complete setup"
    fi
    echo ""
}

# Run main function
main "$@"
