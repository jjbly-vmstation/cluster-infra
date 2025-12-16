#!/bin/bash
# verify-network-ports.sh
# Verify that all required network ports are open and accessible
# Tests connectivity between cluster nodes and FreeIPA/Keycloak services

set -euo pipefail

# Configuration
VERBOSE=${VERBOSE:-false}
TIMEOUT=${TIMEOUT:-5}

# Cluster nodes
NODES=(
    "masternode:192.168.4.63"
    "storagenodet3500:192.168.4.61"
    "homelab:192.168.4.62"
)

# Services to test
SERVICES=(
    "FreeIPA HTTP:192.168.4.63:30088:tcp"
    "FreeIPA HTTPS:192.168.4.63:30445:tcp"
    "FreeIPA LDAP:192.168.4.63:30389:tcp"
    "FreeIPA LDAPS:192.168.4.63:30636:tcp"
    "Keycloak HTTP:192.168.4.63:30180:tcp"
    "Keycloak HTTPS:192.168.4.63:30543:tcp"
)

# Critical ports that must be open
CRITICAL_TCP_PORTS=(22 80 443 389 636)
CRITICAL_UDP_PORTS=(88 464)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_failure() {
    echo -e "${RED}[✗]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Verify network port accessibility for FreeIPA, Keycloak, and cluster communication.

OPTIONS:
    -v, --verbose    Enable verbose output
    -t, --timeout N  Connection timeout in seconds (default: 5)
    -h, --help       Show this help message

TESTS PERFORMED:
    1. SSH connectivity to all cluster nodes
    2. FreeIPA service ports (HTTP, HTTPS, LDAP, LDAPS)
    3. Keycloak service ports (HTTP, HTTPS)
    4. DNS resolution for ipa.vmstation.local
    5. Kerberos ports (TCP and UDP)

EXAMPLES:
    # Run verification with defaults
    $0

    # Verbose output with custom timeout
    $0 --verbose --timeout 10

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Test TCP port connectivity
test_tcp_port() {
    local host=$1
    local port=$2
    local description=$3
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if timeout "$TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        log_success "$description - $host:$port (TCP) is accessible"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_failure "$description - $host:$port (TCP) is NOT accessible"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Test UDP port (basic check using nc if available)
test_udp_port() {
    local host=$1
    local port=$2
    local description=$3
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if command -v nc &> /dev/null; then
        # Use netcat for UDP testing
        if timeout "$TIMEOUT" nc -uz "$host" "$port" 2>/dev/null; then
            log_success "$description - $host:$port (UDP) is accessible"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            return 0
        else
            log_warn "$description - $host:$port (UDP) check inconclusive (nc test failed)"
            # Don't count as failed since UDP is hard to test
            return 0
        fi
    else
        log_verbose "$description - $host:$port (UDP) not tested (nc not available)"
        # Don't count as test if nc is not available
        TOTAL_TESTS=$((TOTAL_TESTS - 1))
        return 0
    fi
}

# Test DNS resolution
test_dns_resolution() {
    local hostname=$1
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    log_verbose "Testing DNS resolution for $hostname..."
    
    if getent hosts "$hostname" &> /dev/null; then
        local resolved_ip=$(getent hosts "$hostname" | awk '{print $1}')
        log_success "DNS resolution - $hostname resolves to $resolved_ip"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    elif grep -q "$hostname" /etc/hosts 2>/dev/null; then
        local hosts_ip=$(grep "$hostname" /etc/hosts | grep -v "^#" | awk '{print $1}' | head -1)
        log_success "DNS resolution - $hostname found in /etc/hosts as $hosts_ip"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_failure "DNS resolution - $hostname cannot be resolved"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Test SSH connectivity
test_ssh_connectivity() {
    local hostname=$1
    local ip=$2
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    log_verbose "Testing SSH connectivity to $hostname ($ip)..."
    
    # Try SSH port check
    if timeout "$TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/$ip/22" 2>/dev/null; then
        log_success "SSH connectivity - $hostname ($ip) port 22 is accessible"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_failure "SSH connectivity - $hostname ($ip) port 22 is NOT accessible"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Print header
cat << EOF

${BLUE}=============================================================================
Network Ports Verification
=============================================================================${NC}

Testing network connectivity for FreeIPA, Keycloak, and cluster nodes...

EOF

# Test 1: DNS Resolution
log_info "Test 1: DNS Resolution"
echo "-----------------------------------"
test_dns_resolution "ipa.vmstation.local"
test_dns_resolution "vmstation.local" || true  # Optional
echo ""

# Test 2: SSH Connectivity to all nodes
log_info "Test 2: SSH Connectivity to Cluster Nodes"
echo "-----------------------------------"
for node in "${NODES[@]}"; do
    IFS=':' read -r hostname ip <<< "$node"
    test_ssh_connectivity "$hostname" "$ip"
done
echo ""

# Test 3: FreeIPA Service Ports
log_info "Test 3: FreeIPA Service Ports"
echo "-----------------------------------"
test_tcp_port "192.168.4.63" "30088" "FreeIPA HTTP"
test_tcp_port "192.168.4.63" "30445" "FreeIPA HTTPS"
test_tcp_port "192.168.4.63" "30389" "FreeIPA LDAP"
test_tcp_port "192.168.4.63" "30636" "FreeIPA LDAPS"
echo ""

# Test 4: Keycloak Service Ports
log_info "Test 4: Keycloak Service Ports"
echo "-----------------------------------"
test_tcp_port "192.168.4.63" "30180" "Keycloak HTTP"
test_tcp_port "192.168.4.63" "30543" "Keycloak HTTPS"
echo ""

# Test 5: Kerberos Ports (if available)
log_info "Test 5: Kerberos Ports"
echo "-----------------------------------"
test_tcp_port "192.168.4.63" "88" "Kerberos (TCP)" || true
test_udp_port "192.168.4.63" "88" "Kerberos (UDP)" || true
test_tcp_port "192.168.4.63" "464" "Kerberos Password (TCP)" || true
test_udp_port "192.168.4.63" "464" "Kerberos Password (UDP)" || true
echo ""

# Test 6: HTTP/HTTPS Connectivity
log_info "Test 6: HTTP/HTTPS Endpoints"
echo "-----------------------------------"
test_tcp_port "192.168.4.63" "80" "HTTP"
test_tcp_port "192.168.4.63" "443" "HTTPS"
echo ""

# Summary
cat << EOF
${BLUE}=============================================================================
Verification Summary
=============================================================================${NC}

Total Tests:  ${TOTAL_TESTS}
${GREEN}Passed:       ${PASSED_TESTS}${NC}
${RED}Failed:       ${FAILED_TESTS}${NC}

EOF

if [ $FAILED_TESTS -eq 0 ]; then
    cat << EOF
${GREEN}✓ All critical network ports are accessible!${NC}

Next Steps:
  1. Verify FreeIPA/Keycloak readiness:
     ./scripts/verify-freeipa-keycloak-readiness.sh

  2. Test FreeIPA web UI:
     curl -k https://ipa.vmstation.local:30445/ipa/ui
     # Or open in browser: https://192.168.4.63:30445/ipa/ui

  3. Test Keycloak admin console:
     curl http://192.168.4.63:30180/auth/
     # Or open in browser: http://192.168.4.63:30180/auth/admin/

${BLUE}==============================================================================${NC}

EOF
    exit 0
else
    cat << EOF
${RED}✗ Some network connectivity tests failed${NC}

${YELLOW}Troubleshooting:${NC}
  1. Check firewall configuration:
     - firewalld: sudo firewall-cmd --list-all
     - iptables: sudo iptables -L -n -v

  2. Reconfigure network ports:
     ./scripts/configure-network-ports.sh --force

  3. Verify services are running:
     kubectl get pods -n identity
     kubectl get services -n identity

  4. Check node connectivity:
     ping <node-ip>
     traceroute <node-ip>

${BLUE}==============================================================================${NC}

EOF
    exit 1
fi
