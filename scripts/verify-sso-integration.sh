#!/bin/bash
# Verification script for Keycloak SSO integration
# Tests SSO configuration and OIDC client setup

set -e

KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
NAMESPACE_IDENTITY=${NAMESPACE_IDENTITY:-identity}
KEYCLOAK_URL=${KEYCLOAK_URL:-"http://192.168.4.63:30080"}
REALM=${REALM:-"cluster-services"}

echo "=========================================="
echo "Keycloak SSO Integration Verification"
echo "=========================================="
echo ""

echo "1. Checking Keycloak deployment"
echo "--------------------------------"
if kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get statefulset keycloak >/dev/null 2>&1; then
    echo "✓ Keycloak StatefulSet exists"
    kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get pods -l app.kubernetes.io/name=keycloak
else
    echo "✗ Keycloak not deployed"
    exit 1
fi
echo ""

echo "2. Testing Keycloak accessibility"
echo "----------------------------------"
if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null -w "%{http_code}" $KEYCLOAK_URL/auth/ | grep -q "200\|302\|303"; then
        echo "✓ Keycloak is accessible at $KEYCLOAK_URL/auth/"
    else
        echo "⚠ Keycloak may not be fully ready yet"
        echo "  URL: $KEYCLOAK_URL/auth/"
    fi
else
    echo "⚠ curl not installed, cannot test HTTP access"
fi
echo ""

echo "3. Checking realm configuration"
echo "--------------------------------"
if [ -f /tmp/cluster-realm.json ]; then
    echo "✓ Realm configuration exists: /tmp/cluster-realm.json"
    echo "  Clients configured:"
    grep -o '"clientId": "[^"]*"' /tmp/cluster-realm.json | cut -d'"' -f4 || true
else
    echo "⚠ Realm configuration not found at /tmp/cluster-realm.json"
    echo "  Run identity deployment playbook to generate"
fi
echo ""

echo "4. Checking OIDC client secrets"
echo "--------------------------------"
NAMESPACE_MONITORING="monitoring"
if kubectl --kubeconfig=$KUBECONFIG get namespace $NAMESPACE_MONITORING >/dev/null 2>&1; then
    echo "✓ Monitoring namespace exists"
    echo "  Note: OIDC secrets must be created manually after realm import"
    echo "  Expected secrets: grafana-oidc-secret, prometheus-oidc-secret, loki-oidc-secret"
else
    echo "⚠ Monitoring namespace not yet created"
fi
echo ""

echo "5. Checking TLS certificates"
echo "-----------------------------"
if kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get certificate keycloak-tls >/dev/null 2>&1; then
    echo "✓ Keycloak TLS certificate exists"
    kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get certificate keycloak-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True && echo "  Status: Ready" || echo "  Status: Not Ready"
else
    echo "⚠ Keycloak TLS certificate not found"
fi
echo ""

echo "6. Checking ClusterIssuer"
echo "-------------------------"
if kubectl --kubeconfig=$KUBECONFIG get clusterissuer freeipa-ca-issuer >/dev/null 2>&1; then
    echo "✓ ClusterIssuer exists: freeipa-ca-issuer"
else
    echo "✗ ClusterIssuer not found"
fi
echo ""

echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo ""
echo "Keycloak Status:"
KEYCLOAK_READY=$(kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE_IDENTITY get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "  Ready: $KEYCLOAK_READY"
echo ""
echo "Access URLs:"
echo "  Keycloak Admin: $KEYCLOAK_URL/auth/admin/"
echo "  Realm: $KEYCLOAK_URL/auth/realms/$REALM"
echo ""
echo "Next Steps:"
echo "  1. Access Keycloak admin console"
echo "  2. Import realm from /tmp/cluster-realm.json"
echo "  3. Configure LDAP user federation:"
echo "     - User Federation > Add Provider > ldap"
echo "     - Connection URL: ldap://freeipa.identity.svc.cluster.local:389"
echo "     - Users DN: cn=users,cn=accounts,dc=vmstation,dc=local"
echo "     - Bind DN: uid=admin,cn=users,cn=accounts,dc=vmstation,dc=local"
echo "  4. Test SSO with a sample application"
echo "  5. Create OIDC client secrets for monitoring stack"
echo ""
echo "Credentials:"
echo "  Admin: /root/identity-backup/cluster-admin-credentials.txt"
echo "=========================================="
