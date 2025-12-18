#!/usr/bin/env bash
#
# enroll-nodes-freeipa.sh
#
# Purpose: Enroll all cluster nodes to use FreeIPA for authentication
# This script uses the existing identity-freeipa-ldap-client Ansible role to enroll nodes.
# It is idempotent - will not re-enroll nodes that are already enrolled.
#
# Usage:
#   sudo ./scripts/enroll-nodes-freeipa.sh
#   sudo FREEIPA_ADMIN_PASSWORD=secret ./scripts/enroll-nodes-freeipa.sh
#
# Environment Variables:
#   FREEIPA_ADMIN_PASSWORD - FreeIPA admin password (required if not in secret)
#   INVENTORY              - Path to Ansible inventory (default: /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml)
#   FREEIPA_SERVER_IP      - FreeIPA server IP (default: 192.168.4.63)
#   FREEIPA_DOMAIN         - FreeIPA domain (default: vmstation.local)
#   FREEIPA_REALM          - FreeIPA realm (default: VMSTATION.LOCAL)
#   DRY_RUN                - Set to "1" for dry-run mode (default: 0)
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
NC='\033[0m' # No Color

# Configuration with defaults
# Canonical inventory path (VMStation Deployment Memory canonical inventory rule)
: "${INVENTORY:=/opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml}"
# Fallback to deprecated inventory if canonical doesn't exist
if [[ ! -f "$INVENTORY" ]]; then
    INVENTORY="$REPO_ROOT/inventory.ini"
fi
FREEIPA_SERVER_IP="${FREEIPA_SERVER_IP:-192.168.4.63}"
FREEIPA_DOMAIN="${FREEIPA_DOMAIN:-vmstation.local}"
FREEIPA_REALM="${FREEIPA_REALM:-VMSTATION.LOCAL}"
FREEIPA_SERVER_HOSTNAME="${FREEIPA_SERVER_HOSTNAME:-ipa.vmstation.local}"
FREEIPA_ADMIN_PASSWORD="${FREEIPA_ADMIN_PASSWORD:-}"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE_IDENTITY="${NAMESPACE_IDENTITY:-identity}"
DRY_RUN="${DRY_RUN:-0}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_fatal() {
    log_error "$*"
    exit 1
}

# Print banner
print_banner() {
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}FreeIPA Node Enrollment Script${NC}"
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
    for cmd in ansible ansible-playbook; do
        if ! command -v "$cmd" &> /dev/null; then
            log_fatal "$cmd command not found - please install Ansible"
        fi
    done
    
    # Check if inventory file exists - fail early with clear error
    if [[ ! -f "$INVENTORY" ]]; then
        log_fatal "Ansible inventory not found at: $INVENTORY
Please ensure the canonical inventory exists at /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
or set INVENTORY environment variable to point to a valid inventory file.
This check prevents Ansible from falling back to implicit localhost."
    fi
    log_info "Using inventory: $INVENTORY"
    
    log_success "Preflight checks passed"
}

# Check if FreeIPA is running
check_freeipa_running() {
    log_info "Checking if FreeIPA is running..."
    
    if [[ ! -f "$KUBECONFIG" ]]; then
        log_warn "Kubeconfig not found - cannot check FreeIPA status"
        return 1
    fi
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl not found - cannot check FreeIPA status"
        return 1
    fi
    
    # Check if FreeIPA pod exists and is ready
    local freeipa_pod
    freeipa_pod=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pods -l app=freeipa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$freeipa_pod" ]]; then
        log_warn "FreeIPA pod not found - deploy FreeIPA before enrolling nodes"
        return 1
    fi
    
    local ready
    ready=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get pod "$freeipa_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [[ "$ready" != "True" ]]; then
        log_warn "FreeIPA pod is not ready - wait for FreeIPA to be fully running"
        return 1
    fi
    
    log_success "FreeIPA is running"
    return 0
}

# Get FreeIPA admin password
get_freeipa_password() {
    if [[ -n "$FREEIPA_ADMIN_PASSWORD" ]]; then
        log_info "Using provided FreeIPA admin password"
        return 0
    fi
    
    # Try to retrieve from Kubernetes secret
    if [[ -f "$KUBECONFIG" ]] && command -v kubectl &> /dev/null; then
        if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds &> /dev/null; then
            FREEIPA_ADMIN_PASSWORD=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE_IDENTITY" get secret freeipa-admin-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
            
            if [[ -n "$FREEIPA_ADMIN_PASSWORD" ]]; then
                log_success "Retrieved FreeIPA admin password from Kubernetes secret"
                return 0
            fi
        fi
    fi
    
    # Try to read from credentials file
    local creds_file="/root/identity-backup/freeipa-admin-credentials.txt"
    if [[ -f "$creds_file" ]]; then
        FREEIPA_ADMIN_PASSWORD=$(grep "^Password:" "$creds_file" | awk '{print $2}' || echo "")
        
        if [[ -n "$FREEIPA_ADMIN_PASSWORD" ]]; then
            log_success "Retrieved FreeIPA admin password from credentials file"
            return 0
        fi
    fi
    
    log_error "FreeIPA admin password not found"
    log_info "Please provide it via FREEIPA_ADMIN_PASSWORD environment variable"
    return 1
}

