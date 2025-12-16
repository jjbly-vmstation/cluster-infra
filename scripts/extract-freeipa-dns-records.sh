#!/bin/bash
# extract-freeipa-dns-records.sh
# Extract DNS records from FreeIPA pod for distribution to cluster nodes
# This script extracts DNS records from /tmp/ipa.system.records.*.db inside the FreeIPA pod

set -euo pipefail

# Configuration
KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
NAMESPACE=${NAMESPACE:-identity}
POD_NAME=${POD_NAME:-freeipa-0}
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/freeipa-dns-records}
VERBOSE=${VERBOSE:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
        echo -e "[VERBOSE] $1"
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Extract DNS records from FreeIPA pod and prepare them for distribution.

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (default: identity)
    -p, --pod POD_NAME           FreeIPA pod name (default: freeipa-0)
    -o, --output DIR             Output directory (default: /tmp/freeipa-dns-records)
    -k, --kubeconfig FILE        Path to kubeconfig (default: /etc/kubernetes/admin.conf)
    -v, --verbose                Enable verbose output
    -h, --help                   Show this help message

EXAMPLES:
    # Extract DNS records with defaults
    $0

    # Extract with custom namespace and output directory
    $0 -n identity -o /srv/dns-records

    # Verbose output
    $0 -v

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
        -p|--pod)
            POD_NAME="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
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

if ! command -v kubectl &> /dev/null; then
    log_error "kubectl command not found. Please install kubectl."
    exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
    log_error "Kubeconfig file not found: $KUBECONFIG"
    exit 1
fi

# Check if FreeIPA pod exists and is running
log_info "Checking FreeIPA pod status..."
if ! kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pod "$POD_NAME" &> /dev/null; then
    log_error "FreeIPA pod '$POD_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

POD_STATUS=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" != "Running" ]; then
    log_error "FreeIPA pod is not running. Current status: $POD_STATUS"
    exit 1
fi

POD_READY=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$POD_READY" != "True" ]; then
    log_warn "FreeIPA pod is not ready yet. DNS records may be incomplete."
fi

# Create output directory
log_info "Creating output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Extract DNS records from pod
log_info "Extracting DNS records from FreeIPA pod..."

# List available DNS record files
log_verbose "Searching for DNS record files in pod..."
DNS_FILES=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" exec "$POD_NAME" -- \
    find /tmp -name "ipa.system.records.*.db" 2>/dev/null || echo "")

if [ -z "$DNS_FILES" ]; then
    log_warn "No DNS record files found in /tmp/ipa.system.records.*.db"
    log_info "Attempting to locate DNS records in alternative locations..."
    
    # Try to find in /data or /var/lib/ipa
    DNS_FILES=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" exec "$POD_NAME" -- \
        find /data /var/lib/ipa -name "*.db" 2>/dev/null | head -5 || echo "")
    
    if [ -z "$DNS_FILES" ]; then
        log_error "No DNS record files found. FreeIPA may not be fully initialized."
        exit 1
    fi
fi

log_verbose "Found DNS record files:"
log_verbose "$DNS_FILES"

# Copy each DNS record file
RECORD_COUNT=0
for DNS_FILE in $DNS_FILES; do
    BASENAME=$(basename "$DNS_FILE")
    log_verbose "Copying $BASENAME..."
    
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" exec "$POD_NAME" -- \
        cat "$DNS_FILE" > "$OUTPUT_DIR/$BASENAME" 2>/dev/null; then
        RECORD_COUNT=$((RECORD_COUNT + 1))
        log_verbose "  ✓ Copied to $OUTPUT_DIR/$BASENAME"
    else
        log_warn "  ✗ Failed to copy $DNS_FILE"
    fi
done

if [ $RECORD_COUNT -eq 0 ]; then
    log_error "Failed to extract any DNS records"
    exit 1
fi

# Parse and create a simplified hosts file format
log_info "Parsing DNS records into hosts file format..."

HOSTS_FILE="$OUTPUT_DIR/freeipa-hosts.txt"
> "$HOSTS_FILE"  # Clear file

# Get FreeIPA service IP or NodePort IP
FREEIPA_SERVICE_IP=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NAMESPACE" get service freeipa -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ -z "$FREEIPA_SERVICE_IP" ]; then
    # If no ClusterIP service, use the masternode IP from inventory
    FREEIPA_SERVICE_IP="192.168.4.63"
    log_warn "FreeIPA service not found, using masternode IP: $FREEIPA_SERVICE_IP"
fi

log_verbose "FreeIPA IP address: $FREEIPA_SERVICE_IP"

# Create hosts entries
echo "# FreeIPA DNS Records - Generated on $(date)" >> "$HOSTS_FILE"
echo "# Source: FreeIPA pod $POD_NAME in namespace $NAMESPACE" >> "$HOSTS_FILE"
echo "" >> "$HOSTS_FILE"

# Primary hostname
echo "$FREEIPA_SERVICE_IP    ipa.vmstation.local ipa" >> "$HOSTS_FILE"

# Additional domain entries
echo "$FREEIPA_SERVICE_IP    vmstation.local" >> "$HOSTS_FILE"

# Parse actual DNS records from database files
for DB_FILE in "$OUTPUT_DIR"/*.db; do
    if [ -f "$DB_FILE" ]; then
        log_verbose "Parsing $DB_FILE..."
        
        # Extract A records (basic parsing)
        # Format: hostname IN A ip_address
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            # Look for A records
            if echo "$line" | grep -q " IN A "; then
                HOSTNAME=$(echo "$line" | awk '{print $1}' | sed 's/\.$//')
                IPADDR=$(echo "$line" | awk '{print $NF}')
                
                if [[ "$HOSTNAME" != "" && "$IPADDR" != "" ]]; then
                    # Only add if not already present
                    if ! grep -q "^$IPADDR.*$HOSTNAME" "$HOSTS_FILE" 2>/dev/null; then
                        echo "$IPADDR    $HOSTNAME" >> "$HOSTS_FILE"
                        log_verbose "  Added: $IPADDR -> $HOSTNAME"
                    fi
                fi
            fi
        done < "$DB_FILE"
    fi
done

# Create a summary file
SUMMARY_FILE="$OUTPUT_DIR/extraction-summary.txt"
cat > "$SUMMARY_FILE" << EOF
FreeIPA DNS Record Extraction Summary
======================================
Extraction Time: $(date)
FreeIPA Pod: $POD_NAME
Namespace: $NAMESPACE
FreeIPA IP: $FREEIPA_SERVICE_IP

Extracted Files:
$(ls -lh "$OUTPUT_DIR"/*.db 2>/dev/null || echo "None")

Generated Hosts File:
$HOSTS_FILE

Total Records: $(grep -v "^#" "$HOSTS_FILE" | grep -v "^$" | wc -l)

Next Steps:
1. Review the hosts file: cat $HOSTS_FILE
2. Distribute to cluster nodes using: ./scripts/configure-dns-records.sh
3. Or use Ansible playbook: ansible-playbook ansible/playbooks/configure-dns-network-step4a.yml
EOF

log_info "DNS records extracted successfully!"
echo ""
cat "$SUMMARY_FILE"
echo ""
log_info "Output directory: $OUTPUT_DIR"
log_info "Hosts file: $HOSTS_FILE"

exit 0
