#!/usr/bin/env bash
#
# identity-full-deploy.sh
#
# Purpose: Main orchestration wrapper for identity stack deployment
# This script orchestrates the complete identity stack workflow including optional reset,
# deployment via Ansible, admin bootstrapping, CA setup, and node enrollment.
#
# Usage:
#   sudo ./scripts/identity-full-deploy.sh                                    # Deploy only (no reset)
#   sudo FORCE_RESET=1 ./scripts/identity-full-deploy.sh                      # Interactive reset + deploy
#   sudo FORCE_RESET=1 RESET_CONFIRM=yes ./scripts/identity-full-deploy.sh    # Automated reset + deploy
#   sudo DRY_RUN=1 ./scripts/identity-full-deploy.sh                          # Dry-run mode
#
# Environment Variables:
#   DRY_RUN                  - Set to "1" for dry-run mode (default: 0)
#   FORCE_RESET              - Set to "1" to perform reset before deploy (default: 0)
#   RESET_CONFIRM            - Set to "yes" to auto-confirm reset (default: prompt)
#   RESET_REMOVE_OLD         - Set to "1" to remove old backups (default: 0)
#   REDEPLOY_AFTER_RESET     - Set to "1" to deploy after reset (default: 1 if FORCE_RESET=1)
#   FREEIPA_ADMIN_PASSWORD   - FreeIPA admin password for automation
#   KEYCLOAK_ADMIN_PASSWORD  - Keycloak admin password for automation
#   SKIP_NODE_ENROLLMENT     - Set to "1" to skip node enrollment (default: 0)
#   SKIP_VERIFICATION        - Set to "1" to skip final verification (default: 0)
#   INVENTORY                - Path to Ansible inventory (default: /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml)
#   KUBECONFIG_PATH          - Path to kubeconfig (default: /etc/kubernetes/admin.conf)
#

set -euo pipefail

# Source common functions if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/kubespray-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/kubespray-common.sh"
fi

# Get repository root
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration with defaults
DRY_RUN="${DRY_RUN:-0}"
FORCE_RESET="${FORCE_RESET:-0}"
RESET_CONFIRM="${RESET_CONFIRM:-}"
RESET_REMOVE_OLD="${RESET_REMOVE_OLD:-0}"
REDEPLOY_AFTER_RESET="${REDEPLOY_AFTER_RESET:-1}"
SKIP_NODE_ENROLLMENT="${SKIP_NODE_ENROLLMENT:-0}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-0}"
FREEIPA_ADMIN_PASSWORD="${FREEIPA_ADMIN_PASSWORD:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"

# Canonical inventory path (VMStation Deployment Memory canonical inventory rule)
: "${INVENTORY:=/opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml}"
# Fallback to deprecated inventory if canonical doesn't exist
if [[ ! -f "$INVENTORY" ]]; then
    INVENTORY="$REPO_ROOT/inventory.ini"
fi

# Export ANSIBLE_INVENTORY to prevent implicit localhost fallback
# Note: Inventory validity is checked in preflight_checks() before use
export ANSIBLE_INVENTORY="$INVENTORY"

# KUBECONFIG path default
: "${KUBECONFIG_PATH:=/etc/kubernetes/admin.conf}"

# Logging and artifacts directory
LOG_DIR="${LOG_DIR:-/opt/vmstation-org/copilot-identity-fixing-automate}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/identity-full-deploy-${TIMESTAMP}.log"

# Logging functions
log_info() {
    local msg="[INFO] $*"
    echo -e "${BLUE}$msg${NC}"
    echo "[$(date -Iseconds)] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() {
    local msg="[SUCCESS] $*"
    echo -e "${GREEN}$msg${NC}"
    echo "[$(date -Iseconds)] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    local msg="[WARN] $*"
    echo -e "${YELLOW}$msg${NC}"
    echo "[$(date -Iseconds)] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local msg="[ERROR] $*"
    echo -e "${RED}$msg${NC}"
    echo "[$(date -Iseconds)] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_fatal() {
    log_error "$*"
    exit 1
}

log_phase() {
    local phase="$1"
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}PHASE: $phase${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "[$(date -Iseconds)] ========== PHASE: $phase ==========" >> "$LOG_FILE" 2>/dev/null || true
}

# Print banner
print_banner() {
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}Identity Stack Full Deployment Orchestrator${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
}

