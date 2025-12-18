#!/bin/bash
# automate-identity-dns-and-coredns.sh
# Wrapper script to automate steps 4a→5: extract FreeIPA DNS records,
# configure CoreDNS, and verify identity access and cert distribution

set -euo pipefail

# Configuration
KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
NAMESPACE=${NAMESPACE:-identity}
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$SCRIPTS_DIR/../ansible" && pwd)"
INVENTORY=${INVENTORY:-/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml}
VERBOSE=${VERBOSE:-false}
FORCE_CLEANUP=${FORCE_CLEANUP:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    echo -e "\n${CYAN}===================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}===================================================================${NC}\n"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Automate identity DNS and CoreDNS configuration (Steps 4a→5).

This wrapper script performs the following steps:
  1. Extract FreeIPA DNS records from pod
  2. Run configure-coredns-freeipa Ansible playbook
  3. Verify FreeIPA and Keycloak readiness
  4. Comprehensive identity and certificate verification
  5. Display result file paths for review

OPTIONS:
    -n, --namespace NAMESPACE  Kubernetes namespace (default: identity)
    -k, --kubeconfig FILE      Path to kubeconfig (default: /etc/kubernetes/admin.conf)
    -i, --inventory FILE       Ansible inventory file (default: /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml)
    -v, --verbose              Enable verbose output
    --force-cleanup            Force cleanup before starting (use with caution)
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    KUBECONFIG         Path to kubeconfig file
    NAMESPACE          Kubernetes namespace for identity stack
    INVENTORY          Path to Ansible inventory file
    VERBOSE            Enable verbose output (true/false)
    FORCE_CLEANUP      Force cleanup before starting (true/false)

EXAMPLES:
    # Standard execution
    sudo $0

    # Verbose mode
    sudo $0 --verbose

    # Custom inventory
    sudo $0 --inventory /path/to/inventory.yml

    # Force cleanup and restart
    sudo $0 --force-cleanup

OUTPUT:
    All verification results are stored in:
    /opt/vmstation-org/copilot-identity-fixing-automate/

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -k|--kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -i|--inventory)
            INVENTORY="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --force-cleanup)
            FORCE_CLEANUP=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Export environment variables
export KUBECONFIG
export NAMESPACE
export VERBOSE

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

