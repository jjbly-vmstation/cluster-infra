#!/usr/bin/env bash
# automate-identity-dns-and-coredns.sh
# 
# Purpose: Automated wrapper to extract FreeIPA DNS records, configure CoreDNS
#          via existing Ansible playbook, and verify readiness of identity services
# 
# This script automates steps 4a->5 for identity services by:
#   1. Optionally running cleanup script (if FORCE_CLEANUP=1)
#   2. Extracting FreeIPA DNS records from pod
#   3. Running Ansible playbook to configure CoreDNS with FreeIPA DNS
#   4. Verifying FreeIPA and Keycloak readiness
#
# Usage:
#   ./scripts/automate-identity-dns-and-coredns.sh
#
# Environment Variables:
#   FORCE_CLEANUP=1  - Automatically run cleanup-identity-stack.sh before deployment
#
# Examples:
#   # Standard run (no cleanup)
#   ./scripts/automate-identity-dns-and-coredns.sh
#
#   # With automatic cleanup before redeploy
#   FORCE_CLEANUP=1 ./scripts/automate-identity-dns-and-coredns.sh

set -euo pipefail

# Configuration - can be overridden via environment variables
WORKDIR="${WORKDIR:-/opt/vmstation-org/copilot-identity-fixing-automate}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_PLAYBOOK_PATH="${ANSIBLE_PLAYBOOK_PATH:-/opt/vmstation-org/cluster-infra/ansible/playbooks/configure-coredns-freeipa.yml}"
INVENTORY="${INVENTORY:-/opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml}"
CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-/opt/vmstation-org/cluster-infra/scripts/cleanup-identity-stack.sh}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Print header
cat << 'EOF'

================================================================================
  Identity Services DNS and CoreDNS Automation
================================================================================
  This script automates the following steps:
    1. Optional: Cleanup identity stack (if FORCE_CLEANUP=1)
    2. Extract FreeIPA DNS records from pod
    3. Configure CoreDNS via Ansible playbook
    4. Verify FreeIPA and Keycloak readiness
================================================================================

EOF

# Create workspace directory
mkdir -p "$WORKDIR"
log_info "Workspace: $WORKDIR"
echo ""

# ============================================================================
# Step 0: Optional Cleanup
# ============================================================================
log_step "Step 0: Cleanup (Optional)"
echo "-----------------------------------"

if [ "${FORCE_CLEANUP:-0}" -eq 1 ]; then
    log_info "FORCE_CLEANUP=1 detected. Running cleanup-identity-stack.sh..."
    
    if [ -x "$CLEANUP_SCRIPT" ]; then
        log_info "Executing: sudo bash $CLEANUP_SCRIPT"
        sudo bash "$CLEANUP_SCRIPT"
        log_info "Cleanup completed successfully"
    elif [ -f "$CLEANUP_SCRIPT" ]; then
        log_error "Cleanup script exists but is not executable: $CLEANUP_SCRIPT"
        log_info "Attempting to make it executable..."
        sudo chmod +x "$CLEANUP_SCRIPT"
        log_info "Executing: sudo bash $CLEANUP_SCRIPT"
        sudo bash "$CLEANUP_SCRIPT"
        log_info "Cleanup completed successfully"
    else
        log_error "Cleanup script not found: $CLEANUP_SCRIPT"
        log_warn "Continuing without cleanup..."
    fi
else
    log_info "Cleanup step skipped (FORCE_CLEANUP not set)"
    log_info "To run cleanup automatically, set: FORCE_CLEANUP=1"
fi

echo ""

# ============================================================================
# Step 1: Extract FreeIPA DNS Records
# ============================================================================
log_step "Step 1: Extract FreeIPA DNS Records"
echo "-----------------------------------"

EXTRACT_SCRIPT="$SCRIPTS_DIR/extract-freeipa-dns-records.sh"

if [ ! -f "$EXTRACT_SCRIPT" ]; then
    log_error "Extract script not found: $EXTRACT_SCRIPT"
    exit 1
fi

if [ ! -x "$EXTRACT_SCRIPT" ]; then
    log_warn "Extract script is not executable, making it executable..."
    chmod +x "$EXTRACT_SCRIPT"
fi

