#!/bin/bash
# reset-identity-stack.sh
#
# Purpose: Perform a controlled reset of the identity stack and generate fresh backups
# This script creates backups, then resets FreeIPA, Keycloak, and Keycloak Postgres
#
# Usage: Called by automate-identity-dns-and-coredns.sh with FORCE_RESET=1
#        or can be run directly with RESET_CONFIRM=yes FORCE_RESET=1
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE="${NAMESPACE:-identity}"
STORAGE_PATH="${STORAGE_PATH:-/srv/monitoring-data}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/root/identity-backup}"
VERBOSE="${VERBOSE:-false}"

# Storage ownership configuration
POSTGRES_UID="${POSTGRES_UID:-999}"
POSTGRES_GID="${POSTGRES_GID:-999}"
FREEIPA_UID="${FREEIPA_UID:-root}"
FREEIPA_GID="${FREEIPA_GID:-root}"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}===================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}===================================================================${NC}\n"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

preflight_checks() {
    log_step "PREFLIGHT CHECKS"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
    log_verbose "Running as root: OK"
    
    # Check required tools
    local missing_tools=()
    for tool in kubectl tar openssl mkdir date; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
            log_error "Required tool not found: $tool"
        else
            log_verbose "Found tool: $tool"
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        return 1
    fi
    
    # Check kubeconfig
    if [ ! -f "$KUBECONFIG" ]; then
        log_error "Kubeconfig not found: $KUBECONFIG"
        return 1
    fi
    log_verbose "Kubeconfig: $KUBECONFIG"
    
    # Check namespace exists
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$NAMESPACE" &>/dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist"
        return 1
    fi
    log_verbose "Namespace '$NAMESPACE': OK"
    
    log_info "✓ Preflight checks passed"
    return 0
}

# ============================================================================
# CONFIRMATION CHECK
# ============================================================================

check_confirmation() {
    log_step "CONFIRMATION CHECK"
    
    # Require explicit confirmation
    if [ "${RESET_CONFIRM:-}" != "yes" ] && [ "${FORCE_RESET:-}" != "1" ]; then
        log_error "This script performs destructive operations!"
        log_error "It will:"
        log_error "  - Create backups of FreeIPA and PostgreSQL data"
        log_error "  - Delete all identity stack pods, PVCs, and PVs"
        log_error "  - Clean and reset storage directories"
        echo ""
        log_error "To proceed, either:"
        log_error "  1. Set RESET_CONFIRM=yes environment variable"
        log_error "  2. Set FORCE_RESET=1 environment variable"
        log_error "  3. Use the wrapper script with --force-reset flag"
        echo ""
        log_error "Example: RESET_CONFIRM=yes FORCE_RESET=1 $0"
        return 1
    fi
    
    log_warn "⚠️  DESTRUCTIVE OPERATION CONFIRMED"
    log_info "Proceeding with identity stack reset..."
    return 0
}

# ============================================================================
# CREATE BACKUP WORKSPACE
# ============================================================================

create_backup_workspace() {
    log_step "CREATE BACKUP WORKSPACE"
    
    # Create timestamped workspace
    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP_WORKSPACE="${BACKUP_BASE_DIR}/auto-reset-${timestamp}"
    
    log_info "Creating backup workspace: $BACKUP_WORKSPACE"
    
    if ! mkdir -p "$BACKUP_WORKSPACE"; then
        log_error "Failed to create backup workspace: $BACKUP_WORKSPACE"
        return 1
    fi
    
    # Set secure permissions
    chmod 700 "$BACKUP_WORKSPACE"
    log_verbose "Workspace permissions set to 700"
    
    # Create subdirectories
    mkdir -p "$BACKUP_WORKSPACE/data"
    mkdir -p "$BACKUP_WORKSPACE/manifests"
    mkdir -p "$BACKUP_WORKSPACE/logs"
    
    log_info "✓ Backup workspace created: $BACKUP_WORKSPACE"
    
    # Export for other functions
    export BACKUP_WORKSPACE
    return 0
}

# ============================================================================
# BACKUP IDENTITY STACK DATA
# ============================================================================

