#!/usr/bin/env bash
#
# reset-identity-stack.sh
#
# Purpose: Conservative reset helper for identity stack (FreeIPA, Keycloak, PostgreSQL)
# This script performs a safe, timestamped backup before resetting the identity stack.
# It requires explicit confirmation for destructive operations.
#
# Usage:
#   sudo ./scripts/reset-identity-stack.sh                    # Interactive mode
#   sudo RESET_CONFIRM=yes ./scripts/reset-identity-stack.sh  # Automated mode
#   sudo RESET_CONFIRM=yes RESET_REMOVE_OLD=1 ./scripts/reset-identity-stack.sh  # Remove old backups
#
# Environment Variables:
#   RESET_CONFIRM      - Set to "yes" to skip confirmation prompt (default: prompt user)
#   RESET_REMOVE_OLD   - Set to "1" to remove old backup directories (default: keep)
#   KUBECONFIG         - Path to kubeconfig (default: /etc/kubernetes/admin.conf)
#   NAMESPACE_IDENTITY - Identity namespace (default: identity)
#   STORAGE_PATH       - Storage path for data (default: /srv/monitoring-data)
#   DRY_RUN            - Set to "1" for dry-run mode (default: 0)
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
STORAGE_PATH="${STORAGE_PATH:-/srv/monitoring-data}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/root/identity-backup}"
RESET_CONFIRM="${RESET_CONFIRM:-}"
RESET_REMOVE_OLD="${RESET_REMOVE_OLD:-0}"
DRY_RUN="${DRY_RUN:-0}"

# Generate timestamped backup directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_BASE_DIR}/auto-reset-${TIMESTAMP}"

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

# Dry-run wrapper for commands
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
    else
        "$@"
    fi
}

# Print banner
print_banner() {
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}Identity Stack Reset Script${NC}"
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
        log_warn "Identity namespace '$NAMESPACE_IDENTITY' does not exist - nothing to reset"
        exit 0
    fi
    
    log_success "Preflight checks passed"
}

# Confirm destructive operation
confirm_reset() {
    if [[ "$RESET_CONFIRM" == "yes" ]]; then
        log_info "Auto-confirmation enabled (RESET_CONFIRM=yes)"
        return 0
    fi
    
    echo ""
    echo -e "${RED}WARNING: This will perform destructive operations!${NC}"
    echo -e "  - All pods in namespace: ${NAMESPACE_IDENTITY}"
    echo -e "  - All PVCs in namespace: ${NAMESPACE_IDENTITY}"
    echo -e "  - All PVs related to identity services"
    echo -e "  - Data will be backed up to: ${BACKUP_DIR}"
    echo ""
    echo -e "Storage directories that will be backed up and cleaned:"
    echo -e "  - ${STORAGE_PATH}/postgresql"
    echo -e "  - ${STORAGE_PATH}/freeipa"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "DRY-RUN mode enabled - no actual changes will be made"
        return 0
    fi
    
    read -rp "Are you sure you want to continue? (yes/no): " response
    if [[ "$response" != "yes" ]]; then
        log_info "Reset cancelled by user"
        exit 0
    fi
}

# Create backup workspace
create_backup_workspace() {
    log_info "Creating backup workspace: $BACKUP_DIR"
    run_cmd mkdir -p "$BACKUP_DIR"
    run_cmd chmod 700 "$BACKUP_DIR"
    
    # Create subdirectories
    run_cmd mkdir -p "$BACKUP_DIR/credentials"
    run_cmd mkdir -p "$BACKUP_DIR/ca-certs"
    run_cmd mkdir -p "$BACKUP_DIR/manifests"
    run_cmd mkdir -p "$BACKUP_DIR/logs"
    
    log_success "Backup workspace created"
}

# Backup existing resources
backup_resources() {
    log_info "Backing up existing Kubernetes resources..."
    
    # Backup credentials if they exist
    if [[ -f /root/identity-backup/cluster-admin-credentials.txt ]]; then
        run_cmd cp /root/identity-backup/cluster-admin-credentials.txt "$BACKUP_DIR/credentials/"
        log_info "  Backed up cluster admin credentials"
    fi
    
    if [[ -f /root/identity-backup/keycloak-admin-credentials.txt ]]; then
        run_cmd cp /root/identity-backup/keycloak-admin-credentials.txt "$BACKUP_DIR/credentials/"
        log_info "  Backed up Keycloak admin credentials"
    fi
    
    # Backup CA certificates if they exist
    if [[ -f /root/identity-backup/identity-ca-backup.tar.gz ]]; then
        run_cmd cp /root/identity-backup/identity-ca-backup.tar.gz "$BACKUP_DIR/ca-certs/"
        log_info "  Backed up CA certificates"
    fi
    
    if [[ -f /etc/pki/tls/certs/ca.cert.pem ]]; then
        run_cmd cp /etc/pki/tls/certs/ca.cert.pem "$BACKUP_DIR/ca-certs/" || true
        log_info "  Backed up CA cert from /etc/pki/tls/certs/"
    fi
    
    # Backup Kubernetes manifests
    if [[ "$DRY_RUN" != "1" ]]; then
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get all -o yaml > "$BACKUP_DIR/manifests/all-resources.yaml" 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pvc -o yaml > "$BACKUP_DIR/manifests/pvcs.yaml" 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secrets -o yaml > "$BACKUP_DIR/manifests/secrets.yaml" 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG" get pv -o yaml > "$BACKUP_DIR/manifests/pvs.yaml" 2>/dev/null || true
        log_info "  Backed up Kubernetes manifests"
    fi
    
    log_success "Resource backup completed"
}