log_info "Running: $EXTRACT_SCRIPT"
bash "$EXTRACT_SCRIPT" || {
    log_error "Failed to extract FreeIPA DNS records"
    exit 1
}

log_info "DNS records extraction completed"
echo ""

# ============================================================================
# Step 2: Configure CoreDNS via Ansible Playbook
# ============================================================================
log_step "Step 2: Configure CoreDNS with FreeIPA DNS"
echo "-----------------------------------"

if [ ! -f "$ANSIBLE_PLAYBOOK_PATH" ]; then
    log_error "Ansible playbook not found: $ANSIBLE_PLAYBOOK_PATH"
    log_error "Please ensure the playbook exists before running this script"
    exit 1
fi

if [ ! -f "$INVENTORY" ]; then
    log_warn "Inventory file not found at: $INVENTORY"
    log_info "Checking alternative inventory location..."
    
    # Try alternative inventory locations relative to script directory
    CLUSTER_INFRA_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
    ALT_INVENTORY="$CLUSTER_INFRA_ROOT/inventory/mycluster/hosts.yaml"
    if [ -f "$ALT_INVENTORY" ]; then
        log_info "Using alternative inventory: $ALT_INVENTORY"
        INVENTORY="$ALT_INVENTORY"
    else
        log_error "No valid inventory file found"
        exit 1
    fi
fi

log_info "Running Ansible playbook: $ANSIBLE_PLAYBOOK_PATH"
log_info "Using inventory: $INVENTORY"
log_info "Command: sudo ansible-playbook -i $INVENTORY $ANSIBLE_PLAYBOOK_PATH --become"

if ! sudo ansible-playbook -i "$INVENTORY" "$ANSIBLE_PLAYBOOK_PATH" --become; then
    log_error "Ansible playbook execution failed"
    log_error "Check the logs above for details"
    exit 1
fi

log_info "CoreDNS configuration completed"
echo ""

# ============================================================================
# Step 3: Verify FreeIPA and Keycloak Readiness
# ============================================================================
log_step "Step 3: Verify FreeIPA and Keycloak Readiness"
echo "-----------------------------------"

VERIFY_SCRIPT="$SCRIPTS_DIR/verify-freeipa-keycloak-readiness.sh"

if [ ! -f "$VERIFY_SCRIPT" ]; then
    log_error "Verify script not found: $VERIFY_SCRIPT"
    exit 1
fi

if [ ! -x "$VERIFY_SCRIPT" ]; then
    log_warn "Verify script is not executable, making it executable..."
    chmod +x "$VERIFY_SCRIPT"
fi

log_info "Running: $VERIFY_SCRIPT"
bash "$VERIFY_SCRIPT" || {
    log_warn "Verification script reported issues"
    log_warn "Review the output above for details"
}

echo ""

# ============================================================================
# Summary
# ============================================================================
cat << EOF
${GREEN}================================================================================
  Automation Complete
================================================================================${NC}

${BLUE}What was done:${NC}
  ✓ FreeIPA DNS records extracted
  ✓ CoreDNS configured with FreeIPA DNS via Ansible
  ✓ FreeIPA and Keycloak readiness verified

${BLUE}Next Steps:${NC}
  1. Test Keycloak UI access:
     - URL: https://ipa.vmstation.local (if DNS configured)
     - URL: http://192.168.4.63:30180/auth/admin/ (direct IP access)
  
  2. Verify DNS resolution from cluster pods:
     kubectl run test-dns --image=busybox:1.36 --rm -i --restart=Never \\
       --command -- nslookup ipa.vmstation.local
  
  3. If DNS changes were made, ensure all nodes/pods can resolve:
     - ipa.vmstation.local
     - vmstation.local
  
  4. Check credentials:
     Credentials are typically stored in: /root/identity-backup/

${BLUE}Troubleshooting:${NC}
  - If pods cannot resolve DNS, check CoreDNS logs:
    kubectl logs -n kube-system -l k8s-app=kube-dns
  
  - If FreeIPA is not accessible, check pod status:
    kubectl get pods -n identity
    kubectl logs -n identity freeipa-0
  
  - For additional verification, run:
    ./scripts/verify-freeipa-keycloak-readiness.sh --verbose

${GREEN}================================================================================${NC}

EOF

log_info "Script execution completed successfully"
exit 0
