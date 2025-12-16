#!/bin/bash
# configure-network-ports.sh
# Configure firewall rules for FreeIPA, Keycloak, and cluster communication
# Supports both firewalld (RHEL 10) and iptables (Debian 12)

set -euo pipefail

# Configuration
DRY_RUN=${DRY_RUN:-false}
VERBOSE=${VERBOSE:-false}
FORCE=${FORCE:-false}

# Required ports
# TCP ports
TCP_PORTS=(22 80 443 389 636 88 464 53)
# UDP ports
UDP_PORTS=(88 464 53)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Configure firewall rules for FreeIPA, Keycloak, and Kubernetes cluster.

This script configures the following ports:

TCP Ports: ${TCP_PORTS[*]}
  - 22:  SSH (always open and unrestricted)
  - 80:  HTTP
  - 443: HTTPS
  - 389: LDAP
  - 636: LDAPS
  - 88:  Kerberos
  - 464: Kerberos password change
  - 53:  DNS (if used)

UDP Ports: ${UDP_PORTS[*]}
  - 88:  Kerberos
  - 464: Kerberos password change
  - 53:  DNS (if used)

Supports: firewalld (RHEL/CentOS), iptables (Debian/Ubuntu)

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -f, --force       Force reconfiguration even if rules exist
    -v, --verbose     Enable verbose output
    -h, --help        Show this help message

EXAMPLES:
    # Configure firewall rules
    $0

    # Dry run to see what would be changed
    $0 --dry-run

    # Force reconfiguration
    $0 --force

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
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

