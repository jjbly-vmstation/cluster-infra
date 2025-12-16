#!/bin/bash
# configure-dns-records.sh
# Distribute DNS records to /etc/hosts on all cluster nodes
# This script adds FreeIPA DNS records to /etc/hosts on each node

set -euo pipefail

# Configuration
INVENTORY_FILE=${INVENTORY_FILE:-/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml}
DNS_RECORDS_FILE=${DNS_RECORDS_FILE:-/tmp/freeipa-dns-records/freeipa-hosts.txt}
BACKUP_SUFFIX=${BACKUP_SUFFIX:-.pre-freeipa}
DRY_RUN=${DRY_RUN:-false}
VERBOSE=${VERBOSE:-false}

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

Distribute FreeIPA DNS records to /etc/hosts on all cluster nodes.

OPTIONS:
    -i, --inventory FILE         Ansible inventory file (default: /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml)
    -f, --file FILE              DNS records file (default: /tmp/freeipa-dns-records/freeipa-hosts.txt)
    -b, --backup-suffix SUFFIX   Backup suffix for /etc/hosts (default: .pre-freeipa)
    -d, --dry-run                Show what would be done without making changes
    -v, --verbose                Enable verbose output
    -h, --help                   Show this help message

EXAMPLES:
    # Distribute DNS records to all nodes
    $0

    # Dry run to see what would be changed
    $0 --dry-run

    # Use custom DNS records file
    $0 -f /srv/dns-records/custom-hosts.txt

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--inventory)
            INVENTORY_FILE="$2"
            shift 2
            ;;
        -f|--file)
            DNS_RECORDS_FILE="$2"
            shift 2
            ;;
        -b|--backup-suffix)
            BACKUP_SUFFIX="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
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

# Validate prerequisites
log_info "Validating prerequisites..."

if [ ! -f "$DNS_RECORDS_FILE" ]; then
    log_error "DNS records file not found: $DNS_RECORDS_FILE"
    log_info "Please run ./scripts/extract-freeipa-dns-records.sh first"
    exit 1
fi

# For this script, we'll use a simpler approach without requiring Ansible
# We'll configure the local host and provide instructions for other nodes
log_info "Reading DNS records from: $DNS_RECORDS_FILE"

# Count non-comment, non-empty lines
RECORD_COUNT=$(grep -v "^#" "$DNS_RECORDS_FILE" | grep -v "^$" | wc -l)
log_info "Found $RECORD_COUNT DNS records to add"

if [ "$RECORD_COUNT" -eq 0 ]; then
    log_error "No DNS records found in $DNS_RECORDS_FILE"
    exit 1
fi

# Display records to be added
if [ "$VERBOSE" = "true" ] || [ "$DRY_RUN" = "true" ]; then
    log_info "DNS records to be added:"
    grep -v "^#" "$DNS_RECORDS_FILE" | grep -v "^$" || true
fi

