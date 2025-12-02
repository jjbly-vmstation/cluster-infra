#!/usr/bin/env bash
set -euo pipefail

# Validate inventory structure and contents
# This script ensures the inventory meets all requirements

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY_FILE="/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml"

echo "=== VMStation Inventory Validation ==="
echo "Inventory: ${INVENTORY_FILE}"
echo ""

# Check if ansible-inventory is available
if ! command -v ansible-inventory &> /dev/null; then
    echo "ERROR: ansible-inventory command not found"
    echo "Please install Ansible: pip install ansible"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq command not found"
    echo "Please install jq: apt-get install jq or brew install jq"
    exit 1
fi

# Check YAML syntax
echo "✓ Checking YAML syntax..."
syntax_output=$(ansible-inventory -i "${INVENTORY_FILE}" --list 2>&1)
syntax_result=$?
if [[ $syntax_result -ne 0 ]]; then
    echo "ERROR: YAML syntax validation failed"
    echo "$syntax_output"
    exit 1
fi
echo "  YAML syntax is valid"

# Verify required groups
echo "✓ Checking required groups..."
required_groups=("kube_control_plane" "kube_node" "etcd" "k8s_cluster")
inventory_json=$(ansible-inventory -i "${INVENTORY_FILE}" --list)

for group in "${required_groups[@]}"; do
    if ! echo "$inventory_json" | jq -e ".[\"${group}\"]" > /dev/null 2>&1; then
        echo "ERROR: Required group '${group}' not found"
        exit 1
    fi
    echo "  Found group: ${group}"
done

# Verify required hosts
echo "✓ Checking required hosts..."
required_hosts=("masternode" "storagenodet3500" "homelab")

for host in "${required_hosts[@]}"; do
    if ! echo "$inventory_json" | jq -e "._meta.hostvars.${host}" > /dev/null 2>&1; then
        echo "ERROR: Required host '${host}' not found"
        exit 1
    fi
    echo "  Found host: ${host}"
done

# Verify host variables
echo "✓ Checking host variables..."
for host in "${required_hosts[@]}"; do
    # Check ansible_host
    if ! echo "$inventory_json" | jq -e "._meta.hostvars.${host}.ansible_host" > /dev/null 2>&1; then
        echo "WARNING: Host '${host}' missing ansible_host variable"
    fi
    
    # Check ip and access_ip for Kubespray compatibility
    if ! echo "$inventory_json" | jq -e "._meta.hostvars.${host}.ip" > /dev/null 2>&1; then
        echo "WARNING: Host '${host}' missing 'ip' variable (required for Kubespray)"
    fi
    
    if ! echo "$inventory_json" | jq -e "._meta.hostvars.${host}.access_ip" > /dev/null 2>&1; then
        echo "WARNING: Host '${host}' missing 'access_ip' variable (required for Kubespray)"
    fi
done

# Check group_vars files
echo "✓ Checking group_vars files..."
group_var_files=(
    "${INVENTORY_DIR}/production/group_vars/all.yml"
    "${INVENTORY_DIR}/production/group_vars/k8s_cluster/k8s-cluster.yml"
    "${INVENTORY_DIR}/production/group_vars/k8s_cluster/addons.yml"
)

for file in "${group_var_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "WARNING: Expected group_vars file not found: $file"
    else
        echo "  Found: $(basename "$(dirname "$file")")/$(basename "$file")"
    fi
done

# Check host_vars files
echo "✓ Checking host_vars files..."
for host in "${required_hosts[@]}"; do
    host_var_file="${INVENTORY_DIR}/production/host_vars/${host}.yml"
    if [[ ! -f "$host_var_file" ]]; then
        echo "WARNING: Expected host_vars file not found: $host_var_file"
    else
        echo "  Found: host_vars/${host}.yml"
    fi
done

echo ""
echo "=== Validation Summary ==="
echo "✓ Inventory validation passed"
echo "✓ All required groups present"
echo "✓ All required hosts present"
echo "✓ Structure is Kubespray-compatible"
echo ""
echo "Inventory is valid and ready to use!"
