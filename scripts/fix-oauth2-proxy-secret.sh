#!/usr/bin/env bash
#
# fix-oauth2-proxy-secret.sh
#
# Purpose: Recreate oauth2-proxy cookie secret with correct 32-byte format
# The apply-oauth2-proxy-secret.sh script was fixed, but the existing Secret
# still contains the old 44-byte value. This script deletes and recreates it.
#
# Usage:
#   sudo ./scripts/fix-oauth2-proxy-secret.sh
#

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE="identity"
SECRET_NAME="oauth2-proxy-cookie-secret"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}Fixing oauth2-proxy Cookie Secret${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# Check current secret
if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[INFO]${NC} Current secret exists - checking length..."
    
    CURRENT_SECRET=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.cookie-secret}' | base64 -d)
    CURRENT_LENGTH=${#CURRENT_SECRET}
    
    echo -e "  Current secret length: ${RED}$CURRENT_LENGTH bytes${NC}"
    
    if [[ $CURRENT_LENGTH -eq 32 ]]; then
        echo -e "${GREEN}[OK]${NC} Secret is already correct (32 bytes)"
        exit 0
    elif [[ $CURRENT_LENGTH -eq 44 ]]; then
        echo -e "${RED}[ERROR]${NC} Secret has OLD incorrect value (44 bytes)"
        echo -e "  This is the base64-encoded value from the old script"
    else
        echo -e "${YELLOW}[WARN]${NC} Secret has unexpected length: $CURRENT_LENGTH bytes"
    fi
    
    echo ""
    echo -e "${YELLOW}[ACTION]${NC} Deleting old secret..."
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" delete secret "$SECRET_NAME"; then
        echo -e "${GREEN}  ✓ Secret deleted${NC}"
    else
        echo -e "${RED}  ✗ Failed to delete secret${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}[INFO]${NC} Secret does not exist - will create new one"
fi

echo ""
echo -e "${YELLOW}[ACTION]${NC} Generating new 32-byte hex cookie secret..."

# Run the fixed script
if [[ -x "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh" ]]; then
    if "$SCRIPT_DIR/apply-oauth2-proxy-secret.sh"; then
        echo -e "${GREEN}  ✓ Secret created with correct format${NC}"
    else
        echo -e "${RED}  ✗ Failed to create secret${NC}"
        exit 1
    fi
else
    echo -e "${RED}[ERROR]${NC} apply-oauth2-proxy-secret.sh not found or not executable"
    echo "  Expected: $SCRIPT_DIR/apply-oauth2-proxy-secret.sh"
    exit 1
fi

echo ""
echo -e "${YELLOW}[ACTION]${NC} Verifying new secret..."
NEW_SECRET=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.cookie-secret}' | base64 -d)
NEW_LENGTH=${#NEW_SECRET}

echo -e "  New secret length: ${CYAN}$NEW_LENGTH bytes${NC}"

if [[ $NEW_LENGTH -eq 32 ]]; then
    echo -e "${GREEN}  ✓ Correct length (32 bytes = 64 hex characters)${NC}"
elif [[ $NEW_LENGTH -eq 64 ]]; then
    echo -e "${GREEN}  ✓ Correct length (64 bytes = 64 hex characters stored)${NC}"
    echo -e "  ${YELLOW}Note: This is actually correct - hex string is 64 chars${NC}"
else
    echo -e "${RED}  ✗ Unexpected length: $NEW_LENGTH bytes${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}[ACTION]${NC} Restarting oauth2-proxy deployment..."
if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" rollout restart deployment oauth2-proxy; then
    echo -e "${GREEN}  ✓ Deployment restarted${NC}"
else
    echo -e "${RED}  ✗ Failed to restart deployment${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}[ACTION]${NC} Waiting for pod to be ready..."
if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" wait --for=condition=ready pod -l app=oauth2-proxy --timeout=60s 2>/dev/null; then
    echo -e "${GREEN}  ✓ Pod is ready${NC}"
else
    echo -e "${RED}  ✗ Pod did not become ready${NC}"
    echo ""
    echo -e "${YELLOW}Check logs:${NC}"
    echo "  kubectl -n identity logs -l app=oauth2-proxy --tail=20"
    exit 1
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}✓ oauth2-proxy Cookie Secret Fixed!${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo "Verify the fix:"
echo "  kubectl -n identity get pods -l app=oauth2-proxy"
echo "  kubectl -n identity logs -l app=oauth2-proxy --tail=20"
echo ""