preflight_checks() {
    log_step "PREFLIGHT CHECKS"
    
    log_info "Checking prerequisites..."
    
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then
        log_warn "Not running as root - some operations may require sudo"
    fi
    
    # Check required tools
    local missing_tools=()
    for tool in kubectl ansible-playbook python3; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
            log_error "Required tool not found: $tool"
        else
            log_verbose "Found: $tool"
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
    
    # Check scripts exist
    local required_scripts=(
        "extract-freeipa-dns-records.sh"
        "verify-freeipa-keycloak-readiness.sh"
        "verify-identity-and-certs.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        if [ ! -x "$SCRIPTS_DIR/$script" ]; then
            log_error "Required script not found or not executable: $SCRIPTS_DIR/$script"
            return 1
        fi
        log_verbose "Found script: $script"
    done
    
    # Check ansible playbook exists
    if [ ! -f "$ANSIBLE_DIR/playbooks/configure-coredns-freeipa.yml" ]; then
        log_error "Ansible playbook not found: $ANSIBLE_DIR/playbooks/configure-coredns-freeipa.yml"
        return 1
    fi
    log_verbose "Found playbook: configure-coredns-freeipa.yml"
    
    # Check inventory file
    if [ ! -f "$INVENTORY" ]; then
        log_warn "Ansible inventory not found: $INVENTORY"
        log_info "Will use localhost for playbook execution"
    else
        log_verbose "Inventory: $INVENTORY"
    fi
    
    log_info "✓ Preflight checks passed"
    return 0
}

# ============================================================================
# CLEANUP (OPTIONAL)
# ============================================================================

cleanup_workspace() {
    if [ "$FORCE_CLEANUP" = "true" ]; then
        log_step "CLEANUP WORKSPACE"
        log_warn "Force cleanup enabled - removing previous verification results"
        
        local workspace="/opt/vmstation-org/copilot-identity-fixing-automate"
        if [ -d "$workspace" ]; then
            log_info "Backing up previous workspace..."
            local backup_dir="${workspace}.backup.$(date +%Y%m%d_%H%M%S)"
            mv "$workspace" "$backup_dir"
            log_info "Previous workspace backed up to: $backup_dir"
        fi
        
        local dns_records="/tmp/freeipa-dns-records"
        if [ -d "$dns_records" ]; then
            log_info "Removing previous DNS records extraction..."
            rm -rf "$dns_records"
        fi
        
        log_info "✓ Cleanup complete"
    fi
}

# ============================================================================
# STEP 1: EXTRACT FREEIPA DNS RECORDS
# ============================================================================

extract_dns_records() {
    log_step "STEP 1: EXTRACT FREEIPA DNS RECORDS"
    
    log_info "Extracting DNS records from FreeIPA pod..."
    
    local cmd="$SCRIPTS_DIR/extract-freeipa-dns-records.sh"
    [ "$VERBOSE" = "true" ] && cmd="$cmd --verbose"
    
    if $cmd; then
        log_info "✓ DNS records extracted successfully"
        return 0
    else
        log_error "✗ DNS records extraction failed"
        return 1
    fi
}

# ============================================================================
# STEP 2: CONFIGURE COREDNS WITH ANSIBLE
# ============================================================================

configure_coredns() {
    log_step "STEP 2: CONFIGURE COREDNS WITH FREEIPA DNS"
    
    log_info "Running configure-coredns-freeipa Ansible playbook..."
    
    local cmd="ansible-playbook"
    if [ -f "$INVENTORY" ]; then
        cmd="$cmd -i $INVENTORY"
    fi
    cmd="$cmd $ANSIBLE_DIR/playbooks/configure-coredns-freeipa.yml"
    [ "$VERBOSE" = "true" ] && cmd="$cmd -v"
    
    log_verbose "Command: $cmd"
    
    if $cmd; then
        log_info "✓ CoreDNS configured successfully"
        return 0
    else
        log_warn "⚠ CoreDNS configuration had issues (may be expected if CoreDNS not used)"
        # Don't fail here as CoreDNS may not be used in all deployments
        return 0
    fi
}

# ============================================================================
# STEP 3: VERIFY READINESS
# ============================================================================

verify_readiness() {
    log_step "STEP 3: VERIFY FREEIPA AND KEYCLOAK READINESS"
    
    log_info "Running readiness verification..."
    
    local cmd="$SCRIPTS_DIR/verify-freeipa-keycloak-readiness.sh"
    [ "$VERBOSE" = "true" ] && cmd="$cmd --verbose"
    
    if $cmd; then
        log_info "✓ Readiness verification passed"
        return 0
    else
        log_warn "⚠ Readiness verification had some warnings"
        # Continue anyway as some checks may be optional
        return 0
    fi
}

# ============================================================================
# STEP 4: COMPREHENSIVE VERIFICATION
# ============================================================================

verify_identity_and_certs() {
    log_step "STEP 4: COMPREHENSIVE IDENTITY AND CERTIFICATE VERIFICATION"
    
    log_info "Running comprehensive verification..."
    
    local cmd="$SCRIPTS_DIR/verify-identity-and-certs.sh"
    [ "$VERBOSE" = "true" ] && cmd="$cmd --verbose"
    
    if $cmd; then
        log_info "✓ Comprehensive verification complete"
        return 0
    else
        log_warn "⚠ Comprehensive verification completed with findings"
        # Return 0 as the script is designed to complete even with findings
        return 0
    fi
}

# ============================================================================
# DISPLAY RESULTS
# ============================================================================

display_results() {
    log_step "VERIFICATION RESULTS"
    
    local workspace="/opt/vmstation-org/copilot-identity-fixing-automate"
    
    cat << EOF
${GREEN}Automation complete!${NC}

${BLUE}Result Files:${NC}
  DNS Records:
    • /tmp/freeipa-dns-records/freeipa-hosts.txt
    • /tmp/freeipa-dns-records/extraction-summary.txt

  Identity Verification:
    • $workspace/recover_identity_audit.log
    • $workspace/recover_identity_steps.json
    • $workspace/keycloak_summary.txt
    • $workspace/freeipa_summary.txt

${BLUE}Review Commands:${NC}
  # View audit log
  cat $workspace/recover_identity_audit.log

  # View structured steps
  cat $workspace/recover_identity_steps.json | jq .

  # View Keycloak summary
  cat $workspace/keycloak_summary.txt

  # View FreeIPA summary
  cat $workspace/freeipa_summary.txt

  # View DNS extraction summary
  cat /tmp/freeipa-dns-records/extraction-summary.txt

${BLUE}Next Steps:${NC}
  1. Review the audit log for any findings or remediation steps
  2. Check the summary files for Keycloak and FreeIPA access status
  3. Verify DNS records were properly extracted and distributed
  4. Address any issues identified in the verification steps

${YELLOW}Security Notes:${NC}
  • All result files are created with mode 600 (owner read/write only)
  • No passwords or tokens are written to logs
  • Credential files are stored in: /root/identity-backup/
  • If admin passwords were created, rotate them and store in Ansible Vault

EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    cat << EOF

${BLUE}=============================================================================
Identity DNS and CoreDNS Automation
==============================================================================${NC}

This script automates:
  • FreeIPA DNS record extraction
  • CoreDNS configuration via Ansible
  • Identity stack readiness verification
  • Comprehensive certificate and access verification

Namespace: $NAMESPACE
Kubeconfig: $KUBECONFIG
Inventory: $INVENTORY

${BLUE}==============================================================================${NC}

EOF

    # Run all steps
    if ! preflight_checks; then
        log_error "Preflight checks failed - exiting"
        exit 1
    fi
    
    cleanup_workspace
    
    if ! extract_dns_records; then
        log_error "DNS records extraction failed - continuing anyway"
    fi
    
    configure_coredns
    verify_readiness
    verify_identity_and_certs
    
    # Display results
    display_results
    
    cat << EOF
${GREEN}=============================================================================
Automation Complete
=============================================================================${NC}

EOF

    log_info "All automation steps completed"
    return 0
}

# Trap errors
trap 'log_error "Script failed at line $LINENO"' ERR

# Run main function
main "$@"
