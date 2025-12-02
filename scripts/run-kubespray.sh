#!/usr/bin/env bash
# VMStation Kubespray Integration Wrapper
# This script stages Kubespray for deployment without making actual cluster changes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library functions
# shellcheck disable=SC1091,SC1090
source "$SCRIPT_DIR/lib/kubespray-common.sh"

# Load configuration
load_config

KUBESPRAY_DIR="${KUBESPRAY_DIR:-$REPO_ROOT/kubespray}"
VENV_DIR="${KUBESPRAY_VENV:-$KUBESPRAY_DIR/.venv}"
KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-v2.24.1}"

# Ensure Kubespray submodule is initialized
if [[ ! -e "$KUBESPRAY_DIR/.git" ]]; then
    log_error "Kubespray submodule not found at $KUBESPRAY_DIR"
    log_info "Initialize submodule with: git submodule update --init --recursive"
    exit 1
fi

# Check if submodule is populated
if [[ ! -f "$KUBESPRAY_DIR/cluster.yml" ]]; then
    log_error "Kubespray submodule is not populated"
    log_info "Initialize submodule with: git submodule update --init --recursive"
    exit 1
fi

# Update to specified version
cd "$KUBESPRAY_DIR"
current_version=$(git describe --tags --always 2>/dev/null || echo "unknown")
log_info "Current Kubespray version: $current_version"

if [[ "$current_version" != "$KUBESPRAY_VERSION"* ]]; then
    log_info "Checking out Kubespray version: $KUBESPRAY_VERSION"
    git fetch --tags 2>/dev/null || true
    if git checkout "$KUBESPRAY_VERSION" 2>/dev/null; then
        log_success "Checked out version $KUBESPRAY_VERSION"
    else
        log_warn "Version $KUBESPRAY_VERSION not found, using current version"
    fi
fi

cd "$REPO_ROOT"

# Create virtual environment if missing
log_info "Setting up Python virtual environment..."
if ! create_venv "$VENV_DIR"; then
    log_fatal "Failed to create virtual environment"
fi

# Install requirements
log_info "Installing Kubespray requirements..."
if [[ ! -f "$KUBESPRAY_DIR/requirements.txt" ]]; then
    log_fatal "Requirements file not found: $KUBESPRAY_DIR/requirements.txt"
fi

if ! install_requirements "$KUBESPRAY_DIR/requirements.txt" "$VENV_DIR/bin/pip"; then
    log_fatal "Failed to install requirements"
fi

log_success "Kubespray environment ready"

# Use VMStation production inventory
PRODUCTION_INVENTORY="$REPO_ROOT/inventory/production/hosts.yml"

log_success "✅ Kubespray setup complete!"
echo ""
print_banner "Next Steps"
echo ""
echo "1. Review and customize the production inventory:"
echo "   $PRODUCTION_INVENTORY"
echo "   $REPO_ROOT/inventory/production/group_vars/all.yml"
echo "   $REPO_ROOT/inventory/production/group_vars/k8s_cluster.yml"
echo ""
echo "2. Validate the inventory:"
echo "   ./scripts/test-inventory.sh -e production"
echo ""
echo "3. Run preflight checks (RHEL10 nodes):"
echo "   cd ansible"
echo "   ansible-playbook playbooks/run-preflight-rhel10.yml \\"
echo "     -i ../inventory/production/hosts.yml -l compute_nodes"
echo ""
echo "4. Deploy cluster with Kubespray:"
echo "   source scripts/activate-kubespray-env.sh"
echo "   cd kubespray"
echo "   ansible-playbook -i ../inventory/production/hosts.yml cluster.yml"
echo ""
echo "5. Access your cluster:"
echo "   export KUBECONFIG=\$HOME/.kube/config"
echo "   kubectl get nodes"
echo ""
print_banner "Documentation"
echo ""
echo "  Kubespray Deployment: docs/KUBESPRAY_DEPLOYMENT.md"
echo "  Kubespray Docs: https://kubespray.io/"
echo "  Kubespray GitHub: https://github.com/kubernetes-sigs/kubespray"
echo ""
echo "=========================================="