# Setup logging directory
setup_logging() {
    log_info "Setting up logging directory: $LOG_DIR"
    
    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "$LOG_DIR"
        chmod 755 "$LOG_DIR"
        
        # Create log file
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        
        log_success "Logging to: $LOG_FILE"
    else
        log_info "[DRY-RUN] Would create log directory and file"
    fi
}

# Preflight checks
preflight_checks() {
    log_phase "Preflight Checks"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root (use sudo)"
    fi
    
    # Check required commands
    local missing_cmds=()
    for cmd in kubectl ansible ansible-playbook; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_fatal "Missing required commands: ${missing_cmds[*]}"
    fi
    
    # Check if Ansible inventory exists - fail early with clear error
    if [[ ! -f "$INVENTORY" ]]; then
        log_fatal "Ansible inventory not found at: $INVENTORY
Please ensure the canonical inventory exists at /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
or set INVENTORY environment variable to point to a valid inventory file.
This check prevents Ansible from falling back to implicit localhost."
    fi
    log_info "Using inventory: $INVENTORY"
    log_info "ANSIBLE_INVENTORY exported to: $ANSIBLE_INVENTORY"
    
    # Export KUBECONFIG if KUBECONFIG_PATH exists
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        log_info "Exported KUBECONFIG: $KUBECONFIG"
    else
        log_warn "KUBECONFIG not found at $KUBECONFIG_PATH - kubectl may not work"
    fi
    
    # Check if playbook exists
    local playbook="$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml"
    if [[ ! -f "$playbook" ]]; then
        log_fatal "Identity deployment playbook not found: $playbook"
    fi
    
    log_success "Preflight checks passed"
}

# Display configuration
display_configuration() {
    log_info "Configuration:"
    log_info "  Repository: $REPO_ROOT"
    log_info "  Log Directory: $LOG_DIR"
    log_info "  Log File: $LOG_FILE"
    log_info "  Inventory: $INVENTORY"
    log_info "  ANSIBLE_INVENTORY: $ANSIBLE_INVENTORY (exported)"
    log_info "  KUBECONFIG Path: $KUBECONFIG_PATH"
    if [[ -n "${KUBECONFIG:-}" ]]; then
        log_info "  KUBECONFIG: $KUBECONFIG (exported)"
    fi
    echo ""
    log_info "Workflow Options:"
    log_info "  Dry Run: $DRY_RUN"
    log_info "  Force Reset: $FORCE_RESET"
    log_info "  Reset Confirm: ${RESET_CONFIRM:-<not set>}"
    log_info "  Reset Remove Old: $RESET_REMOVE_OLD"
    log_info "  Redeploy After Reset: $REDEPLOY_AFTER_RESET"
    log_info "  Skip Node Enrollment: $SKIP_NODE_ENROLLMENT"
    log_info "  Skip Verification: $SKIP_VERIFICATION"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "DRY-RUN MODE ENABLED - No actual changes will be made"
        echo ""
    fi
}

# Phase 1: Optional Reset
run_reset() {
    if [[ "$FORCE_RESET" != "1" ]]; then
        log_info "Skipping reset (FORCE_RESET not set)"
        return 0
    fi
    
    log_phase "Identity Stack Reset"
    
    log_info "Running reset-identity-stack.sh..."
    
    # Export environment variables for reset script
    export RESET_CONFIRM
    export RESET_REMOVE_OLD
    export DRY_RUN
    
    if "$SCRIPT_DIR/reset-identity-stack.sh"; then
        log_success "Reset completed successfully"
    else
        log_error "Reset failed"
        return 1
    fi
}

# Phase 2: Deploy Identity Stack via Ansible
run_deployment() {
    if [[ "$FORCE_RESET" == "1" ]] && [[ "$REDEPLOY_AFTER_RESET" != "1" ]]; then
        log_info "Skipping deployment (REDEPLOY_AFTER_RESET not set)"
        return 0
    fi
    
    log_phase "Identity Stack Deployment"
    
    local playbook="$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml"
    
    log_info "Running Ansible playbook: $playbook"
    log_info "Using inventory: $INVENTORY"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would run: ansible-playbook -i \"$INVENTORY\" $playbook --become"
        return 0
    fi
    
    # Run Ansible playbook with explicit inventory to prevent fallback to localhost
    if ansible-playbook -i "$INVENTORY" "$playbook" --become 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Deployment completed successfully"
    else
        log_error "Deployment failed - check log: $LOG_FILE"
        return 1
    fi
}

