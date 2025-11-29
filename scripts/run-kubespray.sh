#!/usr/bin/env bash
# VMStation Kubespray Integration Wrapper
# This script stages Kubespray for deployment without making actual cluster changes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.cache"
KUBESPRAY_DIR="$CACHE_DIR/kubespray"
VENV_DIR="$KUBESPRAY_DIR/.venv"
KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-v2.24.1}"

# Logging functions
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_err() { echo "[ERROR] $*" >&2; exit 1; }

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Clone or update Kubespray
if [[ -d "$KUBESPRAY_DIR/.git" ]]; then
    log_info "Updating existing Kubespray repository..."
    cd "$KUBESPRAY_DIR"
    git fetch --tags
    git checkout "$KUBESPRAY_VERSION" 2>/dev/null || {
        log_warn "Version $KUBESPRAY_VERSION not found, using latest main"
        git checkout main
        git pull
    }
else
    log_info "Cloning Kubespray repository..."
    git clone https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
    cd "$KUBESPRAY_DIR"
    git checkout "$KUBESPRAY_VERSION" 2>/dev/null || {
        log_warn "Version $KUBESPRAY_VERSION not found, using latest main"
    }
fi

# Create virtual environment in repo cache if missing
log_info "Setting up Python virtual environment..."
if [[ ! -d "$VENV_DIR" ]]; then
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
fi


# Activate the venv from the repo cache and ensure pip/tools are present
# The activate script does not need the executable bit when it will be sourced;
# just ensure the file exists.
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    log_err "Virtualenv activation script not found at $VENV_DIR/bin/activate"
fi

#. "$VENV_DIR/bin/activate"
# Prefer to run pip directly from the venv to avoid relying on shell state

"$VENV_DIR/bin/pip" install -U pip setuptools wheel
if [ -f "$KUBESPRAY_DIR/requirements.txt" ]; then
    log_info "Installing Kubespray requirements into virtualenv..."
    "$VENV_DIR/bin/pip" install -r "$KUBESPRAY_DIR/requirements.txt"
fi

# Activate venv for subsequent commands in this script
. "$VENV_DIR/bin/activate"

# Note: requirements were installed earlier using the venv's pip. The venv is
# now activated so subsequent commands can rely on the environment.

# Create inventory template directory if not exists
INVENTORY_TEMPLATE_DIR="$KUBESPRAY_DIR/inventory/mycluster"
if [[ ! -d "$INVENTORY_TEMPLATE_DIR" ]]; then
    log_info "Creating inventory template..."
    cp -r "$KUBESPRAY_DIR/inventory/sample" "$INVENTORY_TEMPLATE_DIR"
fi

# Ensure expected files mentioned in next steps exist and use canonical names
# Some Kubespray samples provide 'hosts.ini' under sample; create 'inventory.ini'
# as a convenience and ensure group_vars files exist.
if [[ -f "$INVENTORY_TEMPLATE_DIR/hosts.ini" && ! -f "$INVENTORY_TEMPLATE_DIR/inventory.ini" ]]; then
    log_info "Creating convenient inventory.ini from hosts.ini"
    cp "$INVENTORY_TEMPLATE_DIR/hosts.ini" "$INVENTORY_TEMPLATE_DIR/inventory.ini"
fi

# Ensure group_vars paths exist (copy from sample if missing)
if [[ ! -f "$INVENTORY_TEMPLATE_DIR/group_vars/all/all.yml" ]] && [[ -f "$KUBESPRAY_DIR/inventory/sample/group_vars/all/all.yml" ]]; then
    mkdir -p "$INVENTORY_TEMPLATE_DIR/group_vars/all"
    cp "$KUBESPRAY_DIR/inventory/sample/group_vars/all/all.yml" "$INVENTORY_TEMPLATE_DIR/group_vars/all/all.yml"
fi

if [[ ! -f "$INVENTORY_TEMPLATE_DIR/group_vars/k8s_cluster/k8s-cluster.yml" ]] && [[ -f "$KUBESPRAY_DIR/inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml" ]]; then
    mkdir -p "$INVENTORY_TEMPLATE_DIR/group_vars/k8s_cluster"
    cp "$KUBESPRAY_DIR/inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml" "$INVENTORY_TEMPLATE_DIR/group_vars/k8s_cluster/k8s-cluster.yml"
fi

log_info "✅ Kubespray setup complete!"
echo ""
echo "=========================================="
echo "Next Steps for Kubespray Deployment"
echo "=========================================="
echo ""
echo "1. Edit the inventory file:"
echo "   $INVENTORY_TEMPLATE_DIR/inventory.ini"
echo ""
echo "2. Customize cluster variables:"
echo "   $INVENTORY_TEMPLATE_DIR/group_vars/all/all.yml"
echo "   $INVENTORY_TEMPLATE_DIR/group_vars/k8s_cluster/k8s-cluster.yml"
echo ""
cat <<EOF
3. Run preflight checks on RHEL10 node:
   ansible-playbook -i $INVENTORY_TEMPLATE_DIR/inventory.ini \
    -l compute_nodes \
    -e 'target_hosts=compute_nodes' \
    ansible/playbooks/run-preflight-rhel10.yml
EOF
echo ""
echo "4. Deploy cluster with Kubespray:"
echo "   cd $KUBESPRAY_DIR"
echo "   source $VENV_DIR/bin/activate"
echo "   ansible-playbook -i $INVENTORY_TEMPLATE_DIR/inventory.ini cluster.yml"
echo ""
echo "5. Access your cluster:"
echo "   export KUBECONFIG=\$HOME/.kube/config"
echo "   kubectl get nodes"
echo ""
echo "=========================================="
echo "Kubespray Documentation:"
echo "  https://kubespray.io/"
echo "  $KUBESPRAY_DIR/docs/"
echo "=========================================="