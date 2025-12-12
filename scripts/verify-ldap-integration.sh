#!/bin/bash
# Verification script for FreeIPA LDAP integration
# Tests LDAP connectivity from all cluster nodes

set -e

FREEIPA_SERVER=${FREEIPA_SERVER:-"ipa.vmstation.local"}
FREEIPA_DOMAIN=${FREEIPA_DOMAIN:-"vmstation.local"}
LDAP_BASE_DN=${LDAP_BASE_DN:-"dc=vmstation,dc=local"}

echo "=========================================="
echo "FreeIPA LDAP Integration Verification"
echo "=========================================="
echo ""

echo "1. Testing DNS resolution for FreeIPA server"
echo "---------------------------------------------"
if nslookup $FREEIPA_SERVER >/dev/null 2>&1 || grep -q $FREEIPA_SERVER /etc/hosts; then
    echo "✓ FreeIPA server hostname resolves: $FREEIPA_SERVER"
else
    echo "✗ Cannot resolve FreeIPA server: $FREEIPA_SERVER"
    echo "  Add entry to /etc/hosts or configure DNS"
    exit 1
fi
echo ""

echo "2. Testing LDAP connectivity"
echo "----------------------------"
if command -v ldapsearch >/dev/null 2>&1; then
    if timeout 10 ldapsearch -x -H ldap://$FREEIPA_SERVER -b "$LDAP_BASE_DN" -LLL "(objectClass=*)" dn 2>/dev/null | head -5; then
        echo "✓ LDAP server is accessible"
    else
        echo "⚠ LDAP server not accessible (may require authentication)"
    fi
else
    echo "⚠ ldapsearch not installed. Install openldap-clients to test LDAP connectivity"
fi
echo ""

echo "3. Checking FreeIPA client configuration"
echo "-----------------------------------------"
if [ -f /etc/ipa/default.conf ]; then
    echo "✓ FreeIPA client configured"
    echo "  Config: /etc/ipa/default.conf"
    grep -E "^(server|realm|domain)" /etc/ipa/default.conf 2>/dev/null || true
else
    echo "✗ FreeIPA client not configured"
    echo "  Run: ipa-client-install to join this node to FreeIPA domain"
fi
echo ""

echo "4. Checking SSSD service"
echo "------------------------"
if systemctl is-active sssd >/dev/null 2>&1; then
    echo "✓ SSSD service is running"
    systemctl status sssd --no-pager | head -3
else
    echo "✗ SSSD service is not running"
    echo "  Start with: systemctl start sssd"
fi
echo ""

echo "5. Testing user authentication"
echo "------------------------------"
if command -v id >/dev/null 2>&1 && [ -f /etc/ipa/default.conf ]; then
    echo "Testing if LDAP users are visible..."
    if id admin@$FREEIPA_DOMAIN >/dev/null 2>&1; then
        echo "✓ LDAP users are accessible"
        id admin@$FREEIPA_DOMAIN
    else
        echo "⚠ LDAP users not yet accessible (SSSD may still be syncing)"
    fi
else
    echo "⚠ Cannot test user authentication (client not configured)"
fi
echo ""

echo "=========================================="
echo "Verification Summary"
echo "=========================================="
if [ -f /etc/ipa/default.conf ] && systemctl is-active sssd >/dev/null 2>&1; then
    echo "✓ FreeIPA LDAP integration is configured and active"
    echo ""
    echo "Next steps:"
    echo "  - Create users in FreeIPA: ipa user-add username"
    echo "  - Test SSH login: ssh username@$(hostname)"
    echo "  - Configure Keycloak LDAP federation"
else
    echo "⚠ FreeIPA LDAP integration not fully configured"
    echo ""
    echo "To complete setup:"
    echo "  1. Deploy FreeIPA server: kubectl get pods -n identity"
    echo "  2. Join nodes to domain: ipa-client-install"
    echo "  3. Start SSSD: systemctl start sssd"
fi
echo "=========================================="
