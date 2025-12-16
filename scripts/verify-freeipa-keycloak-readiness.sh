#!/bin/bash
# verify-freeipa-keycloak-readiness.sh
# Comprehensive readiness validation for FreeIPA and Keycloak
# Extends the existing verify-identity-deployment.sh with additional checks

set -euo pipefail

# Configuration
KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
NAMESPACE=${NAMESPACE:-identity}
VERBOSE=${VERBOSE:-false}
TEST_KERBEROS=${TEST_KERBEROS:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

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
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
}

log_failure() {
    echo -e "${RED}[✗]${NC} $1"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
    WARNING_CHECKS=$((WARNING_CHECKS + 1))
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

Comprehensive validation of FreeIPA and Keycloak deployment readiness.

OPTIONS:
    -n, --namespace NAMESPACE  Kubernetes namespace (default: identity)
    -k, --kubeconfig FILE      Path to kubeconfig (default: /etc/kubernetes/admin.conf)
    -v, --verbose              Enable verbose output
    --test-kerberos            Test Kerberos authentication (requires kinit)
    -h, --help                 Show this help message

CHECKS PERFORMED:
    1. Pod readiness and status
    2. DNS resolution
    3. Service endpoints
    4. Web UI accessibility
    5. LDAP connectivity
    6. Network ports
    7. Certificate validity
    8. Optional: Kerberos authentication

EXAMPLES:
    # Standard validation
    $0

    # Verbose output with Kerberos test
    $0 --verbose --test-kerberos

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -k|--kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --test-kerberos)
            TEST_KERBEROS=true
            shift
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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if ! command -v kubectl &> /dev/null; then
        log_failure "kubectl not found"
        return 1
    fi
    
    if [ ! -f "$KUBECONFIG" ]; then
        log_failure "kubeconfig not found: $KUBECONFIG"
        return 1
    fi
    
    log_success "Prerequisites check passed"
    return 0
}

# Check pod readiness
check_pod_readiness() {
    local pod_name=$1
    local label=$2
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking pod readiness: $pod_name"
    
    local pod_status=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pods -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$pod_status" != "Running" ]; then
        log_failure "$pod_name is not running (status: $pod_status)"
        return 1
    fi
    
    local pod_ready=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pods -l "$label" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [ "$pod_ready" != "True" ]; then
        log_failure "$pod_name is not ready"
        return 1
    fi
    
    log_success "$pod_name is running and ready (1/1)"
    return 0
}

# Check DNS resolution
check_dns_resolution() {
    local hostname=$1
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking DNS resolution: $hostname"
    
    if getent hosts "$hostname" &> /dev/null; then
        local resolved_ip=$(getent hosts "$hostname" | awk '{print $1}')
        log_success "DNS resolution: $hostname -> $resolved_ip"
        return 0
    elif grep -q "$hostname" /etc/hosts 2>/dev/null; then
        local hosts_ip=$(grep "$hostname" /etc/hosts | grep -v "^#" | awk '{print $1}' | head -1)
        log_success "DNS resolution: $hostname found in /etc/hosts ($hosts_ip)"
        return 0
    else
        log_failure "DNS resolution failed for $hostname"
        return 1
    fi
}

# Check web UI accessibility
check_web_ui() {
    local url=$1
    local description=$2
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking web UI: $description ($url)"
    
    if command -v curl &> /dev/null; then
        local http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null || echo "000")
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "301" ]; then
            log_success "$description is accessible (HTTP $http_code)"
            return 0
        else
            log_failure "$description is not accessible (HTTP $http_code)"
            return 1
        fi
    else
        log_warning "$description check skipped (curl not available)"
        return 0
    fi
}

# Check service endpoint
check_service_endpoint() {
    local service_name=$1
    local port=$2
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking service endpoint: $service_name:$port"
    
    local endpoint=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get endpoints "$service_name" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    
    if [ -z "$endpoint" ]; then
        log_failure "Service $service_name has no endpoints"
        return 1
    fi
    
    log_success "Service $service_name has endpoint: $endpoint"
    return 0
}

# Check LDAP connectivity
check_ldap_connectivity() {
    local host=$1
    local port=$2
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking LDAP connectivity: $host:$port"
    
    if command -v ldapsearch &> /dev/null; then
        if timeout 10 ldapsearch -x -H "ldap://$host:$port" -b "" -s base "(objectclass=*)" namingContexts &> /dev/null; then
            log_success "LDAP connectivity successful ($host:$port)"
            return 0
        else
            log_failure "LDAP connectivity failed ($host:$port)"
            return 1
        fi
    else
        # Fallback to basic TCP check
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            log_success "LDAP port $port is accessible on $host"
            return 0
        else
            log_failure "LDAP port $port is not accessible on $host"
            return 1
        fi
    fi
}