# Scale down workloads
scale_down_workloads() {
    log_info "Scaling down identity stack workloads..."
    
    # Scale down StatefulSets
    log_info "  Scaling down StatefulSets..."
    if [[ "$DRY_RUN" != "1" ]]; then
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" scale statefulset --all --replicas=0 2>/dev/null || log_warn "  No StatefulSets found or already scaled down"
    else
        log_info "  [DRY-RUN] Would scale down all StatefulSets"
    fi
    
    # Scale down Deployments
    log_info "  Scaling down Deployments..."
    if [[ "$DRY_RUN" != "1" ]]; then
        kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" scale deployment --all --replicas=0 2>/dev/null || log_warn "  No Deployments found or already scaled down"
    else
        log_info "  [DRY-RUN] Would scale down all Deployments"
    fi
    
    log_success "Workloads scaled down"
}

# Wait for pods to terminate
wait_for_pod_termination() {
    log_info "Waiting for pods to terminate gracefully..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would wait for pods to terminate"
        return 0
    fi
    
    local max_wait=60
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        local pod_count
        pod_count=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods --no-headers 2>/dev/null | wc -l)
        
        if [[ $pod_count -eq 0 ]]; then
            log_success "All pods terminated"
            return 0
        fi
        
        log_info "  Waiting... ($elapsed/$max_wait seconds) - $pod_count pods remaining"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_warn "Some pods still running after $max_wait seconds - will force delete"
}

# Delete pods with force if necessary
delete_pods() {
    log_info "Deleting identity stack pods..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would delete all pods in namespace $NAMESPACE_IDENTITY"
        return 0
    fi
    
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" delete pods --all --force --grace-period=0 2>/dev/null || log_info "  No pods to delete"
    
    log_success "Pods deleted"
}

# Delete StatefulSets and Deployments
delete_workloads() {
    log_info "Deleting StatefulSets and Deployments..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would delete all StatefulSets and Deployments"
        return 0
    fi
    
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" delete statefulset --all 2>/dev/null || log_info "  No StatefulSets to delete"
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" delete deployment --all 2>/dev/null || log_info "  No Deployments to delete"
    
    log_success "Workloads deleted"
}

# Delete PVCs
delete_pvcs() {
    log_info "Deleting Persistent Volume Claims..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would delete all PVCs in namespace $NAMESPACE_IDENTITY"
        return 0
    fi
    
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" delete pvc --all 2>/dev/null || log_info "  No PVCs to delete"
    
    log_success "PVCs deleted"
}

# Delete PVs
delete_pvs() {
    log_info "Deleting identity-related Persistent Volumes..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would delete identity-related PVs"
        return 0
    fi
    
    # Delete specific PVs used by identity stack
    kubectl --kubeconfig="$KUBECONFIG" delete pv keycloak-postgresql-pv 2>/dev/null || log_info "  PV keycloak-postgresql-pv not found"
    kubectl --kubeconfig="$KUBECONFIG" delete pv freeipa-data-pv 2>/dev/null || log_info "  PV freeipa-data-pv not found"
    
    log_success "PVs deleted"
}

# Backup and clean storage directories
backup_and_clean_storage() {
    log_info "Backing up and cleaning storage directories..."
    
    # Backup PostgreSQL data
    if [[ -d "${STORAGE_PATH}/postgresql" ]]; then
        log_info "  Backing up PostgreSQL data..."
        if [[ "$DRY_RUN" != "1" ]]; then
            tar -czf "$BACKUP_DIR/postgresql-data.tar.gz" -C "${STORAGE_PATH}" postgresql 2>/dev/null || log_warn "  Could not backup PostgreSQL data"
            rm -rf "${STORAGE_PATH}/postgresql"
            log_info "  PostgreSQL data backed up and removed"
        else
            log_info "  [DRY-RUN] Would backup and remove PostgreSQL data"
        fi
    fi
    
    # Backup FreeIPA data
    if [[ -d "${STORAGE_PATH}/freeipa" ]]; then
        log_info "  Backing up FreeIPA data..."
        if [[ "$DRY_RUN" != "1" ]]; then
            tar -czf "$BACKUP_DIR/freeipa-data.tar.gz" -C "${STORAGE_PATH}" freeipa 2>/dev/null || log_warn "  Could not backup FreeIPA data"
            rm -rf "${STORAGE_PATH}/freeipa"
            log_info "  FreeIPA data backed up and removed"
        else
            log_info "  [DRY-RUN] Would backup and remove FreeIPA data"
        fi
    fi
    
    # Recreate empty directories with proper permissions
    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "${STORAGE_PATH}/postgresql"
        mkdir -p "${STORAGE_PATH}/freeipa"
        chown 999:999 "${STORAGE_PATH}/postgresql"
        chown root:root "${STORAGE_PATH}/freeipa"
        chmod 0755 "${STORAGE_PATH}/postgresql"
        chmod 0755 "${STORAGE_PATH}/freeipa"
        log_info "  Empty storage directories recreated with proper permissions"
    else
        log_info "  [DRY-RUN] Would recreate empty storage directories"
    fi
    
    log_success "Storage directories backed up and cleaned"
}

