#!/bin/bash
# Verification script for identity stack deployment
# Tests that all components are properly deployed and tolerating control-plane taint

set -e

KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
NAMESPACE_IDENTITY=${NAMESPACE_IDENTITY:-identity}
NAMESPACE_CERTMGR=${NAMESPACE_CERTMGR:-cert-manager}

echo "=========================================="
echo "Identity Stack Deployment Verification"
echo "=========================================="
echo ""

# Function to check if a resource exists and is ready
check_resource() {
    local resource=$1
    local namespace=$2
    local name=$3
    
    echo -n "Checking $resource $name in namespace $namespace... "
    if kubectl --kubeconfig=$KUBECONFIG -n $namespace get $resource $name >/dev/null 2>&1; then
        echo "✓ EXISTS"
        return 0
    else
        echo "✗ NOT FOUND"
        return 1
    fi
}

# Function to check pod status
check_pod_status() {
    local namespace=$1
    local label=$2
    local expected=$3
    
    echo -n "Checking pods with label $label in $namespace... "
    local count=$(kubectl --kubeconfig=$KUBECONFIG -n $namespace get pods -l $label --no-headers 2>/dev/null | wc -l)
    
    if [ "$count" -ge "$expected" ]; then
        local ready=$(kubectl --kubeconfig=$KUBECONFIG -n $namespace get pods -l $label -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c "True" || echo 0)
        if [ "$ready" -ge "$expected" ]; then
            echo "✓ RUNNING ($ready/$count pods ready)"
            return 0
        else
            echo "⚠ STARTING ($ready/$count pods ready)"
            return 1
        fi
    else
        echo "✗ NOT FOUND ($count pods found, expected $expected)"
        return 1
    fi
}

# Function to check tolerations
check_tolerations() {
    local namespace=$1
    local resource=$2
    local name=$3
    
    echo -n "Checking control-plane toleration for $resource/$name... "
    local tolerations=$(kubectl --kubeconfig=$KUBECONFIG -n $namespace get $resource $name -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="node-role.kubernetes.io/control-plane")]}' 2>/dev/null)
    
    if [ -n "$tolerations" ]; then
        echo "✓ PRESENT"
        return 0
    else
        echo "✗ MISSING"
        return 1
    fi
}

echo "1. Checking Namespaces"
echo "----------------------"
check_resource namespace "" $NAMESPACE_IDENTITY
check_resource namespace "" $NAMESPACE_CERTMGR
echo ""

echo "2. Checking Storage"
echo "-------------------"
check_resource storageclass "" manual
check_resource pv "" keycloak-postgresql-pv
check_resource pvc $NAMESPACE_IDENTITY data-keycloak-postgresql-0
echo ""

echo "3. Checking PostgreSQL"
echo "----------------------"
check_resource statefulset $NAMESPACE_IDENTITY keycloak-postgresql
check_pod_status $NAMESPACE_IDENTITY "app=keycloak,component=postgresql" 1
check_tolerations $NAMESPACE_IDENTITY statefulset keycloak-postgresql
echo ""

echo "4. Checking Keycloak"
echo "--------------------"
check_resource statefulset $NAMESPACE_IDENTITY keycloak
check_pod_status $NAMESPACE_IDENTITY "app.kubernetes.io/name=keycloak" 1
check_resource service $NAMESPACE_IDENTITY keycloak-nodeport
echo ""

echo "5. Checking FreeIPA (optional)"
echo "------------------------------"
if check_resource statefulset $NAMESPACE_IDENTITY freeipa; then
    check_pod_status $NAMESPACE_IDENTITY "app=freeipa" 1
    check_tolerations $NAMESPACE_IDENTITY statefulset freeipa
else
    echo "FreeIPA not deployed (optional component)"
fi
echo ""

echo "6. Checking cert-manager"
echo "------------------------"
check_resource deployment $NAMESPACE_CERTMGR cert-manager
check_resource deployment $NAMESPACE_CERTMGR cert-manager-webhook
check_resource deployment $NAMESPACE_CERTMGR cert-manager-cainjector
check_pod_status $NAMESPACE_CERTMGR "app.kubernetes.io/instance=cert-manager" 3
echo ""

echo "7. Checking ClusterIssuer"
echo "-------------------------"
check_resource clusterissuer "" freeipa-ca-issuer
echo ""

echo "8. Checking Node Scheduling"
echo "---------------------------"
echo "Control-plane node(s):"
kubectl --kubeconfig=$KUBECONFIG get nodes -l node-role.kubernetes.io/control-plane -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
echo ""

echo "Identity pods distribution:"
kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
echo ""

echo "9. Verification Summary"
echo "-----------------------"
ERRORS=0

# Count running pods
POSTGRES_PODS=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get pods -l app=keycloak,component=postgresql --no-headers 2>/dev/null | grep -c Running || echo 0)
KEYCLOAK_PODS=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get pods -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -c Running || echo 0)
CERTMGR_PODS=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_CERTMGR get pods --no-headers 2>/dev/null | grep -c Running || echo 0)

echo "PostgreSQL: $POSTGRES_PODS pod(s) running"
echo "Keycloak: $KEYCLOAK_PODS pod(s) running"
echo "cert-manager: $CERTMGR_PODS pod(s) running"

if [ "$POSTGRES_PODS" -lt 1 ] || [ "$KEYCLOAK_PODS" -lt 1 ] || [ "$CERTMGR_PODS" -lt 3 ]; then
    ERRORS=1
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "✓ All critical components are deployed and running!"
    echo ""
    echo "Access Keycloak:"
    NODE_IP=$(kubectl --kubeconfig=$KUBECONFIG get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
    if [ -n "$NODE_IP" ]; then
        echo "  http://$NODE_IP:30080/auth"
    else
        echo "  Unable to determine node IP. Check 'kubectl get nodes -o wide' for node IPs"
    fi
    echo ""
    echo "Credentials location:"
    echo "  /root/identity-backup/keycloak-admin-credentials.txt"
    exit 0
else
    echo "⚠ Some components are not ready yet. Please wait for pods to start."
    echo "   Run this script again in a few minutes."
    echo ""
    echo "To check pod status:"
    echo "  kubectl get pods -n $NAMESPACE_IDENTITY -o wide"
    echo "  kubectl get pods -n $NAMESPACE_CERTMGR -o wide"
    echo ""
    echo "To check events:"
    echo "  kubectl get events -n $NAMESPACE_IDENTITY --sort-by=.metadata.creationTimestamp"
    exit 1
fi
