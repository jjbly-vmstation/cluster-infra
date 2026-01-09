#!/usr/bin/env bash
#
# diagnose-freeipa-failure.sh
#
# Purpose: Comprehensive diagnostics for FreeIPA pod failures
# This script gathers all relevant information about FreeIPA pod state,
# logs, events, and resource usage to help identify the root cause of failures.
#
# Usage:
#   sudo ./scripts/diagnose-freeipa-failure.sh
#

set -euo pipefail

# Configuration
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NAMESPACE="identity"
POD_NAME="freeipa-0"
CONTAINER_NAME="freeipa-server"
OUTPUT_DIR="/tmp/freeipa-diagnostics-$(date +%Y%m%d-%H%M%S)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}FreeIPA Pod Diagnostics${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"
echo -e "${BLUE}[INFO]${NC} Diagnostics will be saved to: $OUTPUT_DIR"
echo ""

# Function to run and log commands
run_diagnostic() {
    local description="$1"
    local command="$2"
    local output_file="$3"
    
    echo -e "${YELLOW}[DIAG]${NC} $description..."
    
    {
        echo "==================================================="
        echo "$description"
        echo "Command: $command"
        echo "Timestamp: $(date -Iseconds)"
        echo "==================================================="
        echo ""
        eval "$command" 2>&1 || echo "[ERROR] Command failed with exit code $?"
        echo ""
    } | tee "$OUTPUT_DIR/$output_file"
}

# 1. Pod basic information
run_diagnostic "Pod basic information" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o wide" \
    "01-pod-info.txt"

# 2. Pod detailed description
run_diagnostic "Pod detailed description (events, conditions, status)" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE describe pod $POD_NAME" \
    "02-pod-describe.txt"

# 3. Pod status in JSON
run_diagnostic "Pod status (JSON format)" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o json" \
    "03-pod-json.txt"

# 4. Container logs (current)
run_diagnostic "Container logs (current instance)" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE logs $POD_NAME -c $CONTAINER_NAME --tail=1000" \
    "04-container-logs-current.txt"

# 5. Container logs (previous instance if crashed)
run_diagnostic "Container logs (previous instance if crashed)" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE logs $POD_NAME -c $CONTAINER_NAME --previous --tail=1000" \
    "05-container-logs-previous.txt"

# 6. Init container logs
run_diagnostic "Init container logs" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE logs $POD_NAME -c freeipa-preseed-hostname" \
    "06-initcontainer-logs.txt"

# 7. Node resource usage
run_diagnostic "Node resource usage" \
    "kubectl --kubeconfig=$KUBECONFIG top nodes" \
    "07-node-resources.txt"

# 8. Pod resource usage
run_diagnostic "Pod resource usage" \
    "kubectl --kubeconfig=$KUBECONFIG top pod -n $NAMESPACE $POD_NAME --containers" \
    "08-pod-resources.txt"

# 9. PVC status
run_diagnostic "PersistentVolumeClaim status" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pvc freeipa-data -o yaml" \
    "09-pvc-status.txt"

# 10. PV status
run_diagnostic "PersistentVolume status" \
    "kubectl --kubeconfig=$KUBECONFIG get pv freeipa-data-pv -o yaml" \
    "10-pv-status.txt"

# 11. StatefulSet status
run_diagnostic "StatefulSet status" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get statefulset freeipa -o yaml" \
    "11-statefulset-status.txt"

# 12. Events in identity namespace
run_diagnostic "Recent events in identity namespace" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get events --sort-by='.lastTimestamp' | tail -100" \
    "12-namespace-events.txt"

# 13. All pods in identity namespace
run_diagnostic "All pods in identity namespace" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pods -o wide" \
    "13-all-identity-pods.txt"

# 14. FreeIPA service and endpoints
run_diagnostic "FreeIPA services and endpoints" \
    "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get svc,endpoints | grep -E '(NAME|freeipa)'" \
    "14-services-endpoints.txt"

# 15. Storage path on host (if accessible)
run_diagnostic "Storage directory on host" \
    "ls -lah /srv/monitoring-data/freeipa/ 2>&1 || echo 'Storage path not accessible from this context'" \
    "15-storage-host-path.txt"

# 16. If pod is running, exec into it for internal diagnostics
if kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE get pod $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
    echo -e "${YELLOW}[DIAG]${NC} Pod is Running - collecting internal diagnostics..."
    
    run_diagnostic "systemctl status ipa (inside container)" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- systemctl status ipa --no-pager" \
        "16-systemctl-status-ipa.txt"
    
    run_diagnostic "FreeIPA install log (tail)" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- tail -n 500 /var/log/ipaserver-install.log 2>/dev/null || echo 'Log not found'" \
        "17-ipaserver-install-log.txt"
    
    run_diagnostic "FreeIPA configure-first log (tail)" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- tail -n 500 /var/log/ipa-server-configure-first.log 2>/dev/null || echo 'Log not found'" \
        "18-configure-first-log.txt"
    
    run_diagnostic "journalctl for ipa services (tail)" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- journalctl -u ipa -n 500 --no-pager 2>/dev/null || echo 'journalctl not available'" \
        "19-journalctl-ipa.txt"
    
    run_diagnostic "Hostname and DNS resolution inside container" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- bash -c 'echo \"Hostname: \$(hostname)\"; echo \"FQDN: \$(hostname -f)\"; echo \"IP: \$(hostname -I)\"; echo \"DNS (nslookup ipa.vmstation.local):\"; nslookup ipa.vmstation.local 2>&1 || true'" \
        "20-hostname-dns-inside.txt"
    
    run_diagnostic "Memory usage inside container" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- free -h" \
        "21-memory-inside.txt"
    
    run_diagnostic "Disk usage inside container" \
        "kubectl --kubeconfig=$KUBECONFIG -n $NAMESPACE exec $POD_NAME -c $CONTAINER_NAME -- df -h" \
        "22-disk-inside.txt"
else
    echo -e "${RED}[WARN]${NC} Pod is not Running - skipping internal diagnostics"
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}Diagnostics complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${BLUE}[INFO]${NC} All diagnostic files saved to: $OUTPUT_DIR"
echo ""
echo -e "${YELLOW}[NEXT STEPS]${NC}"
echo "1. Review the diagnostic files, especially:"
echo "   - 02-pod-describe.txt (events and conditions)"
echo "   - 04-container-logs-current.txt (current container logs)"
echo "   - 05-container-logs-previous.txt (if pod crashed/restarted)"
echo "2. Check for:"
echo "   - OOMKilled status (memory issues)"
echo "   - CrashLoopBackOff or Error states"
echo "   - Failed liveness/readiness probes"
echo "   - Storage/permission issues"
echo "   - FreeIPA install errors in ipaserver-install.log"
echo ""
echo "Common issues:"
echo "  - Memory exhaustion (check pod-resources.txt and memory-inside.txt)"
echo "  - Liveness probe killing healthy pod (check systemctl-status-ipa.txt)"
echo "  - Storage permissions (check storage-host-path.txt)"
echo "  - DNS resolution failures (check hostname-dns-inside.txt)"
echo ""
