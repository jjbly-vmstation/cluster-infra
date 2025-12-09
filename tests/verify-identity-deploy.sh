#!/bin/bash
# verify-identity-deploy.sh
# Acceptance test for identity deployment

set -euo pipefail

# SCRIPT_DIR and REPO_ROOT are reserved for future use if needed to reference repository files
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
PASSED=0
FAILED=0

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

test_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((PASSED++))
}

test_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((FAILED++))
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi

# Set KUBECONFIG if not set
# Note: This uses admin.conf which has cluster-admin privileges.
# For production environments, consider using a more restrictive kubeconfig.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

log_info "Starting identity deployment verification..."
log_info "Using KUBECONFIG: $KUBECONFIG"

# Test 1: Check if identity namespace exists
log_info "Test 1: Checking if identity namespace exists..."
if kubectl get namespace identity &> /dev/null; then
    test_pass "identity namespace exists"
else
    test_fail "identity namespace does not exist"
fi

# Test 2: Check if cert-manager namespace exists
log_info "Test 2: Checking if cert-manager namespace exists..."
if kubectl get namespace cert-manager &> /dev/null; then
    test_pass "cert-manager namespace exists"
else
    test_fail "cert-manager namespace does not exist"
fi

# Test 3: Check if infra node (control-plane) is detected
log_info "Test 3: Checking if infra node (control-plane) is detected..."
INFRA_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$INFRA_NODE" ]; then
    test_pass "Infra node detected: $INFRA_NODE"
else
    log_warn "No control-plane node found, checking for first schedulable node..."
    INFRA_NODE=$(kubectl get nodes -o jsonpath='{.items[?(@.spec.taints[*].effect!="NoSchedule")].metadata.name}' | awk '{print $1}')
    if [ -n "$INFRA_NODE" ]; then
        test_pass "Fallback infra node detected: $INFRA_NODE"
    else
        test_fail "No infra node detected"
    fi
fi

# Test 4: Check if /srv/identity_data/postgresql exists on infra node
log_info "Test 4: Checking if /srv/identity_data/postgresql directory exists..."
if [ -d "/srv/identity_data/postgresql" ]; then
    test_pass "/srv/identity_data/postgresql exists"
else
    test_fail "/srv/identity_data/postgresql does not exist"
fi

# Test 5: Check StorageClass
log_info "Test 5: Checking if 'manual' StorageClass exists..."
if kubectl get storageclass manual &> /dev/null; then
    test_pass "StorageClass 'manual' exists"
else
    test_fail "StorageClass 'manual' does not exist"
fi

# Test 6: Check PersistentVolume
log_info "Test 6: Checking if keycloak-postgresql-pv PersistentVolume exists..."
if kubectl get pv keycloak-postgresql-pv &> /dev/null; then
    PV_STATUS=$(kubectl get pv keycloak-postgresql-pv -o jsonpath='{.status.phase}')
    test_pass "PersistentVolume 'keycloak-postgresql-pv' exists (status: $PV_STATUS)"
else
    test_fail "PersistentVolume 'keycloak-postgresql-pv' does not exist"
fi

