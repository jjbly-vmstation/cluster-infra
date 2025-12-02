#!/usr/bin/env bash
# VMStation Kubespray Validation Functions Library
# Pre-flight validation and checks for Kubespray deployment

set -euo pipefail

# Source common functions
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091,SC1090
source "$_LIB_DIR/kubespray-common.sh"

# Validate inventory file exists and is readable
validate_inventory_file() {
    local inventory_file="$1"
    
    if [[ ! -f "$inventory_file" ]]; then
        log_error "Inventory file not found: $inventory_file"
        return 1
    fi
    
    if [[ ! -r "$inventory_file" ]]; then
        log_error "Inventory file not readable: $inventory_file"
        return 1
    fi
    
    log_success "Inventory file found: $inventory_file"
    return 0
}

# Validate YAML syntax
validate_yaml_syntax() {
    local yaml_file="$1"
    
    if ! command_exists python3; then
        log_warn "Python3 not available, skipping YAML validation"
        return 0
    fi
    
    if python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
        log_success "YAML syntax valid: $yaml_file"
        return 0
    else
        log_error "YAML syntax invalid: $yaml_file"
        return 1
    fi
}

# Validate Ansible inventory using ansible-inventory command
validate_ansible_inventory() {
    local inventory_file="$1"
    
    if ! command_exists ansible-inventory; then
        log_warn "ansible-inventory not available, skipping inventory validation"
        return 0
    fi
    
    log_info "Validating Ansible inventory structure..."
    if ansible-inventory -i "$inventory_file" --list > /dev/null 2>&1; then
        log_success "Ansible inventory structure is valid"
        return 0
    else
        log_error "Ansible inventory structure is invalid"
        return 1
    fi
}

# Check if required host groups exist in inventory
validate_inventory_groups() {
    local inventory_file="$1"
    shift
    local required_groups=("$@")
    
    if ! command_exists ansible-inventory; then
        log_warn "ansible-inventory not available, skipping group validation"
        return 0
    fi
    
    local missing_groups=()
    
    for group in "${required_groups[@]}"; do
        if ! ansible-inventory -i "$inventory_file" --list 2>/dev/null | grep -q "\"$group\""; then
            missing_groups+=("$group")
        fi
    done
    
    if [[ ${#missing_groups[@]} -gt 0 ]]; then
        log_error "Missing required inventory groups: ${missing_groups[*]}"
        return 1
    fi
    
    log_success "All required inventory groups found"
    return 0
}

# Validate SSH connectivity to hosts
validate_ssh_connectivity() {
    local inventory_file="$1"
    local timeout="${2:-5}"
    
    if ! command_exists ansible; then
        log_warn "Ansible not available, skipping SSH connectivity check"
        return 0
    fi
    
    log_info "Checking SSH connectivity to hosts..."
    if ansible all -i "$inventory_file" -m ping --timeout="$timeout" > /dev/null 2>&1; then
        log_success "SSH connectivity to all hosts verified"
        return 0
    else
        log_warn "Some hosts are not reachable via SSH"
        return 1
    fi
}

# Validate Kubespray requirements
validate_kubespray_requirements() {
    local kubespray_dir="$1"
    
    # Check for essential Kubespray files
    local essential_files=(
        "cluster.yml"
        "requirements.txt"
        "inventory/sample/hosts.ini"
        "roles/kubespray-defaults/defaults/main.yaml"
    )
    
    local missing_files=()
    
    for file in "${essential_files[@]}"; do
        if [[ ! -f "$kubespray_dir/$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Missing essential Kubespray files: ${missing_files[*]}"
        return 1
    fi
    
    log_success "All essential Kubespray files present"
    return 0
}

# Validate system requirements (CPU, memory, disk)
validate_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check available memory (at least 2GB recommended)
    local mem_mb
    if command_exists free; then
        mem_mb=$(free -m | awk '/^Mem:/{print $7}')
        if [[ $mem_mb -lt 2048 ]]; then
            log_warn "Low available memory: ${mem_mb}MB (2048MB recommended)"
        else
            log_success "Available memory: ${mem_mb}MB"
        fi
    fi
    
    # Check available disk space (at least 10GB recommended)
    local disk_gb
    if command_exists df; then
        disk_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
        if [[ $disk_gb -lt 10 ]]; then
            log_warn "Low available disk space: ${disk_gb}GB (10GB recommended)"
        else
            log_success "Available disk space: ${disk_gb}GB"
        fi
    fi
    
    # Check CPU cores (at least 2 recommended)
    local cpu_cores
    if command_exists nproc; then
        cpu_cores=$(nproc)
        if [[ $cpu_cores -lt 2 ]]; then
            log_warn "Low CPU cores: ${cpu_cores} (2+ recommended)"
        else
            log_success "CPU cores: ${cpu_cores}"
        fi
    fi
    
    return 0
}

# Run all validation checks
run_all_validations() {
    local inventory_file="$1"
    local kubespray_dir="$2"
    
    local failed_checks=0
    
    print_banner "Kubespray Validation"
    
    # Check requirements
    log_info "Checking requirements..."
    if ! check_requirements python3 git; then
        ((failed_checks++))
    fi
    
    # Validate Python version
    if ! check_python_version 3 8; then
        ((failed_checks++))
    fi
    
    # Validate inventory
    if ! validate_inventory_file "$inventory_file"; then
        ((failed_checks++))
    fi
    
    # Validate YAML if file is YAML
    if [[ "$inventory_file" =~ \.ya?ml$ ]]; then
        if ! validate_yaml_syntax "$inventory_file"; then
            ((failed_checks++))
        fi
    fi
    
    # Validate Kubespray directory
    if ! check_kubespray_dir "$kubespray_dir"; then
        ((failed_checks++))
    fi
    
    # Validate Kubespray requirements
    if ! validate_kubespray_requirements "$kubespray_dir"; then
        ((failed_checks++))
    fi
    
    # Validate system requirements
    validate_system_requirements  # Non-critical, doesn't increment failed_checks
    
    echo ""
    if [[ $failed_checks -eq 0 ]]; then
        log_success "All validation checks passed"
        return 0
    else
        log_error "$failed_checks validation check(s) failed"
        return 1
    fi
}

# Export functions
export -f validate_inventory_file validate_yaml_syntax validate_ansible_inventory
export -f validate_inventory_groups validate_ssh_connectivity
export -f validate_kubespray_requirements validate_system_requirements
export -f run_all_validations