# Create temporary Ansible playbook for node enrollment
create_enrollment_playbook() {
    log_info "Creating temporary enrollment playbook..."
    
    local TMP_PLAYBOOK="/tmp/freeipa-node-enrollment.yml"
    
    cat > "$TMP_PLAYBOOK" << 'EOF'
---
# Temporary playbook for FreeIPA node enrollment
- name: Enroll cluster nodes to FreeIPA
  hosts: all
  become: true
  gather_facts: true
  
  vars:
    freeipa_server_hostname: "{{ lookup('env', 'FREEIPA_SERVER_HOSTNAME') | default('ipa.vmstation.local', true) }}"
    freeipa_domain: "{{ lookup('env', 'FREEIPA_DOMAIN') | default('vmstation.local', true) }}"
    freeipa_realm: "{{ lookup('env', 'FREEIPA_REALM') | default('VMSTATION.LOCAL', true) }}"
    freeipa_server_ip: "{{ lookup('env', 'FREEIPA_SERVER_IP') | default('192.168.4.63', true) }}"
    freeipa_admin_password: "{{ lookup('env', 'FREEIPA_ADMIN_PASSWORD') }}"
    freeipa_client_install: true
  
  tasks:
    - name: Display enrollment information
      debug:
        msg: |
          Enrolling {{ inventory_hostname }} to FreeIPA
          Server: {{ freeipa_server_hostname }}
          Domain: {{ freeipa_domain }}
          Realm: {{ freeipa_realm }}
    
    - name: Add FreeIPA server to /etc/hosts
      lineinfile:
        path: /etc/hosts
        line: "{{ freeipa_server_ip }} {{ freeipa_server_hostname }}"
        state: present
        regexp: "^{{ freeipa_server_ip }}.*{{ freeipa_server_hostname }}"
    
    - name: Check if node is already joined to FreeIPA domain
      stat:
        path: /etc/ipa/default.conf
      register: ipa_client_configured
    
    - name: Install FreeIPA client packages (RHEL/AlmaLinux)
      package:
        name:
          - ipa-client
          - sssd
          - sssd-client
        state: present
      when:
        - not ipa_client_configured.stat.exists
        - ansible_os_family == "RedHat"
    
    - name: Install FreeIPA client packages (Debian/Ubuntu)
      package:
        name:
          - freeipa-client
          - sssd
          - sssd-tools
        state: present
      when:
        - not ipa_client_configured.stat.exists
        - ansible_os_family == "Debian"
    
    - name: Join node to FreeIPA domain
      shell: >-
        ipa-client-install --unattended
        --server={{ freeipa_server_hostname }}
        --domain={{ freeipa_domain }}
        --realm={{ freeipa_realm }}
        --principal=admin
        --password={{ freeipa_admin_password }}
        --no-ntp
        --force-join
        --mkhomedir
      when:
        - not ipa_client_configured.stat.exists
        - freeipa_client_install | bool
      register: ipa_client_join
      # Exit code 0: Successful enrollment
      # Exit code 3: Client already enrolled (acceptable with --force-join)
      # Any other exit code: Failure
      failed_when: ipa_client_join.rc != 0 and ipa_client_join.rc != 3
      changed_when: ipa_client_join.rc == 0
    
    - name: Ensure SSSD service is enabled and started
      service:
        name: sssd
        state: started
        enabled: true
    
    - name: Display enrollment status
      debug:
        msg: |
          FreeIPA client configured on {{ inventory_hostname }}
          Status: {{ 'Already enrolled' if ipa_client_configured.stat.exists else 'Newly enrolled' }}
EOF
    
    # Set restrictive permissions immediately after file creation
    chmod 600 "$TMP_PLAYBOOK"
    
    # Verify playbook was created successfully
    if [[ ! -f "$TMP_PLAYBOOK" ]]; then
        log_fatal "Failed to create temporary playbook at $TMP_PLAYBOOK"
    fi
    
    log_success "Created enrollment playbook: $TMP_PLAYBOOK"
    echo "$TMP_PLAYBOOK"
}

