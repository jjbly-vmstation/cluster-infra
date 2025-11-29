#!/usr/bin/env bash
# VMStation Kubespray Environment Activation Script
# Activates the Kubespray virtual environment and sets KUBECONFIG
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBESPRAY_DIR="$REPO_ROOT/.cache/kubespray"
VENV_DIR="$KUBESPRAY_DIR/.venv"

# Logging functions
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_err() { echo "[ERROR] $*" >&2; return 1; }

# Check if Kubespray venv exists
if [[ ! -d "$VENV_DIR" ]]; then
    log_err "Kubespray virtual environment not found at $VENV_DIR"
    log_info "Run 'scripts/run-kubespray.sh' first to stage Kubespray"
    exit 1
fi

# Check if activation script exists
if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    log_err "Virtual environment activation script not found"
    exit 1
fi

# Activate the virtual environment
log_info "Activating Kubespray virtual environment..."
# shellcheck disable=SC1090,SC1091
source "$VENV_DIR/bin/activate"

# Find and export KUBECONFIG
# Kubespray typically generates kubeconfig at inventory/mycluster/artifacts/admin.conf
# or users may have it in ~/.kube/config
KUBECONFIG_PATHS=(
    "$KUBESPRAY_DIR/inventory/mycluster/artifacts/admin.conf"
    "$HOME/.kube/config"
    "/etc/kubernetes/admin.conf"
)

KUBECONFIG_FOUND=""
for kconfig in "${KUBECONFIG_PATHS[@]}"; do
    if [[ -f "$kconfig" ]]; then
        KUBECONFIG_FOUND="$kconfig"
        break
    fi
done

if [[ -n "$KUBECONFIG_FOUND" ]]; then
    export KUBECONFIG="$KUBECONFIG_FOUND"
    log_info "KUBECONFIG set to: $KUBECONFIG"
    
    # Verify kubectl works
    if command -v kubectl &>/dev/null; then
        if kubectl cluster-info &>/dev/null; then
            log_info "✅ Kubernetes cluster is reachable"
        else
            log_warn "kubectl found but cluster is not reachable"
        fi
    else
        log_warn "kubectl not found in PATH"
    fi
else
    log_warn "No kubeconfig file found. Cluster may not be deployed yet."
    log_info "Expected locations:"
    for kconfig in "${KUBECONFIG_PATHS[@]}"; do
        log_info "  - $kconfig"
    done
fi

log_info "Kubespray environment activated"
log_info "Run 'deactivate' to exit the virtual environment"