# Remove old backup directories
cleanup_old_backups() {
    if [[ "$RESET_REMOVE_OLD" != "1" ]]; then
        log_info "Keeping old backup directories (RESET_REMOVE_OLD not set)"
        return 0
    fi
    
    log_info "Removing old backup directories..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would remove old auto-reset-* directories"
        return 0
    fi
    
    # Find and remove old auto-reset directories (keep the current one)
    local removed_count=0
    while IFS= read -r old_backup; do
        if [[ "$old_backup" != "$BACKUP_DIR" ]]; then
            log_info "  Removing: $old_backup"
            rm -rf "$old_backup"
            removed_count=$((removed_count + 1))
        fi
    done < <(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "auto-reset-*" 2>/dev/null)
    
    if [[ $removed_count -gt 0 ]]; then
        log_success "Removed $removed_count old backup directories"
    else
        log_info "No old backup directories to remove"
    fi
}

# Generate reset summary
generate_summary() {
    log_info "Generating reset summary..."
    
    local summary_file="$BACKUP_DIR/reset-summary.txt"
    
    cat > "$summary_file" << EOF
Identity Stack Reset Summary
Generated: $(date -Iseconds)
Backup Location: $BACKUP_DIR

Configuration:
  Namespace: $NAMESPACE_IDENTITY
  Storage Path: $STORAGE_PATH
  Kubeconfig: $KUBECONFIG
  Dry Run: $DRY_RUN

Operations Performed:
  - Preflight checks
  - Resource backup
  - Workload scale down
  - Pod deletion
  - PVC deletion
  - PV deletion
  - Storage backup and cleanup
  $(if [[ "$RESET_REMOVE_OLD" == "1" ]]; then echo "  - Old backup cleanup"; fi)

Backup Contents:
  - credentials/      : Admin credentials
  - ca-certs/         : CA certificates
  - manifests/        : Kubernetes manifests
  - postgresql-data.tar.gz : PostgreSQL data backup (if existed)
  - freeipa-data.tar.gz    : FreeIPA data backup (if existed)
  - logs/             : Operation logs

Next Steps:
  1. Review this summary and backup contents
  2. Run identity-full-deploy.sh to redeploy the stack
  3. Or manually run: ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml

Restore Instructions:
  To restore from this backup, extract the data archives:
    tar -xzf $BACKUP_DIR/postgresql-data.tar.gz -C ${STORAGE_PATH}
    tar -xzf $BACKUP_DIR/freeipa-data.tar.gz -C ${STORAGE_PATH}
  
  Then apply the backed-up manifests if needed.
EOF
    
    log_success "Reset summary saved to: $summary_file"
}

# Main execution
main() {
    print_banner
    
    # Run preflight checks
    preflight_checks
    
    # Confirm reset
    confirm_reset
    
    echo ""
    log_info "Starting identity stack reset..."
    echo ""
    
    # Create backup workspace
    create_backup_workspace
    
    # Backup existing resources
    backup_resources
    
    # Scale down workloads
    scale_down_workloads
    
    # Wait for graceful termination
    wait_for_pod_termination
    
    # Delete pods
    delete_pods
    
    # Delete workloads
    delete_workloads
    
    # Delete PVCs
    delete_pvcs
    
    # Delete PVs
    delete_pvs
    
    # Backup and clean storage
    backup_and_clean_storage
    
    # Cleanup old backups if requested
    cleanup_old_backups
    
    # Generate summary
    generate_summary
    
    echo ""
    log_success "============================================================"
    log_success "Identity Stack Reset Complete!"
    log_success "============================================================"
    echo ""
    log_info "Backup Location: $BACKUP_DIR"
    log_info "Reset Summary: $BACKUP_DIR/reset-summary.txt"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "This was a DRY-RUN - no actual changes were made"
        echo ""
    else
        log_info "Next steps:"
        log_info "  1. Review the backup at: $BACKUP_DIR"
        log_info "  2. Run: ./scripts/identity-full-deploy.sh"
        log_info "  3. Or manually: ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml"
        echo ""
    fi
}

# Run main function
main "$@"