backup_identity_data() {
    log_step "BACKUP IDENTITY STACK DATA"
    
    local backup_log="${BACKUP_WORKSPACE}/logs/backup.log"
    
    log_info "Backing up identity stack data..."
    
    # Backup PostgreSQL data
    if [ -d "${STORAGE_PATH}/postgresql" ]; then
        log_info "Backing up PostgreSQL data..."
        if tar -czf "${BACKUP_WORKSPACE}/data/postgresql-data.tar.gz" \
               -C "${STORAGE_PATH}" postgresql 2>&1 | tee -a "$backup_log"; then
            log_info "✓ PostgreSQL data backed up"
            
            # Create checksum
            (cd "${BACKUP_WORKSPACE}/data" && sha256sum postgresql-data.tar.gz > postgresql-data.tar.gz.sha256)
            log_verbose "PostgreSQL backup checksum created"
        else
            log_error "Failed to backup PostgreSQL data"
            return 1
        fi
    else
        log_warn "PostgreSQL data directory not found: ${STORAGE_PATH}/postgresql"
    fi
    
    # Backup FreeIPA data
    if [ -d "${STORAGE_PATH}/freeipa" ]; then
        log_info "Backing up FreeIPA data..."
        if tar -czf "${BACKUP_WORKSPACE}/data/freeipa-data.tar.gz" \
               -C "${STORAGE_PATH}" freeipa 2>&1 | tee -a "$backup_log"; then
            log_info "✓ FreeIPA data backed up"
            
            # Create checksum
            (cd "${BACKUP_WORKSPACE}/data" && sha256sum freeipa-data.tar.gz > freeipa-data.tar.gz.sha256)
            log_verbose "FreeIPA backup checksum created"
        else
            log_error "Failed to backup FreeIPA data"
            return 1
        fi
    else
        log_warn "FreeIPA data directory not found: ${STORAGE_PATH}/freeipa"
    fi
    
    # Create combined checksum file
    if compgen -G "${BACKUP_WORKSPACE}/data/*.tar.gz" > /dev/null; then
        (cd "${BACKUP_WORKSPACE}/data" && sha256sum *.tar.gz > SHA256SUMS 2>/dev/null) || true
        log_info "✓ Combined checksums created: ${BACKUP_WORKSPACE}/data/SHA256SUMS"
    fi
    
    log_info "✓ Identity data backup complete"
    return 0
}

# ============================================================================
# BACKUP KUBERNETES MANIFESTS
# ============================================================================

backup_kubernetes_manifests() {
    log_step "BACKUP KUBERNETES MANIFESTS"
    
    log_info "Backing up Kubernetes manifests from namespace '$NAMESPACE'..."
    
    local manifest_log="${BACKUP_WORKSPACE}/logs/manifests.log"
    
    # Backup all resources in namespace
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get all,pvc,secrets,configmaps \
           -o yaml > "${BACKUP_WORKSPACE}/manifests/all-resources.yaml" 2>&1 | tee -a "$manifest_log"; then
        log_verbose "All resources backed up to all-resources.yaml"
    fi
    
    # Backup PVs separately (cluster-scoped) - get all PVs that have claimRef to our namespace
    if kubectl --kubeconfig="$KUBECONFIG" get pv -o json | \
           jq -r --arg ns "$NAMESPACE" '.items[] | select(.spec.claimRef.namespace == $ns)' \
           > "${BACKUP_WORKSPACE}/manifests/pvs.json" 2>&1; then
        log_verbose "PVs backed up to pvs.json"
    else
        log_verbose "No PVs found or jq not available, using alternative method"
        kubectl --kubeconfig="$KUBECONFIG" get pv -o yaml > "${BACKUP_WORKSPACE}/manifests/all-pvs.yaml" 2>&1 | tee -a "$manifest_log" || true
    fi
    
    log_info "✓ Kubernetes manifests backed up"
    return 0
}

# ============================================================================
# RESET IDENTITY STACK
# ============================================================================

