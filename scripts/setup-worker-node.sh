#!/usr/bin/env bash
#
# setup-worker-node.sh
#
# Purpose: Prepare worker node (homelab) for identity stack scheduling
# This script labels the node, creates storage directories, and validates readiness
#
# Usage:
#   sudo ./scripts/setup-worker-node.sh <worker-node-hostname>
#   sudo ./scripts/setup-worker-node.sh homelab
#

set -euo pipefail

# Configuration
WORKER_NODE="${1:-homelab}"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}Worker Node Setup: $WORKER_NODE${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# Check if node exists
if ! kubectl --kubeconfig="$KUBECONFIG" get node "$WORKER_NODE" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Node '$WORKER_NODE' not found in cluster"
    echo ""
    echo "Available nodes:"
    kubectl --kubeconfig="$KUBECONFIG" get nodes
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Node '$WORKER_NODE' found"
echo ""

# Label node as worker
echo -e "${BLUE}[STEP 1/4]${NC} Labeling node as worker..."
if kubectl --kubeconfig="$KUBECONFIG" label nodes "$WORKER_NODE" node-role.kubernetes.io/worker= --overwrite; then
    echo -e "${GREEN}  ✓ Node labeled successfully${NC}"
else
    echo -e "${RED}  ✗ Failed to label node${NC}"
    exit 1
fi
echo ""

# Verify label
echo -e "${BLUE}[STEP 2/4]${NC} Verifying node labels..."
LABELS=$(kubectl --kubeconfig="$KUBECONFIG" get node "$WORKER_NODE" --show-labels)
if echo "$LABELS" | grep -q "node-role.kubernetes.io/worker="; then
    echo -e "${GREEN}  ✓ Worker label verified${NC}"
else
    echo -e "${RED}  ✗ Worker label not found${NC}"
    exit 1
fi
echo ""

# Check node resources
echo -e "${BLUE}[STEP 3/4]${NC} Checking node resources..."
NODE_INFO=$(kubectl --kubeconfig="$KUBECONFIG" describe node "$WORKER_NODE")

ALLOCATABLE_MEMORY=$(echo "$NODE_INFO" | grep -A 5 "Allocatable:" | grep "memory:" | awk '{print $2}')
ALLOCATABLE_CPU=$(echo "$NODE_INFO" | grep -A 5 "Allocatable:" | grep "cpu:" | awk '{print $2}')

echo -e "  Allocatable Memory: ${CYAN}$ALLOCATABLE_MEMORY${NC}"
echo -e "  Allocatable CPU: ${CYAN}$ALLOCATABLE_CPU${NC}"

# Check if sufficient for identity stack (needs ~10-12Gi)
MEMORY_GB=$(echo "$ALLOCATABLE_MEMORY" | sed 's/Gi//' | sed 's/G//' | sed 's/Mi/.000001/' | sed 's/M/.000001/' | bc 2>/dev/null || echo "0")
if (( $(echo "$MEMORY_GB < 10" | bc -l 2>/dev/null || echo "0") )); then
    echo -e "${YELLOW}  ⚠ WARNING: Less than 10Gi allocatable memory${NC}"
    echo -e "    Identity stack may not fit. Recommended: 12Gi+"
else
    echo -e "${GREEN}  ✓ Sufficient memory for identity stack${NC}"
fi
echo ""

# Create storage directories on worker node
echo -e "${BLUE}[STEP 4/4]${NC} Creating storage directories on $WORKER_NODE..."
if command -v ssh >/dev/null 2>&1 && ssh -o ConnectTimeout=5 -o BatchMode=yes "$WORKER_NODE" "echo 2>&1" >/dev/null 2>&1; then
    echo -e "  Using SSH to create directories..."
    
    if ssh "$WORKER_NODE" "sudo mkdir -p /srv/monitoring-data/freeipa /srv/monitoring-data/postgresql && sudo chmod 755 /srv/monitoring-data && sudo chown -R root:root /srv/monitoring-data && ls -lah /srv/monitoring-data"; then
        echo -e "${GREEN}  ✓ Storage directories created via SSH${NC}"
    else
        echo -e "${RED}  ✗ Failed to create directories via SSH${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}  ⚠ SSH not available or not configured${NC}"
    echo -e "  Please run manually on $WORKER_NODE:"
    echo -e "    ${CYAN}sudo mkdir -p /srv/monitoring-data/freeipa /srv/monitoring-data/postgresql${NC}"
    echo -e "    ${CYAN}sudo chmod 755 /srv/monitoring-data${NC}"
    echo ""
    echo -e "  Continuing without storage validation..."
fi
echo ""

# Display scheduling readiness
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}Worker Node Setup Complete!${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${BLUE}Node:${NC} $WORKER_NODE"
echo -e "${BLUE}Status:${NC} Ready for identity stack scheduling"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Verify storage directories exist on worker node:"
echo "   ${CYAN}ssh $WORKER_NODE 'ls -lah /srv/monitoring-data'${NC}"
echo ""
echo "2. Deploy identity stack (will schedule on $WORKER_NODE):"
echo "   ${CYAN}cd /opt/vmstation-org/cluster-infra/ansible${NC}"
echo "   ${CYAN}sudo ../scripts/identity-full-deploy.sh --force-reset --reset-confirm${NC}"
echo ""
echo "3. Verify pods scheduled on worker node:"
echo "   ${CYAN}kubectl -n identity get pods -o wide${NC}"
echo ""
echo -e "${YELLOW}Expected scheduling:${NC}"
echo "  - freeipa-0: $WORKER_NODE"
echo "  - keycloak-0: $WORKER_NODE"
echo "  - keycloak-postgresql-0: $WORKER_NODE"
echo ""
echo -e "${YELLOW}Power Management Tip:${NC}"
echo "  To save costs, power on $WORKER_NODE only when using identity/monitoring"
echo "  Keep masternode running 24/7 for control-plane duties"
echo ""
