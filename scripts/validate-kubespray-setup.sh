#!/usr/bin/env bash
# VMStation Kubespray Setup Validation Script
# Verifies that Kubespray environment is correctly configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library functions
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-common.sh"
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-validation.sh"

main() {
    print_banner "Kubespray Setup Validation"
    
    # Load configuration
    load_config
    
    local kubespray_dir="${KUBESPRAY_DIR:-$REPO_ROOT/kubespray}"
    local venv_dir="${KUBESPRAY_VENV:-$kubespray_dir/.venv}"
    
    local failed_checks=0
    
    # Check 1: Kubespray submodule
    log_info "Checking Kubespray submodule..."
    if [[ -e "$kubespray_dir/.git" ]]; then
        local version
        version=$(get_kubespray_version "$kubespray_dir")
        log_success "Kubespray submodule exists (version: $version)"
    else
        log_error "Kubespray submodule not found at $kubespray_dir"
        log_info "Run: git submodule update --init --recursive"
        ((failed_checks++))
    fi
    
    # Check 2: Python virtual environment
    log_info "Checking Python virtual environment..."
    if [[ -d "$venv_dir" ]] && [[ -f "$venv_dir/bin/activate" ]]; then
        log_success "Python virtual environment exists at $venv_dir"
    else
        log_error "Python virtual environment not found at $venv_dir"
        log_info "Run: ./scripts/run-kubespray.sh"
        ((failed_checks++))
    fi
    
    # Check 3: Kubespray dependencies installed
    if [[ -f "$venv_dir/bin/ansible-playbook" ]]; then
        log_success "Ansible installed in virtual environment"
    else
        log_warn "Ansible not found in virtual environment"
        ((failed_checks++))
    fi
    
    # Check 4: Configuration file
    log_info "Checking configuration file..."
    if [[ -f "$REPO_ROOT/config/kubespray-defaults.env" ]]; then
        log_success "Configuration file exists"
    else
        log_error "Configuration file not found"
        ((failed_checks++))
    fi
    
    # Check 5: Inventory structure
    log_info "Checking inventory structure..."
    if [[ -d "$REPO_ROOT/inventory/production" ]]; then
        log_success "Production inventory directory exists"
    else
        log_error "Production inventory directory not found"
        ((failed_checks++))
    fi
    
    if [[ -f "$REPO_ROOT/inventory/production/hosts.yml" ]]; then
        log_success "Production inventory file exists"
    else
        log_error "Production inventory file not found"
        ((failed_checks++))
    fi
    
    # Check 6: Script library
    log_info "Checking script library..."
    # DEBUG: echo "SCRIPT_DIR=$SCRIPT_DIR, checking $SCRIPT_DIR/lib/kubespray-common.sh" >&2
    if [[ -f "$SCRIPT_DIR/lib/kubespray-common.sh" ]]; then
        log_success "Common library exists"
    else
        log_error "Common library not found"
        log_error "Path checked: $SCRIPT_DIR/lib/kubespray-common.sh"
        ((failed_checks++))
    fi
    
    if [[ -f "$SCRIPT_DIR/lib/kubespray-validation.sh" ]]; then
        log_success "Validation library exists"
    else
        log_error "Validation library not found"
        ((failed_checks++))
    fi
    
    # Summary
    echo ""
    print_banner "Validation Summary"
    if [[ $failed_checks -eq 0 ]]; then
        log_success "All checks passed! Kubespray setup is ready."
        echo ""
        echo "Next steps:"
        echo "  1. Review and customize: inventory/production/hosts.yml"
        echo "  2. Activate environment: source scripts/activate-kubespray-env.sh"
        echo "  3. Deploy cluster: cd kubespray && ansible-playbook -i ../inventory/production/hosts.yml cluster.yml"
        return 0
    else
        log_error "$failed_checks check(s) failed"
        echo ""
        echo "Please fix the issues above before proceeding."
        return 1
    fi
}

main "$@"
