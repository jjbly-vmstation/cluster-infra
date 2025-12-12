#!/usr/bin/env bash
#
# cleanup-identity-stack.sh
# 
# Purpose: Clean up identity stack PV/PVCs and pods for testing idempotency
# This script removes all identity-related resources to allow a fresh deployment
#
# Usage: sudo ./scripts/cleanup-identity-stack.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE_IDENTITY="${NAMESPACE_IDENTITY:-identity}"
STORAGE_PATH="${STORAGE_PATH:-/srv/monitoring-data}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root (use sudo)${NC}" 
   exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found${NC}"
    exit 1
fi

# Check if kubeconfig exists
if [[ ! -f "$KUBECONFIG" ]]; then
    echo -e "${RED}Error: Kubeconfig not found at $KUBECONFIG${NC}"
    exit 1
fi

echo -e "${YELLOW}================================================${NC}"
echo -e "${YELLOW}Identity Stack Cleanup Script${NC}"
echo -e "${YELLOW}================================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: This will delete all identity stack resources!${NC}"
echo -e "  - All pods in namespace: ${NAMESPACE_IDENTITY}"
echo -e "  - All PVCs in namespace: ${NAMESPACE_IDENTITY}"
echo -e "  - All PVs related to identity services"
echo -e "  - Data in: ${STORAGE_PATH}/postgresql"
echo -e "  - Data in: ${STORAGE_PATH}/freeipa"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${GREEN}Cleanup cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting cleanup...${NC}"
echo ""

# Step 1: Scale down StatefulSets
echo -e "${GREEN}[1/9] Scaling down StatefulSets...${NC}"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" scale statefulset --all --replicas=0 2>/dev/null || echo "  No StatefulSets found or already scaled down"

# Step 2: Scale down Deployments
echo -e "${GREEN}[2/9] Scaling down Deployments...${NC}"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" scale deployment --all --replicas=0 2>/dev/null || echo "  No Deployments found or already scaled down"

# Step 3: Delete all pods in identity namespace (force if needed)
echo -e "${GREEN}[3/9] Deleting all pods in namespace ${NAMESPACE_IDENTITY}...${NC}"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" delete pods --all --force --grace-period=0 2>/dev/null || echo "  No pods found"

# Wait for pods to be fully removed
echo -e "${GREEN}[4/9] Waiting for pods to be fully removed...${NC}"
for i in {1..30}; do
    POD_COUNT=$(KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" get pods --no-headers 2>/dev/null | wc -l)
    if [[ $POD_COUNT -eq 0 ]]; then
        echo "  All pods removed"
        break
    fi
    echo "  Waiting... ($i/30) - $POD_COUNT pods remaining"
    sleep 2
done

# Step 4: Delete all PVCs in identity namespace
echo -e "${GREEN}[5/9] Deleting all PVCs in namespace ${NAMESPACE_IDENTITY}...${NC}"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" delete pvc --all 2>/dev/null || echo "  No PVCs found"

# Step 5: Delete PVs related to identity services
echo -e "${GREEN}[6/9] Deleting PVs for identity services...${NC}"
# Delete keycloak-postgresql PV
KUBECONFIG="$KUBECONFIG" kubectl delete pv keycloak-postgresql-pv 2>/dev/null || echo "  PV keycloak-postgresql-pv not found"
# Delete freeipa PV
KUBECONFIG="$KUBECONFIG" kubectl delete pv freeipa-data-pv 2>/dev/null || echo "  PV freeipa-data-pv not found"

# Step 6: Delete StatefulSets and Deployments
echo -e "${GREEN}[7/9] Deleting StatefulSets and Deployments...${NC}"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" delete statefulset --all 2>/dev/null || echo "  No StatefulSets found"
KUBECONFIG="$KUBECONFIG" kubectl -n "$NAMESPACE_IDENTITY" delete deployment --all 2>/dev/null || echo "  No Deployments found"

# Step 7: Clean up storage directories (optional - commented out for safety)
echo -e "${GREEN}[8/9] Cleaning up storage directories...${NC}"
BACKUP_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -d "${STORAGE_PATH}/postgresql" ]]; then
    echo "  Backing up postgresql data to ${STORAGE_PATH}/postgresql.backup.${BACKUP_TIMESTAMP}"
    mv "${STORAGE_PATH}/postgresql" "${STORAGE_PATH}/postgresql.backup.${BACKUP_TIMESTAMP}" || echo "  Warning: Could not backup postgresql directory"
fi

if [[ -d "${STORAGE_PATH}/freeipa" ]]; then
    echo "  Backing up freeipa data to ${STORAGE_PATH}/freeipa.backup.${BACKUP_TIMESTAMP}"
    mv "${STORAGE_PATH}/freeipa" "${STORAGE_PATH}/freeipa.backup.${BACKUP_TIMESTAMP}" || echo "  Warning: Could not backup freeipa directory"
fi

# Step 8: Recreate empty directories
echo -e "${GREEN}[9/9] Recreating empty storage directories...${NC}"
mkdir -p "${STORAGE_PATH}/postgresql"
mkdir -p "${STORAGE_PATH}/freeipa"
chown 999:999 "${STORAGE_PATH}/postgresql"
chown root:root "${STORAGE_PATH}/freeipa"
chmod 0755 "${STORAGE_PATH}/postgresql"
chmod 0755 "${STORAGE_PATH}/freeipa"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Cleanup Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${GREEN}Summary:${NC}"
echo -e "  - All identity pods have been deleted"
echo -e "  - All PVCs have been removed"
echo -e "  - All PVs have been removed"
echo -e "  - Storage directories have been backed up and recreated"
echo ""
echo -e "${GREEN}You can now run the playbook again:${NC}"
echo -e "  sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \\"
echo -e "    ansible/playbooks/identity-deploy-and-handover.yml --become"
echo ""
echo -e "${YELLOW}Note: Old data has been backed up to:${NC}"
echo -e "  - ${STORAGE_PATH}/postgresql.backup.* (if existed)"
echo -e "  - ${STORAGE_PATH}/freeipa.backup.* (if existed)"
echo ""
