#!/usr/bin/env bash
# VMStation Inventory Validation Script
# Tests and validates Ansible inventory files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library functions
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-common.sh"
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-validation.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [INVENTORY_FILE]

Test and validate Ansible inventory files.

OPTIONS:
    -h, --help              Show this help message
    -e, --environment ENV   Test environment inventory (production|staging)
    -c, --check-ssh         Check SSH connectivity to hosts
    -v, --verbose           Verbose output

EXAMPLES:
    $(basename "$0") -e production
    $(basename "$0") /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
    $(basename "$0") -e production -c
EOF
}

main() {
    local inventory_file=""
    local check_ssh=false
    local verbose=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -e|--environment)
                shift
                local env="$1"
                inventory_file="/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml"
                ;;
            -c|--check-ssh)
                check_ssh=true
                ;;
            -v|--verbose)
                verbose=true
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                inventory_file="$1"
                ;;
        esac
        shift
    done
    
    # Default to production inventory if not specified
    if [[ -z "$inventory_file" ]]; then
        inventory_file="/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml"
    fi
    
    print_banner "Inventory Validation"
    
    log_info "Testing inventory: $inventory_file"
    echo ""
    
    local failed_checks=0
    
    # Validate inventory file exists and is readable
    if ! validate_inventory_file "$inventory_file"; then
        ((failed_checks++))
    fi
    
    # Validate YAML syntax if applicable
    if [[ "$inventory_file" =~ \.ya?ml$ ]]; then
        if ! validate_yaml_syntax "$inventory_file"; then
            ((failed_checks++))
        fi
    fi
    
    # Validate Ansible inventory structure
    if ! validate_ansible_inventory "$inventory_file"; then
        ((failed_checks++))
    fi
    
    # Check for required Kubespray groups
    log_info "Checking for required Kubespray groups..."
    local required_groups=("kube_control_plane" "kube_node" "etcd" "k8s_cluster")
    if ! validate_inventory_groups "$inventory_file" "${required_groups[@]}"; then
        log_warn "Some Kubespray groups are missing (this may be intentional)"
    fi
    
    # Display inventory information
    if command_exists ansible-inventory && [[ "$verbose" == true ]]; then
        echo ""
        log_info "Inventory hosts:"
        ansible-inventory -i "$inventory_file" --graph 2>/dev/null || true
        echo ""
        log_info "Inventory variables (all group):"
        ansible-inventory -i "$inventory_file" --host localhost 2>/dev/null | head -20 || true
    fi
    
    # SSH connectivity check
    if [[ "$check_ssh" == true ]]; then
        echo ""
        if ! validate_ssh_connectivity "$inventory_file" 5; then
            log_warn "SSH connectivity check failed"
            log_info "This may be expected if hosts are not currently reachable"
        fi
    fi
    
    # Summary
    echo ""
    print_banner "Validation Summary"
    
    if [[ $failed_checks -eq 0 ]]; then
        log_success "Inventory validation passed!"
        return 0
    else
        log_error "$failed_checks validation check(s) failed"
        return 1
    fi
}

main "$@"