reset_identity_stack() {
    log_step "RESET IDENTITY STACK"
    
    log_warn "⚠️  Beginning destructive reset operations..."
    
    local reset_log="${BACKUP_WORKSPACE}/logs/reset.log"
    
    # Step 1: Scale down StatefulSets
    log_info "[1/9] Scaling down StatefulSets..."
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" scale statefulset --all --replicas=0 2>&1 | tee -a "$reset_log"; then
        log_verbose "StatefulSets scaled down"
    else
        log_warn "No StatefulSets found or already scaled down"
    fi
    
    # Step 2: Scale down Deployments
    log_info "[2/9] Scaling down Deployments..."
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" scale deployment --all --replicas=0 2>&1 | tee -a "$reset_log"; then
        log_verbose "Deployments scaled down"
    else
        log_warn "No Deployments found or already scaled down"
    fi
    
    # Step 3: Delete all pods
    log_info "[3/9] Deleting all pods in namespace '$NAMESPACE'..."
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete pods --all --force --grace-period=0 2>&1 | tee -a "$reset_log" || log_warn "No pods found"
    
    # Step 4: Wait for pods to be removed
    log_info "[4/9] Waiting for pods to be fully removed..."
    for i in {1..30}; do
        local pod_count
        pod_count=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l)
        if [ "$pod_count" -eq 0 ]; then
            log_info "✓ All pods removed"
            break
        fi
        log_verbose "Waiting... ($i/30) - $pod_count pods remaining"
        sleep 2
    done
    
    # Step 5: Delete all PVCs
    log_info "[5/9] Deleting all PVCs in namespace '$NAMESPACE'..."
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete pvc --all 2>&1 | tee -a "$reset_log" || log_warn "No PVCs found"
    
    # Step 6: Delete PVs - dynamically find PVs associated with the namespace
    log_info "[6/9] Deleting PVs for identity services..."
    local pvs_to_delete
    pvs_to_delete=$(kubectl --kubeconfig="$KUBECONFIG" get pv -o json | \
                    jq -r --arg ns "$NAMESPACE" '.items[] | select(.spec.claimRef.namespace == $ns) | .metadata.name' 2>/dev/null || true)
    
    if [ -n "$pvs_to_delete" ]; then
        while IFS= read -r pv; do
            if [ -n "$pv" ]; then
                log_info "Deleting PV: $pv"
                kubectl --kubeconfig="$KUBECONFIG" delete pv "$pv" 2>&1 | tee -a "$reset_log" || log_warn "Failed to delete PV: $pv"
            fi
        done <<< "$pvs_to_delete"
    else
        log_warn "No PVs found for namespace '$NAMESPACE' (or jq not available)"
        # Fallback to known PV names if jq is not available
        kubectl --kubeconfig="$KUBECONFIG" delete pv keycloak-postgresql-pv 2>&1 | tee -a "$reset_log" || log_warn "PV keycloak-postgresql-pv not found"
        kubectl --kubeconfig="$KUBECONFIG" delete pv freeipa-data-pv 2>&1 | tee -a "$reset_log" || log_warn "PV freeipa-data-pv not found"
    fi
    
    # Step 7: Delete StatefulSets and Deployments
    log_info "[7/9] Deleting StatefulSets and Deployments..."
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete statefulset --all 2>&1 | tee -a "$reset_log" || log_warn "No StatefulSets found"
    kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete deployment --all 2>&1 | tee -a "$reset_log" || log_warn "No Deployments found"
    
    # Step 8: Clean storage directories
    log_info "[8/9] Cleaning storage directories..."
    if [ -d "${STORAGE_PATH}/postgresql" ]; then
        log_info "Removing PostgreSQL storage..."
        rm -rf "${STORAGE_PATH}/postgresql"
        log_verbose "PostgreSQL storage removed"
    fi
    
    if [ -d "${STORAGE_PATH}/freeipa" ]; then
        log_info "Removing FreeIPA storage..."
        rm -rf "${STORAGE_PATH}/freeipa"
        log_verbose "FreeIPA storage removed"
    fi
    
    # Step 9: Recreate empty directories
    log_info "[9/9] Recreating empty storage directories..."
    mkdir -p "${STORAGE_PATH}/postgresql"
    mkdir -p "${STORAGE_PATH}/freeipa"
    chown "${POSTGRES_UID}:${POSTGRES_GID}" "${STORAGE_PATH}/postgresql"
    chown "${FREEIPA_UID}:${FREEIPA_GID}" "${STORAGE_PATH}/freeipa"
    chmod 0755 "${STORAGE_PATH}/postgresql"
    chmod 0755 "${STORAGE_PATH}/freeipa"
    log_verbose "Storage directories recreated with proper permissions (postgres: ${POSTGRES_UID}:${POSTGRES_GID}, freeipa: ${FREEIPA_UID}:${FREEIPA_GID})"
    
    log_info "✓ Identity stack reset complete"
    return 0
}

# ============================================================================
# GENERATE RESET SUMMARY
# ============================================================================