# Phase 3: Bootstrap Admin Accounts
run_admin_bootstrap() {
    log_phase "Admin Account Bootstrap"
    
    log_info "Running bootstrap-identity-admins.sh..."
    
    # Export passwords if provided
    export FREEIPA_ADMIN_PASSWORD
    export KEYCLOAK_ADMIN_PASSWORD
    export DRY_RUN
    
    if "$SCRIPT_DIR/bootstrap-identity-admins.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Admin bootstrap completed successfully"
    else
        log_warn "Admin bootstrap encountered issues - continuing anyway"
    fi
}

# Phase 4: Setup CA Certificates
run_ca_setup() {
    log_phase "CA Certificate Setup"
    
    log_info "Running request-freeipa-intermediate-ca.sh..."
    
    # Export password if provided
    export FREEIPA_ADMIN_PASSWORD
    export DRY_RUN
    
    if "$SCRIPT_DIR/request-freeipa-intermediate-ca.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "CA setup completed successfully"
    else
        log_warn "CA setup encountered issues - continuing anyway"
    fi
}

# Phase 5: Enroll Cluster Nodes
run_node_enrollment() {
    if [[ "$SKIP_NODE_ENROLLMENT" == "1" ]]; then
        log_info "Skipping node enrollment (SKIP_NODE_ENROLLMENT set)"
        return 0
    fi
    
    log_phase "Cluster Node Enrollment"
    
    log_info "Running enroll-nodes-freeipa.sh..."
    
    # Export configuration
    export FREEIPA_ADMIN_PASSWORD
    export INVENTORY
    export DRY_RUN
    
    if "$SCRIPT_DIR/enroll-nodes-freeipa.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Node enrollment completed successfully"
    else
        log_warn "Node enrollment encountered issues - continuing anyway"
    fi
}

# Phase 6: Final Verification
run_verification() {
    if [[ "$SKIP_VERIFICATION" == "1" ]]; then
        log_info "Skipping verification (SKIP_VERIFICATION set)"
        return 0
    fi
    
    log_phase "Final Verification"
    
    # Check if verification script exists
    local verify_script="$SCRIPT_DIR/verify-identity-deployment.sh"
    if [[ ! -f "$verify_script" ]]; then
        log_warn "Verification script not found: $verify_script"
        return 0
    fi
    
    log_info "Running verify-identity-deployment.sh..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would run verification script"
        return 0
    fi
    
    if "$verify_script" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Verification completed successfully"
    else
        log_warn "Verification reported issues - review output above"
    fi
}

# Generate deployment summary
generate_summary() {
    log_phase "Deployment Summary"
    
    local summary_file="$LOG_DIR/deployment-summary-${TIMESTAMP}.txt"
    
    cat > "$summary_file" << EOF
Identity Stack Full Deployment Summary
Generated: $(date -Iseconds)

Configuration:
  Repository: $REPO_ROOT
  Log File: $LOG_FILE
  Inventory: $INVENTORY

Workflow Executed:
  Force Reset: $FORCE_RESET
  Deployment: $(if [[ "$FORCE_RESET" == "1" ]] && [[ "$REDEPLOY_AFTER_RESET" != "1" ]]; then echo "Skipped"; else echo "Executed"; fi)
  Admin Bootstrap: Executed
  CA Setup: Executed
  Node Enrollment: $(if [[ "$SKIP_NODE_ENROLLMENT" == "1" ]]; then echo "Skipped"; else echo "Executed"; fi)
  Verification: $(if [[ "$SKIP_VERIFICATION" == "1" ]]; then echo "Skipped"; else echo "Executed"; fi)

Credentials Location:
  /root/identity-backup/cluster-admin-credentials.txt
  /root/identity-backup/keycloak-admin-credentials.txt
  /root/identity-backup/freeipa-admin-credentials.txt

CA Certificates:
  /etc/pki/tls/certs/ca.cert.pem
  /root/identity-backup/identity-ca-backup.tar.gz

Access Information:
  Keycloak: http://<node-ip>:30180/auth
  FreeIPA: https://ipa.vmstation.local

Next Steps:
  1. Review credentials in /root/identity-backup/
  2. Access Keycloak admin console
    3. Verify realm 'cluster-services' and LDAP provider 'freeipa' (auto-configured)
    4. Configure your apps (Grafana/Prometheus) to use Keycloak OIDC
    5. Test authentication with FreeIPA users

For More Information:
  - Deployment log: $LOG_FILE
  - Documentation: $REPO_ROOT/docs/IDENTITY-SSO-SETUP.md

EOF
    
    log_success "Summary saved to: $summary_file"
    
    # Display summary
    cat "$summary_file"
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Deployment failed with exit code: $exit_code"
        log_info "Check log file for details: $LOG_FILE"
    fi
}