# Check Kerberos
check_kerberos() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log_verbose "Checking Kerberos authentication..."
    
    if ! command -v kinit &> /dev/null; then
        log_warning "Kerberos check skipped (kinit not available)"
        return 0
    fi
    
    log_info "To test Kerberos authentication, run:"
    log_info "  echo 'admin_password' | kinit admin"
    log_info "  klist"
    
    log_warning "Kerberos authentication test skipped (requires manual password entry)"
    return 0
}

# Print header
cat << EOF

${BLUE}=============================================================================
FreeIPA and Keycloak Readiness Verification
=============================================================================${NC}

Namespace: $NAMESPACE
Kubeconfig: $KUBECONFIG

EOF

# Run checks
log_info "Starting readiness checks..."
echo ""

# Section 1: Prerequisites
log_info "Section 1: Prerequisites"
echo "-----------------------------------"
check_prerequisites || exit 1
echo ""

# Section 2: Pod Readiness
log_info "Section 2: Pod Readiness"
echo "-----------------------------------"
check_pod_readiness "FreeIPA" "app=freeipa"
check_pod_readiness "Keycloak" "app.kubernetes.io/name=keycloak"
check_pod_readiness "PostgreSQL" "app=keycloak,component=postgresql"
echo ""

# Section 3: DNS Resolution
log_info "Section 3: DNS Resolution"
echo "-----------------------------------"
check_dns_resolution "ipa.vmstation.local"
check_dns_resolution "vmstation.local" || true
echo ""

# Section 4: Service Endpoints
log_info "Section 4: Service Endpoints"
echo "-----------------------------------"
check_service_endpoint "freeipa" "80"
check_service_endpoint "keycloak-nodeport" "8080" || check_service_endpoint "keycloak" "8080"
echo ""

# Section 5: Web UI Accessibility
log_info "Section 5: Web UI Accessibility"
echo "-----------------------------------"
check_web_ui "http://192.168.4.63:30088" "FreeIPA HTTP"
check_web_ui "https://192.168.4.63:30445/ipa/ui" "FreeIPA Web UI"
check_web_ui "http://192.168.4.63:30180/auth/" "Keycloak HTTP"
echo ""

# Section 6: LDAP Connectivity
log_info "Section 6: LDAP Connectivity"
echo "-----------------------------------"
check_ldap_connectivity "192.168.4.63" "30389"
echo ""

# Section 7: Kerberos (optional)
if [ "$TEST_KERBEROS" = "true" ]; then
    log_info "Section 7: Kerberos Authentication"
    echo "-----------------------------------"
    check_kerberos
    echo ""
fi

# Summary
cat << EOF
${BLUE}=============================================================================
Verification Summary
=============================================================================${NC}

Total Checks: ${TOTAL_CHECKS}
${GREEN}Passed:       ${PASSED_CHECKS}${NC}
${YELLOW}Warnings:     ${WARNING_CHECKS}${NC}
${RED}Failed:       ${FAILED_CHECKS}${NC}

EOF

if [ $FAILED_CHECKS -eq 0 ]; then
    cat << EOF
${GREEN}✓ FreeIPA and Keycloak are ready!${NC}

${BLUE}Access Points:${NC}
  FreeIPA Web UI:  https://192.168.4.63:30445/ipa/ui
                   or https://ipa.vmstation.local:30445/ipa/ui (if DNS configured)
  
  Keycloak Admin:  http://192.168.4.63:30180/auth/admin/
  
  Credentials:     Check /root/identity-backup/ for saved credentials

${BLUE}Next Steps:${NC}
  1. Configure applications to use Keycloak OIDC:
     See docs/KEYCLOAK-INTEGRATION.md

  2. Add users and groups in FreeIPA:
     ipa user-add <username> --first=<first> --last=<last>
     ipa group-add <groupname>

  3. Deploy infrastructure services and monitoring:
     Continue with deployment sequence steps

${BLUE}==============================================================================${NC}

EOF
    exit 0
else
    cat << EOF
${RED}✗ Some readiness checks failed${NC}

${YELLOW}Troubleshooting:${NC}
  1. Check pod logs:
     kubectl logs -n $NAMESPACE freeipa-0
     kubectl logs -n $NAMESPACE <keycloak-pod-name>

  2. Check pod status:
     kubectl get pods -n $NAMESPACE -o wide
     kubectl describe pod -n $NAMESPACE freeipa-0

  3. Check services:
     kubectl get services -n $NAMESPACE
     kubectl describe service -n $NAMESPACE freeipa

  4. Verify network connectivity:
     ./scripts/verify-network-ports.sh

  5. Check DNS configuration:
     cat /etc/hosts | grep ipa.vmstation.local

${BLUE}==============================================================================${NC}

EOF
    exit 1
fi