# Run Ansible playbook for enrollment
run_enrollment() {
    log_info "Running node enrollment via Ansible..."
    
    # Create playbook
    local TMP_PLAYBOOK
    TMP_PLAYBOOK=$(create_enrollment_playbook)
    
    # Verify playbook exists before proceeding
    if [[ ! -f "$TMP_PLAYBOOK" ]]; then
        log_fatal "Temporary playbook not found at: $TMP_PLAYBOOK"
    fi
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would run: ansible-playbook -i \"$INVENTORY\" \"$TMP_PLAYBOOK\""
        log_info "[DRY-RUN] With environment variables:"
        log_info "  FREEIPA_SERVER_HOSTNAME=$FREEIPA_SERVER_HOSTNAME"
        log_info "  FREEIPA_DOMAIN=$FREEIPA_DOMAIN"
        log_info "  FREEIPA_REALM=$FREEIPA_REALM"
        log_info "  FREEIPA_SERVER_IP=$FREEIPA_SERVER_IP"
        log_info "  FREEIPA_ADMIN_PASSWORD=***"
        return 0
    fi
    
    # Export environment variables for the playbook
    export FREEIPA_SERVER_HOSTNAME
    export FREEIPA_DOMAIN
    export FREEIPA_REALM
    export FREEIPA_SERVER_IP
    export FREEIPA_ADMIN_PASSWORD
    
    # Run playbook with explicit inventory to prevent fallback to localhost
    log_info "Executing Ansible playbook with inventory: $INVENTORY"
    if ansible-playbook -i "$INVENTORY" "$TMP_PLAYBOOK" --become; then
        log_success "Node enrollment completed successfully"
        # Cleanup temporary playbook on success
        rm -f "$TMP_PLAYBOOK"
    else
        local exit_code=$?
        log_error "Node enrollment failed - check Ansible output above"
        log_error "Temporary playbook preserved at: $TMP_PLAYBOOK for debugging"
        return $exit_code
    fi
}

# Verify node enrollment
verify_enrollment() {
    log_info "Verifying node enrollment..."
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would verify node enrollment"
        return 0
    fi
    
    # Create simple verification playbook
    local verify_playbook="/tmp/verify-freeipa-enrollment.yml"
    
    cat > "$verify_playbook" << 'EOF'
---
- name: Verify FreeIPA enrollment
  hosts: all
  become: true
  gather_facts: false
  
  tasks:
    - name: Check if IPA client is configured
      stat:
        path: /etc/ipa/default.conf
      register: ipa_configured
    
    - name: Check SSSD service status
      service:
        name: sssd
        state: started
      register: sssd_status
      failed_when: false
    
    - name: Display verification results
      debug:
        msg: |
          Node: {{ inventory_hostname }}
          IPA configured: {{ ipa_configured.stat.exists }}
          SSSD running: {{ sssd_status.state is defined and sssd_status.state == 'started' }}
EOF
    
    log_info "Running verification checks..."
    ansible-playbook -i "$INVENTORY" "$verify_playbook" --become || log_warn "Verification encountered issues"
    
    # Cleanup
    rm -f "$verify_playbook"
    
    log_success "Verification completed"
}

# Main execution
main() {
    print_banner
    
    # Run preflight checks
    preflight_checks
    
    echo ""
    
    # Check if FreeIPA is running
    if ! check_freeipa_running; then
        log_fatal "FreeIPA is not running - deploy FreeIPA before enrolling nodes"
    fi
    
    echo ""
    
    # Get FreeIPA admin password
    if ! get_freeipa_password; then
        log_fatal "Cannot proceed without FreeIPA admin password"
    fi
    
    echo ""
    log_info "Starting node enrollment to FreeIPA..."
    echo ""
    log_info "Configuration:"
    log_info "  FreeIPA Server: $FREEIPA_SERVER_HOSTNAME ($FREEIPA_SERVER_IP)"
    log_info "  Domain: $FREEIPA_DOMAIN"
    log_info "  Realm: $FREEIPA_REALM"
    log_info "  Inventory: $INVENTORY"
    echo ""
    
    # Run enrollment
    if ! run_enrollment; then
        log_error "Enrollment failed"
        exit 1
    fi
    
    echo ""
    
    # Verify enrollment
    verify_enrollment
    
    echo ""
    log_success "============================================================"
    log_success "Node Enrollment Complete!"
    log_success "============================================================"
    echo ""
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "This was a DRY-RUN - no actual changes were made"
    else
        log_info "All cluster nodes are now enrolled with FreeIPA"
        log_info "Users can now authenticate using their FreeIPA credentials"
        echo ""
        log_info "Test authentication:"
        log_info "  su - <freeipa-username>"
        log_info "  id <freeipa-username>"
    fi
    echo ""
}

# Run main function
main "$@"