# Test 7: Check PVC status
log_info "Test 7: Checking Keycloak PostgreSQL PVC status..."
if kubectl get pvc data-keycloak-postgresql-0 -n identity &> /dev/null; then
    PVC_STATUS=$(kubectl get pvc data-keycloak-postgresql-0 -n identity -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" = "Bound" ]; then
        test_pass "PVC 'data-keycloak-postgresql-0' is Bound"
    else
        test_fail "PVC 'data-keycloak-postgresql-0' is not Bound (status: $PVC_STATUS)"
    fi
else
    log_warn "PVC 'data-keycloak-postgresql-0' does not exist (may not be created yet)"
fi

# Test 8: Check cert-manager deployments
log_info "Test 8: Checking cert-manager deployments..."
for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
    if kubectl get deployment "$deployment" -n cert-manager &> /dev/null; then
        READY=$(kubectl get deployment "$deployment" -n cert-manager -o jsonpath='{.status.readyReplicas}')
        DESIRED=$(kubectl get deployment "$deployment" -n cert-manager -o jsonpath='{.status.replicas}')
        if [ "$READY" = "$DESIRED" ] && [ "$READY" != "" ]; then
            test_pass "cert-manager deployment '$deployment' is ready ($READY/$DESIRED)"
        else
            test_fail "cert-manager deployment '$deployment' is not ready ($READY/$DESIRED)"
        fi
    else
        test_fail "cert-manager deployment '$deployment' does not exist"
    fi
done

# Test 9: Check Keycloak StatefulSet
log_info "Test 9: Checking Keycloak StatefulSet..."
if kubectl get statefulset keycloak -n identity &> /dev/null; then
    READY=$(kubectl get statefulset keycloak -n identity -o jsonpath='{.status.readyReplicas}')
    DESIRED=$(kubectl get statefulset keycloak -n identity -o jsonpath='{.status.replicas}')
    if [ "$READY" = "$DESIRED" ] && [ "$READY" != "" ]; then
        test_pass "Keycloak StatefulSet is ready ($READY/$DESIRED)"
    else
        test_fail "Keycloak StatefulSet is not ready ($READY/$DESIRED)"
    fi
else
    log_warn "Keycloak StatefulSet does not exist (may not be deployed yet)"
fi

# Test 10: Check PostgreSQL StatefulSet
log_info "Test 10: Checking PostgreSQL StatefulSet..."
if kubectl get statefulset keycloak-postgresql -n identity &> /dev/null; then
    READY=$(kubectl get statefulset keycloak-postgresql -n identity -o jsonpath='{.status.readyReplicas}')
    DESIRED=$(kubectl get statefulset keycloak-postgresql -n identity -o jsonpath='{.status.replicas}')
    if [ "$READY" = "$DESIRED" ] && [ "$READY" != "" ]; then
        test_pass "PostgreSQL StatefulSet is ready ($READY/$DESIRED)"
    else
        test_fail "PostgreSQL StatefulSet is not ready ($READY/$DESIRED)"
    fi
else
    log_warn "PostgreSQL StatefulSet does not exist (may not be deployed yet)"
fi

# Test 11: Check node affinity and scheduling
log_info "Test 11: Checking if cert-manager pods are scheduled on infra node..."
if kubectl get pods -n cert-manager -o wide &> /dev/null; then
    CERTMGR_PODS=$(kubectl get pods -n cert-manager -o jsonpath='{.items[*].spec.nodeName}')
    if echo "$CERTMGR_PODS" | grep -q "$INFRA_NODE"; then
        test_pass "cert-manager pods are scheduled on infra node ($INFRA_NODE)"
    else
        log_warn "cert-manager pods may not be scheduled on infra node (nodes: $CERTMGR_PODS)"
    fi
fi

# Test 12: Check if PostgreSQL is using correct image
log_info "Test 12: Checking PostgreSQL image..."
if kubectl get statefulset keycloak-postgresql -n identity &> /dev/null; then
    PG_IMAGE=$(kubectl get statefulset keycloak-postgresql -n identity -o jsonpath='{.spec.template.spec.containers[0].image}')
    if echo "$PG_IMAGE" | grep -q "postgres:11"; then
        test_pass "PostgreSQL is using postgres:11 image ($PG_IMAGE)"
    else
        log_warn "PostgreSQL is using different image: $PG_IMAGE"
    fi
else
    log_warn "PostgreSQL StatefulSet not found, skipping image check"
fi

# Test 13: Check backup directory
log_info "Test 13: Checking if backup directory exists..."
if [ -d "/root/identity-backup" ]; then
    test_pass "Backup directory /root/identity-backup exists"
else
    log_warn "Backup directory /root/identity-backup does not exist (created only during backup operations)"
fi

# Summary
echo ""
log_info "==== Verification Summary ===="
echo -e "${GREEN}Passed:${NC} $PASSED"
echo -e "${RED}Failed:${NC} $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    log_info "All tests passed!"
    exit 0
else
    log_error "Some tests failed. Please review the output above."
    exit 1
fi