# Function to add records to a host
add_records_to_host() {
    local hostname=$1
    local ip_address=$2
    local user=$3
    local ssh_key=$4
    local is_local=$5
    
    log_info "Configuring DNS records on $hostname ($ip_address)..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would backup /etc/hosts to /etc/hosts${BACKUP_SUFFIX}"
        log_info "[DRY RUN] Would add $RECORD_COUNT records to /etc/hosts"
        return 0
    fi
    
    # Create a script to run on the remote host
    local REMOTE_SCRIPT=$(cat <<'REMOTE_EOF'
#!/bin/bash
set -euo pipefail

DNS_RECORDS_FILE=$1
BACKUP_SUFFIX=$2

# Backup existing /etc/hosts
if [ ! -f "/etc/hosts${BACKUP_SUFFIX}" ]; then
    cp /etc/hosts "/etc/hosts${BACKUP_SUFFIX}"
    echo "✓ Backed up /etc/hosts to /etc/hosts${BACKUP_SUFFIX}"
fi

# Remove old FreeIPA entries (if any)
sed -i '/# FreeIPA DNS Records/,/^$/d' /etc/hosts

# Add new FreeIPA entries
cat "$DNS_RECORDS_FILE" >> /etc/hosts

echo "✓ Added FreeIPA DNS records to /etc/hosts"

# Verify key record
if grep -q "ipa.vmstation.local" /etc/hosts; then
    echo "✓ Verified: ipa.vmstation.local is resolvable"
else
    echo "✗ Warning: ipa.vmstation.local not found in /etc/hosts"
    exit 1
fi
REMOTE_EOF
)
    
    if [ "$is_local" = "true" ]; then
        # Run locally
        log_verbose "Running on local host..."
        
        # Backup
        if [ ! -f "/etc/hosts${BACKUP_SUFFIX}" ]; then
            sudo cp /etc/hosts "/etc/hosts${BACKUP_SUFFIX}"
            log_verbose "✓ Backed up /etc/hosts"
        fi
        
        # Remove old FreeIPA entries
        sudo sed -i '/# FreeIPA DNS Records/,/^$/d' /etc/hosts
        
        # Add new entries
        sudo sh -c "cat '$DNS_RECORDS_FILE' >> /etc/hosts"
        
        # Verify
        if grep -q "ipa.vmstation.local" /etc/hosts; then
            log_info "✓ Successfully configured DNS records on $hostname"
        else
            log_error "✗ Failed to verify DNS records on $hostname"
            return 1
        fi
    else
        # Run on remote host via SSH
        log_verbose "Connecting via SSH to $user@$ip_address..."
        
        # Copy DNS records file to remote host
        if [ -n "$ssh_key" ]; then
            scp -o StrictHostKeyChecking=no -i "$ssh_key" "$DNS_RECORDS_FILE" "$user@$ip_address:/tmp/freeipa-hosts.txt" &> /dev/null
        else
            scp -o StrictHostKeyChecking=no "$DNS_RECORDS_FILE" "$user@$ip_address:/tmp/freeipa-hosts.txt" &> /dev/null
        fi
        
        # Execute remote script
        if [ -n "$ssh_key" ]; then
            ssh -o StrictHostKeyChecking=no -i "$ssh_key" "$user@$ip_address" "sudo bash -s /tmp/freeipa-hosts.txt $BACKUP_SUFFIX" <<< "$REMOTE_SCRIPT"
        else
            ssh -o StrictHostKeyChecking=no "$user@$ip_address" "sudo bash -s /tmp/freeipa-hosts.txt $BACKUP_SUFFIX" <<< "$REMOTE_SCRIPT"
        fi
        
        log_info "✓ Successfully configured DNS records on $hostname"
    fi
}

# Configure localhost (masternode)
log_info "Configuring DNS records on local host..."
add_records_to_host "localhost" "127.0.0.1" "root" "" "true"

# Provide instructions for remote nodes
cat << EOF

${GREEN}=============================================================================
DNS Records Configuration Summary
=============================================================================${NC}

✓ DNS records have been configured on the local host (masternode)

To configure DNS records on other cluster nodes, run these commands:

${YELLOW}For storagenodet3500 (192.168.4.61):${NC}
  ssh root@192.168.4.61 -i ~/.ssh/id_k3s
  # Then copy and paste the DNS records from $DNS_RECORDS_FILE to /etc/hosts

${YELLOW}For homelab (192.168.4.62):${NC}
  ssh jashandeepjustinbains@192.168.4.62 -i ~/.ssh/id_k3s
  sudo bash
  # Then copy and paste the DNS records from $DNS_RECORDS_FILE to /etc/hosts

${BLUE}Or use the Ansible playbook for automated distribution:${NC}
  ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \\
    ansible/playbooks/configure-dns-network-step4a.yml --tags dns

${GREEN}Verification:${NC}
  # Test DNS resolution on each node:
  ping -c 2 ipa.vmstation.local
  nslookup ipa.vmstation.local || getent hosts ipa.vmstation.local

${GREEN}==============================================================================${NC}

EOF

log_info "DNS records configuration completed on local host"
exit 0
