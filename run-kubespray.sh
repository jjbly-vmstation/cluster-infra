#!/usr/bin/env bash
set -euo pipefail

# run-kubespray.sh
# Helper wrapper to ensure Kubespray is available, create a venv, optionally symlink
# the canonical inventory into the local Kubespray `inventory/` directory, run a
# connectivity check, execute Kubespray, and clean up the symlink.
#
# Usage: run-kubespray.sh [--mode symlink|external] [--kubespray-dir PATH] [--inventory-dir PATH] -- [ansible-playbook-args]
# Default mode: symlink

KUBESPRAY_REPO="https://github.com/kubernetes-sigs/kubespray.git"
MODE="symlink"
KUBESPRAY_DIR="/opt/vmstation-org/cluster-infra/kubespray"
CANON_INV_DIR="/opt/vmstation-org/cluster-infra/inventory/mycluster"

print_usage() {
  cat <<EOF
Usage: $0 [--mode symlink|external] [--kubespray-dir PATH] [--inventory-dir PATH] -- [ansible-playbook args]

Examples:
  $0 --mode symlink --ansible-playbook-args "-e kube_network_plugin=calico"
  $0 --mode external --inventory-dir /opt/vmstation-org/cluster-infra/inventory/mycluster -- -e k8s_version=v1.28.0
EOF
}

# parse args up to `--` then pass remaining to ansible-playbook
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"; shift 2;;
    --kubespray-dir)
      KUBESPRAY_DIR="$2"; shift 2;;
    --inventory-dir)
      CANON_INV_DIR="$2"; shift 2;;
    --help|-h)
      print_usage; exit 0;;
    --)
      shift; ARGS+=("$@"); break;;
    *)
      # treat other args as passthrough to ansible-playbook
      ARGS+=("$1"); shift;;
  esac
done

echo "Mode: $MODE"
echo "Kubespray dir: $KUBESPRAY_DIR"
echo "Canonical inventory dir: $CANON_INV_DIR"

# Clone Kubespray if missing
if [ ! -d "$KUBESPRAY_DIR/.git" ]; then
  echo "Cloning Kubespray into $KUBESPRAY_DIR"
  mkdir -p "$(dirname "$KUBESPRAY_DIR")"
  git clone "$KUBESPRAY_REPO" "$KUBESPRAY_DIR"
else
  echo "Kubespray already present at $KUBESPRAY_DIR"
fi

# Create and activate venv
VENV_DIR="$KUBESPRAY_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating Python venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
if [ -f "$KUBESPRAY_DIR/requirements.txt" ]; then
  pip install -r "$KUBESPRAY_DIR/requirements.txt"
fi

ANSIBLE_BIN="$VENV_DIR/bin/ansible"
ANSIBLE_PLAYBOOK_BIN="$VENV_DIR/bin/ansible-playbook"

SYMLINK_CREATED=0
if [ "$MODE" = "symlink" ]; then
  # Create inventory symlink inside kubespray repo
  mkdir -p "$KUBESPRAY_DIR/inventory"
  if [ -L "$KUBESPRAY_DIR/inventory/mycluster" ]; then
    echo "Existing symlink found at $KUBESPRAY_DIR/inventory/mycluster, removing"
    rm -f "$KUBESPRAY_DIR/inventory/mycluster"
  fi
  ln -s "$CANON_INV_DIR" "$KUBESPRAY_DIR/inventory/mycluster"
  SYMLINK_CREATED=1
  INVENTORY_PATH="$KUBESPRAY_DIR/inventory/mycluster/hosts.yaml"
else
  INVENTORY_PATH="$CANON_INV_DIR/hosts.yaml"
fi

if [ ! -f "$INVENTORY_PATH" ]; then
  echo "ERROR: inventory file not found: $INVENTORY_PATH" >&2
  if [ $SYMLINK_CREATED -eq 1 ]; then
    rm -f "$KUBESPRAY_DIR/inventory/mycluster"
  fi
  exit 2
fi

echo "Inventory path for run: $INVENTORY_PATH"

# Quick connectivity check using ansible ping
echo "Running Ansible connectivity check (this may take a moment)"
set +e
$ANSIBLE_BIN -i "$INVENTORY_PATH" all -m ping -o
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "WARNING: Ansible ping returned non-zero ($RC). Fix SSH/auth before proceeding." >&2
  if [ $SYMLINK_CREATED -eq 1 ]; then
    rm -f "$KUBESPRAY_DIR/inventory/mycluster"
  fi
  exit $RC
fi

# Run Kubespray
pushd "$KUBESPRAY_DIR" >/dev/null
echo "Running Kubespray playbook against inventory: $INVENTORY_PATH"
"$ANSIBLE_PLAYBOOK_BIN" -i "$INVENTORY_PATH" cluster.yml -b --become-user=root "${ARGS[@]}"
RET=$?
popd >/dev/null

# Clean up symlink if we created it
if [ $SYMLINK_CREATED -eq 1 ]; then
  echo "Removing transient symlink at $KUBESPRAY_DIR/inventory/mycluster"
  rm -f "$KUBESPRAY_DIR/inventory/mycluster"
fi

exit $RET
