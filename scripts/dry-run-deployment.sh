#!/usr/bin/env bash
# VMStation Kubespray Dry Run Deployment Script
# Tests deployment without applying changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library functions
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-common.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Perform a dry-run of Kubespray deployment to test configuration without making changes.

OPTIONS:
    -h, --help              Show this help message
    -e, --environment ENV   Environment to test (production|staging) [default: production]
    -p, --playbook FILE     Kubespray playbook to test [default: cluster.yml]

EXAMPLES:
    $(basename "$0") -e production
    $(basename "$0") -e staging -p scale.yml
EOF
}

main() {
    local environment="production"
    local playbook="cluster.yml"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -e|--environment)
                shift
                environment="$1"
                ;;
            -p|--playbook)
                shift
                playbook="$1"
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
    
    print_banner "Kubespray Dry Run"
    
    # Load configuration
    load_config
    
    local kubespray_dir="${KUBESPRAY_DIR:-$REPO_ROOT/kubespray}"
    local venv_dir="${KUBESPRAY_VENV:-$kubespray_dir/.venv}"
    local inventory_file="/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml"
    
    # Validate setup
    log_info "Validating environment: $environment"
    
    if [[ ! -d "$kubespray_dir" ]]; then
        log_fatal "Kubespray directory not found: $kubespray_dir"
    fi
    
    if [[ ! -f "$inventory_file" ]]; then
        log_fatal "Inventory file not found: $inventory_file"
    fi
    
    if [[ ! -d "$venv_dir" ]]; then
        log_fatal "Virtual environment not found: $venv_dir"
    fi
    
    if [[ ! -f "$kubespray_dir/$playbook" ]]; then
        log_fatal "Playbook not found: $kubespray_dir/$playbook"
    fi
    
    log_success "Environment validated"
    echo ""
    
    # Activate virtual environment
    log_info "Activating virtual environment..."
    # shellcheck disable=SC1091,SC1090
    source "$venv_dir/bin/activate"
    
    # Display configuration
    log_info "Configuration:"
    echo "  Environment:  $environment"
    echo "  Inventory:    $inventory_file"
    echo "  Playbook:     $playbook"
    echo "  Kubespray:    $(get_kubespray_version "$kubespray_dir")"
    echo ""
    
    # Run dry-run
    log_info "Running Ansible dry-run (--check mode)..."
    log_info "This will not make any changes to your infrastructure"
    echo ""
    
    cd "$kubespray_dir"
    
    # Run ansible-playbook in check mode
    if ansible-playbook \
        -i "$inventory_file" \
        "$playbook" \
        --check \
        --diff \
        --become; then
        echo ""
        log_success "Dry run completed successfully!"
        echo ""
        echo "Next steps:"
        echo "  1. Review the changes above"
        echo "  2. If everything looks good, run the actual deployment:"
        echo "     cd $kubespray_dir"
        echo "     ansible-playbook -i $inventory_file $playbook --become"
        return 0
    else
        echo ""
        log_error "Dry run failed"
        echo ""
        echo "Please fix the errors above before attempting actual deployment."
        return 1
    fi
}

main "$@"
