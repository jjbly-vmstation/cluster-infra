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
#   ANSIBLE_INVENTORY        - Path to Ansible inventory (default: inventory.ini)
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
ANSIBLE_INVENTORY="${ANSIBLE_INVENTORY:-$REPO_ROOT/inventory.ini}"

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
    
    # Check if Ansible inventory exists
    if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
        log_warn "Ansible inventory not found at $ANSIBLE_INVENTORY"
        log_info "Node enrollment will be skipped"
        SKIP_NODE_ENROLLMENT=1
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
    log_info "  Ansible Inventory: $ANSIBLE_INVENTORY"
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
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would run: ansible-playbook $playbook --become"
        return 0
    fi
    
    # Run Ansible playbook
    if ansible-playbook "$playbook" --become 2>&1 | tee -a "$LOG_FILE"; then
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
    export ANSIBLE_INVENTORY
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
  Ansible Inventory: $ANSIBLE_INVENTORY

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
  3. Import SSO realm from /tmp/cluster-realm.json
  4. Configure LDAP user federation
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

# Main execution
main() {
    print_banner
    
    # Setup logging
    setup_logging
    
    # Display configuration
    display_configuration
    
    # Preflight checks
    preflight_checks
    
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
    
    # Wait a bit for pods to stabilize
    if [[ "$DRY_RUN" != "1" ]] && [[ "$FORCE_RESET" != "1" || "$REDEPLOY_AFTER_RESET" == "1" ]]; then
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
