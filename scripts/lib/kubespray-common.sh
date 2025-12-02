#!/usr/bin/env bash
# VMStation Kubespray Common Functions Library
# Shared functions for Kubespray integration scripts

set -euo pipefail

# Color codes for output (only set if not already set)
if [[ -z "${COLOR_RED:-}" ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_RESET='\033[0m'
fi

# Logging functions with colors
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*" >&2
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*" >&2
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_fatal() {
    log_error "$*"
    exit 1
}

# Get repository root directory
get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$script_dir/.." && pwd
}

# Load configuration from defaults file
load_config() {
    local repo_root
    repo_root="$(get_repo_root)"
    local config_file="$repo_root/config/kubespray-defaults.env"
    
    if [[ -f "$config_file" ]]; then
        # shellcheck disable=SC1090
        source "$config_file"
        log_info "Loaded configuration from $config_file"
    else
        log_warn "Configuration file not found: $config_file"
    fi
    
    # Export commonly used variables
    export REPO_ROOT="${REPO_ROOT:-$repo_root}"
    export KUBESPRAY_DIR="${KUBESPRAY_DIR:-$REPO_ROOT/kubespray}"
    export KUBESPRAY_VENV="${KUBESPRAY_VENV:-$KUBESPRAY_DIR/.venv}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
check_requirements() {
    local required_commands=("$@")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        return 1
    fi
    
    return 0
}

# Check Python version
check_python_version() {
    local min_major="${1:-3}"
    local min_minor="${2:-8}"
    
    if ! command_exists python3; then
        log_error "python3 not found"
        return 1
    fi
    
    local python_version
    python_version=$(python3 --version 2>&1 | awk '{print $2}')
    local major minor
    major=$(echo "$python_version" | cut -d. -f1)
    minor=$(echo "$python_version" | cut -d. -f2)
    
    if [[ $major -lt $min_major ]] || [[ $major -eq $min_major && $minor -lt $min_minor ]]; then
        log_error "Python $min_major.$min_minor+ required, found $python_version"
        return 1
    fi
    
    log_info "Python version: $python_version"
    return 0
}

# Create Python virtual environment
create_venv() {
    local venv_dir="$1"
    
    if [[ -d "$venv_dir" ]]; then
        log_info "Virtual environment already exists at $venv_dir"
        return 0
    fi
    
    log_info "Creating Python virtual environment at $venv_dir..."
    python3 -m venv "$venv_dir"
    
    if [[ ! -f "$venv_dir/bin/activate" ]]; then
        log_error "Failed to create virtual environment"
        return 1
    fi
    
    log_success "Virtual environment created"
    return 0
}

# Activate Python virtual environment
activate_venv() {
    local venv_dir="$1"
    
    if [[ ! -f "$venv_dir/bin/activate" ]]; then
        log_error "Virtual environment not found at $venv_dir"
        return 1
    fi
    
    # shellcheck disable=SC1091,SC1090
    source "$venv_dir/bin/activate"
    log_info "Virtual environment activated"
    return 0
}

# Install Python requirements
install_requirements() {
    local requirements_file="$1"
    local pip_binary="${2:-pip}"
    
    if [[ ! -f "$requirements_file" ]]; then
        log_error "Requirements file not found: $requirements_file"
        return 1
    fi
    
    log_info "Installing Python requirements from $requirements_file..."
    "$pip_binary" install -q -U pip setuptools wheel
    "$pip_binary" install -q -r "$requirements_file"
    
    log_success "Requirements installed"
    return 0
}

# Check if Kubespray directory exists and is a git repository
check_kubespray_dir() {
    local kubespray_dir="$1"
    
    if [[ ! -d "$kubespray_dir" ]]; then
        log_error "Kubespray directory not found: $kubespray_dir"
        return 1
    fi
    
    # Check if it's a git repository (both .git directory or file for submodules)
    if [[ ! -e "$kubespray_dir/.git" ]]; then
        log_error "Kubespray directory is not a git repository: $kubespray_dir"
        return 1
    fi
    
    return 0
}

# Get Kubespray version
get_kubespray_version() {
    local kubespray_dir="$1"
    
    if ! check_kubespray_dir "$kubespray_dir"; then
        echo "unknown"
        return 1
    fi
    
    cd "$kubespray_dir"
    local version
    version=$(git describe --tags --always 2>/dev/null || echo "unknown")
    echo "$version"
}

# Print banner
print_banner() {
    local title="$1"
    local width=50
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo ""
    printf '%*s' "$width" '' | tr ' ' '='
    echo ""
    printf '%*s%s%*s\n' "$padding" '' "$title" "$padding" ''
    printf '%*s' "$width" '' | tr ' ' '='
    echo ""
}

# Export functions for use in other scripts
export -f log_info log_success log_warn log_error log_fatal
export -f get_repo_root load_config
export -f command_exists check_requirements check_python_version
export -f create_venv activate_venv install_requirements
export -f check_kubespray_dir get_kubespray_version
export -f print_banner