trap cleanup EXIT


# Pre-deploy check for oauth2-proxy-secrets
precheck_oauth2_proxy_secret() {
    log_info "Checking oauth2-proxy-secrets in namespace identity..."
    local secret_json
    secret_json=$(kubectl -n identity get secret oauth2-proxy-secrets -o json 2>/dev/null || true)
    if [[ -z "$secret_json" ]]; then
        log_warn "oauth2-proxy-secrets not found. Running scripts/apply-oauth2-proxy-secret.sh to create it."
        "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh"
        return
    fi
    # Validate cookie-secret length
    local cookie_secret_b64
    cookie_secret_b64=$(echo "$secret_json" | grep '"cookie-secret"' | awk -F '"' '{print $4}')
    if [[ -z "$cookie_secret_b64" ]]; then
        log_warn "cookie-secret missing in oauth2-proxy-secrets. Recreating secret."
        "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh"
        return
    fi
    local cookie_secret
    cookie_secret=$(echo "$cookie_secret_b64" | { base64 -d 2>/dev/null || base64 --decode 2>/dev/null; } 2>/dev/null || true)
    local len=${#cookie_secret}
    if [[ "$len" != "16" && "$len" != "24" && "$len" != "32" ]]; then
        log_warn "cookie-secret in oauth2-proxy-secrets is invalid length ($len bytes). Recreating secret."
        "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh"
        return
    fi
    # Validate client-secret is present
    local client_secret_b64
    client_secret_b64=$(echo "$secret_json" | grep '"client-secret"' | awk -F '"' '{print $4}')
    local client_secret
    client_secret=$(echo "$client_secret_b64" | { base64 -d 2>/dev/null || base64 --decode 2>/dev/null; } 2>/dev/null || true)
    if [[ -z "$client_secret" ]]; then
        log_warn "client-secret in oauth2-proxy-secrets is empty. Recreating secret."
        "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh"
        return
    fi
    log_success "oauth2-proxy-secrets is present and valid."
}

# Main execution
main() {
    print_banner
    
    # Setup logging
    setup_logging
    
    # Display configuration
    display_configuration
    
    # Preflight checks
    preflight_checks

    # Pre-deploy secret check
    precheck_oauth2_proxy_secret

    echo ""
    log_info "Starting identity stack deployment workflow..."
    echo ""
    
    # Phase 1: Optional Reset
    if ! run_reset; then
        log_fatal "Reset phase failed - aborting"
    fi
    
    # Phase 2: Deploy Identity Stack
    if ! run_deployment; then
        log_fatal "Deployment phase failed - aborting"
    fi
    
    # Wait a bit for pods to stabilize after deployment
    # Only wait if we're not in dry-run and we actually deployed something
    # (either no reset, or reset with redeploy)
    local should_wait=0
    if [[ "$DRY_RUN" != "1" ]]; then
        if [[ "$FORCE_RESET" != "1" ]]; then
            # No reset, so we deployed
            should_wait=1
        elif [[ "$REDEPLOY_AFTER_RESET" == "1" ]]; then
            # Reset with redeploy
            should_wait=1
        fi
    fi
    
    if [[ $should_wait -eq 1 ]]; then
        log_info "Waiting 30 seconds for pods to stabilize..."
        sleep 30
    fi
    
    # Phase 3: Bootstrap Admin Accounts
    run_admin_bootstrap
    
    # Phase 4: Setup CA Certificates
    run_ca_setup
    
    # Phase 5: Enroll Cluster Nodes
    run_node_enrollment
    
    # Phase 6: Final Verification
    run_verification
    
    # Generate Summary
    echo ""
    generate_summary
    
    echo ""
    log_success "============================================================"
    log_success "Identity Stack Deployment Complete!"
    log_success "============================================================"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "This was a DRY-RUN - no actual changes were made"
        log_info "Remove DRY_RUN=1 to execute for real"
    else
        log_info "All phases completed successfully!"
        log_info "Review the summary and logs for details"
    fi
    
    echo ""
    log_info "Log file: $LOG_FILE"
    echo ""
}

# Run main function
main "$@"