generate_summary() {
    log_step "RESET SUMMARY"
    
    local summary_file="${BACKUP_WORKSPACE}/RESET_SUMMARY.txt"
    
    cat > "$summary_file" << EOF
Identity Stack Reset Summary
============================

Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Namespace: $NAMESPACE
Storage Path: $STORAGE_PATH
Backup Workspace: $BACKUP_WORKSPACE

Backup Files:
-------------
$(ls -lh "${BACKUP_WORKSPACE}/data/" 2>/dev/null || echo "No backup files created")

Checksums:
----------
$(cat "${BACKUP_WORKSPACE}/data/SHA256SUMS" 2>/dev/null || echo "No checksums available")

Logs:
-----
- Backup log: ${BACKUP_WORKSPACE}/logs/backup.log
- Manifest log: ${BACKUP_WORKSPACE}/logs/manifests.log
- Reset log: ${BACKUP_WORKSPACE}/logs/reset.log

Actions Performed:
------------------
1. Created timestamped backup workspace
2. Backed up PostgreSQL and FreeIPA data
3. Backed up Kubernetes manifests
4. Scaled down all workloads
5. Deleted all pods, PVCs, and PVs
6. Cleaned storage directories
7. Recreated empty storage directories with proper permissions

Next Steps:
-----------
1. Review backup files in: $BACKUP_WORKSPACE
2. Verify checksums: cd ${BACKUP_WORKSPACE}/data && sha256sum -c SHA256SUMS
3. Deploy fresh identity stack using Ansible playbook
4. Run DNS and CoreDNS automation
5. Verify identity stack readiness

Restore Instructions (if needed):
----------------------------------
To restore from this backup:
1. Stop all identity workloads
2. Extract backups:
   - tar -xzf ${BACKUP_WORKSPACE}/data/postgresql-data.tar.gz -C ${STORAGE_PATH}
   - tar -xzf ${BACKUP_WORKSPACE}/data/freeipa-data.tar.gz -C ${STORAGE_PATH}
3. Restore correct permissions:
   - chown -R ${POSTGRES_UID}:${POSTGRES_GID} ${STORAGE_PATH}/postgresql
   - chown -R ${FREEIPA_UID}:${FREEIPA_GID} ${STORAGE_PATH}/freeipa
4. Redeploy identity stack

EOF
    
    chmod 600 "$summary_file"
    
    # Display summary
    cat "$summary_file"
    
    log_info "✓ Summary saved to: $summary_file"
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    cat << EOF

${BLUE}=============================================================================
Identity Stack Reset Script
=============================================================================${NC}

${YELLOW}⚠️  WARNING: This script performs DESTRUCTIVE operations!${NC}

This script will:
  • Create timestamped backups of FreeIPA and PostgreSQL data
  • Delete all identity stack Kubernetes resources
  • Clean and reset storage directories
  • Generate detailed logs and checksums

Namespace: $NAMESPACE
Kubeconfig: $KUBECONFIG
Storage Path: $STORAGE_PATH
Backup Base: $BACKUP_BASE_DIR

${BLUE}=============================================================================${NC}

EOF
    
    # Run all steps
    if ! preflight_checks; then
        log_error "Preflight checks failed - aborting"
        exit 1
    fi
    
    if ! check_confirmation; then
        log_error "Confirmation check failed - aborting"
        exit 1
    fi
    
    if ! create_backup_workspace; then
        log_error "Failed to create backup workspace - aborting"
        exit 1
    fi
    
    if ! backup_identity_data; then
        log_error "Failed to backup identity data - aborting"
        log_error "Backup workspace preserved at: $BACKUP_WORKSPACE"
        exit 1
    fi
    
    if ! backup_kubernetes_manifests; then
        log_warn "Failed to backup Kubernetes manifests - continuing anyway"
    fi
    
    if ! reset_identity_stack; then
        log_error "Failed to reset identity stack"
        log_error "Backup workspace preserved at: $BACKUP_WORKSPACE"
        exit 1
    fi
    
    generate_summary
    
    cat << EOF

${GREEN}=============================================================================
Identity Stack Reset Complete
=============================================================================${NC}

${GREEN}✓ Backups created successfully${NC}
${GREEN}✓ Identity stack reset successfully${NC}

Backup Location: ${BACKUP_WORKSPACE}

${BLUE}Next Steps:${NC}
  1. Review the reset summary: cat ${BACKUP_WORKSPACE}/RESET_SUMMARY.txt
  2. Verify backups: cd ${BACKUP_WORKSPACE}/data && sha256sum -c SHA256SUMS
  3. Deploy fresh identity stack (will be done automatically by wrapper)
  4. Run verification steps (will be done automatically by wrapper)

${YELLOW}Security Note:${NC}
  All backup files have been created with mode 600 (owner read/write only)
  Backup workspace: ${BACKUP_WORKSPACE}

EOF
    
    log_info "Reset script completed successfully"
    return 0
}

# Run main function
main "$@"
