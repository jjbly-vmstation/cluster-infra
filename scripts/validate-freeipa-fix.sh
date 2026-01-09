#!/usr/bin/env bash
#
# validate-freeipa-fix.sh
#
# Purpose: Validate that FreeIPA pod stability fixes are working
# This script checks the FreeIPA manifest, pod status, and probe configuration
# to ensure all fixes have been applied correctly.
#
# Usage:
#   sudo ./scripts/validate-freeipa-fix.sh
#

set -euo pipefail

# Configuration
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE="identity"
POD_NAME="freeipa-0"
MANIFEST="/opt/vmstation-org/cluster-infra/manifests/identity/freeipa.yaml"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}FreeIPA Fix Validation${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

VALIDATION_FAILED=0

# Function to validate a condition
validate() {
    local check_name="$1"
    local command="$2"
    local expected="$3"
    
    echo -e "${YELLOW}[CHECK]${NC} $check_name..."
    
    if eval "$command" | grep -q "$expected"; then
        echo -e "${GREEN}  ✓ PASS${NC}"
        return 0
    else
        echo -e "${RED}  ✗ FAIL${NC}"
        VALIDATION_FAILED=1
        return 1
    fi
}

# 1. Check manifest has resource limits
echo -e "${BLUE}[SECTION]${NC} Manifest Configuration"
validate "Resource limits defined" \
    "grep -A 5 'resources:' $MANIFEST" \
    "memory:"

validate "Memory request is 2Gi" \
    "grep -A 10 'resources:' $MANIFEST" \
    "2Gi"

validate "Memory limit is 4Gi" \
    "grep -A 10 'resources:' $MANIFEST" \
    "4Gi"

# 2. Check liveness probe configuration
echo ""
echo -e "${BLUE}[SECTION]${NC} Liveness Probe Configuration"
validate "Liveness probe uses bash script" \
    "grep -A 20 'livenessProbe:' $MANIFEST" \
    "/bin/bash"

validate "Liveness probe has 1800s initial delay" \
    "grep -A 20 'livenessProbe:' $MANIFEST" \
    "initialDelaySeconds: 1800"

validate "Liveness probe has 60s period" \
    "grep -A 20 'livenessProbe:' $MANIFEST" \
    "periodSeconds: 60"

# 3. Check readiness probe configuration
echo ""
echo -e "${BLUE}[SECTION]${NC} Readiness Probe Configuration"
validate "Readiness probe uses bash script" \
    "grep -A 20 'readinessProbe:' $MANIFEST" \
    "/bin/bash"

validate "Readiness probe has 180s initial delay" \
    "grep -A 20 'readinessProbe:' $MANIFEST" \
    "initialDelaySeconds: 180"

validate "Readiness probe has 90 failure threshold" \
    "grep -A 20 'readinessProbe:' $MANIFEST" \
    "failureThreshold: 90"

# 4. Check if diagnostic script exists
echo ""
echo -e "${BLUE}[SECTION]${NC} Diagnostic Tools"
if [[ -f "/opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh" ]]; then
    if [[ -x "/opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh" ]]; then
        echo -e "${GREEN}  ✓ PASS${NC} Diagnostic script exists and is executable"
    else
        echo -e "${YELLOW}  ⚠ WARN${NC} Diagnostic script exists but is not executable"
        echo -e "    Run: chmod +x /opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh"
    fi
else
    echo -e "${RED}  ✗ FAIL${NC} Diagnostic script not found"
    VALIDATION_FAILED=1
fi

# 5. Check current pod status (if exists)
echo ""
echo -e "${BLUE}[SECTION]${NC} Current Pod Status"
if kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME >/dev/null 2>&1; then
    POD_PHASE=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o jsonpath='{.status.phase}')
    POD_READY=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o jsonpath='{.status.containerStatuses[?(@.name=="freeipa-server")].ready}')
    RESTART_COUNT=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o jsonpath='{.status.containerStatuses[?(@.name=="freeipa-server")].restartCount}')
    
    echo -e "  Phase: ${CYAN}$POD_PHASE${NC}"
    echo -e "  Ready: ${CYAN}$POD_READY${NC}"
    echo -e "  Restart Count: ${CYAN}$RESTART_COUNT${NC}"
    
    if [[ "$POD_PHASE" == "Running" ]] && [[ "$POD_READY" == "true" ]]; then
        echo -e "${GREEN}  ✓ Pod is healthy${NC}"
    elif [[ "$POD_PHASE" == "Running" ]] && [[ "$POD_READY" == "false" ]]; then
        echo -e "${YELLOW}  ⚠ Pod is Running but not Ready (may still be installing)${NC}"
    elif [[ "$POD_PHASE" == "Failed" ]]; then
        echo -e "${RED}  ✗ Pod is in Failed state${NC}"
        echo -e "    Run diagnostics: sudo /opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh"
        VALIDATION_FAILED=1
    else
        echo -e "${YELLOW}  ⚠ Pod status: $POD_PHASE${NC}"
    fi
    
    # Check resource usage if pod is Running
    if [[ "$POD_PHASE" == "Running" ]]; then
        echo ""
        echo -e "${YELLOW}[INFO]${NC} Current resource usage:"
        kubectl --kubeconfig=$KUBECONFIG top pod -n $NAMESPACE $POD_NAME --containers 2>/dev/null || \
            echo -e "  ${YELLOW}⚠ metrics-server not available${NC}"
    fi
else
    echo -e "${YELLOW}  ⚠ FreeIPA pod not found${NC}"
    echo "  This is expected if identity stack hasn't been deployed yet"
fi

# 6. Check identity-service-accounts role changes
echo ""
echo -e "${BLUE}[SECTION]${NC} Ansible Role Updates"
ROLE_FILE="/opt/vmstation-org/cluster-infra/ansible/roles/identity-service-accounts/tasks/main.yml"
if grep -q "Handle non-Running FreeIPA pod" "$ROLE_FILE" 2>/dev/null; then
    echo -e "${GREEN}  ✓ PASS${NC} identity-service-accounts role has auto-recovery logic"
else
    echo -e "${RED}  ✗ FAIL${NC} identity-service-accounts role missing auto-recovery"
    VALIDATION_FAILED=1
fi

if grep -q "rollout restart statefulset/freeipa" "$ROLE_FILE" 2>/dev/null; then
    echo -e "${GREEN}  ✓ PASS${NC} Automatic restart logic present"
else
    echo -e "${RED}  ✗ FAIL${NC} Automatic restart logic missing"
    VALIDATION_FAILED=1
fi

# Summary
echo ""
echo -e "${CYAN}============================================================${NC}"
if [[ $VALIDATION_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All validations passed!${NC}"
    echo ""
    echo "The FreeIPA stability fixes have been applied correctly."
    echo "You can now proceed with deployment."
else
    echo -e "${RED}✗ Some validations failed${NC}"
    echo ""
    echo "Please review the failures above and ensure all fixes are applied."
    echo "You may need to:"
    echo "  1. Pull the latest changes: git pull origin main"
    echo "  2. Make scripts executable: chmod +x scripts/*.sh"
    echo "  3. Review the fix documentation: docs/FREEIPA_POD_FAILURE_FIX.md"
fi
echo -e "${CYAN}============================================================${NC}"
echo ""

exit $VALIDATION_FAILED