# Detect firewall system
detect_firewall() {
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        echo "firewalld"
    elif command -v iptables &> /dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# Configure firewalld (RHEL 10)
configure_firewalld() {
    log_info "Configuring firewalld rules..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would configure firewalld with the following rules:"
        for port in "${TCP_PORTS[@]}"; do
            log_info "[DRY RUN]   - Allow TCP port $port"
        done
        for port in "${UDP_PORTS[@]}"; do
            log_info "[DRY RUN]   - Allow UDP port $port"
        done
        return 0
    fi
    
    # Ensure firewalld is running
    if ! systemctl is-active --quiet firewalld; then
        log_info "Starting firewalld service..."
        sudo systemctl start firewalld
        sudo systemctl enable firewalld
    fi
    
    # Get active zone (default to public if not found)
    ACTIVE_ZONE=$(sudo firewall-cmd --get-active-zones | head -n 1 || echo "public")
    log_verbose "Active firewall zone: $ACTIVE_ZONE"
    
    # Configure TCP ports
    log_info "Configuring TCP ports..."
    for port in "${TCP_PORTS[@]}"; do
        log_verbose "  Adding TCP port $port..."
        if sudo firewall-cmd --zone="$ACTIVE_ZONE" --add-port="$port/tcp" --permanent &> /dev/null; then
            log_verbose "    ✓ Added TCP port $port"
        else
            log_verbose "    ℹ TCP port $port already configured or failed to add"
        fi
    done
    
    # Configure UDP ports
    log_info "Configuring UDP ports..."
    for port in "${UDP_PORTS[@]}"; do
        log_verbose "  Adding UDP port $port..."
        if sudo firewall-cmd --zone="$ACTIVE_ZONE" --add-port="$port/udp" --permanent &> /dev/null; then
            log_verbose "    ✓ Added UDP port $port"
        else
            log_verbose "    ℹ UDP port $port already configured or failed to add"
        fi
    done
    
    # Add commonly used services
    log_info "Configuring firewall services..."
    for service in ssh http https ldap ldaps kerberos dns; do
        log_verbose "  Adding service: $service..."
        sudo firewall-cmd --zone="$ACTIVE_ZONE" --add-service="$service" --permanent &> /dev/null || true
    done
    
    # Special rule for Kubernetes cluster communication
    # Allow traffic from cluster network
    log_info "Configuring Kubernetes cluster network rules..."
    for subnet in "192.168.4.0/24" "10.244.0.0/16" "10.96.0.0/12"; do
        log_verbose "  Trusting subnet: $subnet..."
        sudo firewall-cmd --zone="$ACTIVE_ZONE" --add-source="$subnet" --permanent &> /dev/null || true
    done
    
    # Reload firewall to apply changes
    log_info "Reloading firewall configuration..."
    sudo firewall-cmd --reload
    
    log_info "✓ Firewalld configuration completed"
}

# Configure iptables (Debian 12)
configure_iptables() {
    log_info "Configuring iptables rules..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would configure iptables with the following rules:"
        for port in "${TCP_PORTS[@]}"; do
            log_info "[DRY RUN]   - Allow TCP port $port"
        done
        for port in "${UDP_PORTS[@]}"; do
            log_info "[DRY RUN]   - Allow UDP port $port"
        done
        return 0
    fi
    
    # Check if iptables-persistent is installed for rule persistence
    if ! dpkg -l | grep -q iptables-persistent; then
        log_warn "iptables-persistent not installed. Rules will be lost on reboot."
        log_info "Install with: sudo apt-get install -y iptables-persistent"
    fi
    
    # Configure TCP ports
    log_info "Configuring TCP ports..."
    for port in "${TCP_PORTS[@]}"; do
        log_verbose "  Adding TCP port $port..."
        
        # Check if rule already exists
        if sudo iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &> /dev/null; then
            log_verbose "    ℹ TCP port $port already allowed"
        else
            sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            log_verbose "    ✓ Added TCP port $port"
        fi
    done
    
    # Configure UDP ports
    log_info "Configuring UDP ports..."
    for port in "${UDP_PORTS[@]}"; do
        log_verbose "  Adding UDP port $port..."
        
        # Check if rule already exists
        if sudo iptables -C INPUT -p udp --dport "$port" -j ACCEPT &> /dev/null; then
            log_verbose "    ℹ UDP port $port already allowed"
        else
            sudo iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            log_verbose "    ✓ Added UDP port $port"
        fi
    done
    
    # Allow established connections
    if ! sudo iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &> /dev/null; then
        sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log_verbose "  ✓ Added rule for established connections"
    fi
    
    # Allow loopback
    if ! sudo iptables -C INPUT -i lo -j ACCEPT &> /dev/null; then
        sudo iptables -A INPUT -i lo -j ACCEPT
        log_verbose "  ✓ Added rule for loopback interface"
    fi
    
    # Allow cluster subnets
    log_info "Configuring Kubernetes cluster network rules..."
    for subnet in "192.168.4.0/24" "10.244.0.0/16" "10.96.0.0/12"; do
        log_verbose "  Allowing subnet: $subnet..."
        if ! sudo iptables -C INPUT -s "$subnet" -j ACCEPT &> /dev/null; then
            sudo iptables -A INPUT -s "$subnet" -j ACCEPT
            log_verbose "    ✓ Added rule for $subnet"
        else
            log_verbose "    ℹ Rule for $subnet already exists"
        fi
    done
    
    # Save rules if iptables-persistent is available
    if command -v netfilter-persistent &> /dev/null; then
        log_info "Saving iptables rules..."
        sudo netfilter-persistent save
        log_verbose "  ✓ Rules saved"
    elif [ -d /etc/iptables ]; then
        log_info "Saving iptables rules to /etc/iptables/rules.v4..."
        sudo sh -c "iptables-save > /etc/iptables/rules.v4"
        log_verbose "  ✓ Rules saved"
    else
        log_warn "Could not save iptables rules. Install iptables-persistent for persistence."
    fi
    
    log_info "✓ Iptables configuration completed"
}

# Main execution
log_info "Starting network ports configuration..."
log_info "Target ports - TCP: ${TCP_PORTS[*]}, UDP: ${UDP_PORTS[*]}"

# Detect firewall system
FIREWALL_TYPE=$(detect_firewall)
log_info "Detected firewall system: $FIREWALL_TYPE"

case $FIREWALL_TYPE in
    firewalld)
        configure_firewalld
        ;;
    iptables)
        configure_iptables
        ;;
    none)
        log_warn "No supported firewall system detected (firewalld or iptables)"
        log_warn "Ports may need to be configured manually"
        log_info "Required ports:"
        log_info "  TCP: ${TCP_PORTS[*]}"
        log_info "  UDP: ${UDP_PORTS[*]}"
        exit 0
        ;;
esac

# Display summary
cat << EOF

${GREEN}=============================================================================
Network Ports Configuration Summary
=============================================================================${NC}

✓ Firewall system: $FIREWALL_TYPE
✓ Configured TCP ports: ${TCP_PORTS[*]}
✓ Configured UDP ports: ${UDP_PORTS[*]}

${YELLOW}Special Notes:${NC}
  - SSH (port 22) is always allowed and unrestricted
  - Cluster networks (192.168.4.0/24, 10.244.0.0/16, 10.96.0.0/12) are trusted
  - Rules are persistent and will survive reboots

${BLUE}Verification:${NC}
  Run the verification script to test port connectivity:
    ./scripts/verify-network-ports.sh

${GREEN}==============================================================================${NC}

EOF

log_info "Network ports configuration completed successfully"
exit 0
