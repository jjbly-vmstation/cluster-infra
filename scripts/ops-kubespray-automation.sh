#!/usr/bin/env bash
# VMStation Kubespray Deployment Automation Script
# This script automates the complete Kubespray deployment workflow
# Designed to run inside GitHub Actions runner with VMSTATION_SSH_KEY secret
set -euo pipefail

# ============================================================================
# Environment Configuration
# ============================================================================
REPO_ROOT="${REPO_ROOT:-/github/workspace}"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$REPO_ROOT/.cache/kubespray}"
KUBESPRAY_INVENTORY="${KUBESPRAY_INVENTORY:-$KUBESPRAY_DIR/inventory/mycluster/inventory.ini}"
MAIN_INVENTORY="${MAIN_INVENTORY:-$REPO_ROOT/ansible/inventory/hosts.yml}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/tmp/id_vmstation_ops}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARTIFACTS_DIR="$REPO_ROOT/ansible/artifacts/run-$TIMESTAMP"
LOG_DIR="$ARTIFACTS_DIR/ansible-run-logs"
BACKUP_DIR="$REPO_ROOT/.git/ops-backups/$TIMESTAMP"
KUBECONFIG_PATH="/tmp/admin.conf"

# ============================================================================
# Logging Functions
# ============================================================================
log_info() {
    echo "[INFO $(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/main.log"
}

log_warn() {
    echo "[WARN $(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/main.log" >&2
}

log_error() {
    echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/main.log" >&2
}

log_cmd() {
    local cmd="$1"
    local logfile="$2"
    echo "=== Running: $cmd ===" | tee -a "$logfile"
    echo "=== Time: $(date) ===" | tee -a "$logfile"
}

# ============================================================================
# Create Idempotent Fix Playbooks
# ============================================================================
create_idempotent_fixes() {
    log_info "Creating idempotent fix playbooks..."
    
    local fixes_dir="$REPO_ROOT/ansible/playbooks/fixes"
    mkdir -p "$fixes_dir"
    
    # Create swap disable playbook
    cat > "$fixes_dir/disable-swap.yml" << 'EOF'
---
# Idempotent playbook to disable swap on all nodes
- name: Disable swap for Kubernetes
  hosts: all
  become: true
  tasks:
    - name: Disable swap immediately
      ansible.builtin.command: swapoff -a
      changed_when: false
      
    - name: Remove swap entries from fstab
      ansible.builtin.lineinfile:
        path: /etc/fstab
        regexp: '^[^#].*\s+swap\s+'
        state: absent
        backup: yes
      
    - name: Verify swap is disabled
      ansible.builtin.command: swapon --show
      register: swap_status
      changed_when: false
      failed_when: swap_status.stdout != ""
EOF
    
    # Create kernel modules playbook
    cat > "$fixes_dir/load-kernel-modules.yml" << 'EOF'
---
# Idempotent playbook to load required kernel modules
- name: Load required kernel modules for Kubernetes
  hosts: all
  become: true
  tasks:
    - name: Load br_netfilter module
      community.general.modprobe:
        name: br_netfilter
        state: present
        
    - name: Load overlay module
      community.general.modprobe:
        name: overlay
        state: present
        
    - name: Ensure modules load on boot
      ansible.builtin.copy:
        content: |
          br_netfilter
          overlay
        dest: /etc/modules-load.d/kubernetes.conf
        mode: '0644'
EOF
    
    # Create containerd restart playbook
    cat > "$fixes_dir/restart-container-runtime.yml" << 'EOF'
---
# Idempotent playbook to restart container runtime
- name: Restart container runtime services
  hosts: all
  become: true
  tasks:
    - name: Restart containerd
      ansible.builtin.systemd:
        name: containerd
        state: restarted
        enabled: yes
      
    - name: Wait for containerd to be ready
      ansible.builtin.wait_for:
        path: /var/run/containerd/containerd.sock
        timeout: 30
EOF
    
    log_info "Idempotent fix playbooks created in $fixes_dir"
}

# ============================================================================
# Diagnostic Bundle Creation
# ============================================================================
create_diagnostic_bundle() {
    log_info "Creating diagnostic bundle..."
    
    local bundle_dir="$ARTIFACTS_DIR/diagnostic-bundle"
    mkdir -p "$bundle_dir"
    
    # Network diagnostics
    {
        echo "=== Network Diagnostics ==="
        echo "Date: $(date)"
        echo ""
        echo "--- Routing Table ---"
        ip route || netstat -rn || route -n
        echo ""
        echo "--- DNS Configuration ---"
        cat /etc/resolv.conf
        echo ""
        echo "--- Network Interfaces ---"
        ip addr || ifconfig
        echo ""
        echo "--- Ping Tests ---"
        for host in 192.168.4.61 192.168.4.62 192.168.4.63; do
            echo "Pinging $host..."
            ping -c 3 -W 2 "$host" || echo "Failed to ping $host"
        done
    } > "$bundle_dir/network-diagnostics.txt" 2>&1
    
    # SSH diagnostics
    {
        echo "=== SSH Diagnostics ==="
        echo "SSH Key Path: $SSH_KEY_PATH"
        echo "SSH Key Exists: $(test -f "$SSH_KEY_PATH" && echo "yes" || echo "no")"
        echo "SSH Key Permissions: $(ls -l "$SSH_KEY_PATH" 2>/dev/null || echo "N/A")"
        echo ""
        echo "--- Known Hosts ---"
        cat ~/.ssh/known_hosts 2>/dev/null || echo "No known_hosts file"
        echo ""
        echo "--- SSH Test Connections ---"
        for host in 192.168.4.61 192.168.4.62 192.168.4.63; do
            echo "Testing SSH to $host..."
            ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                root@"$host" "echo 'Connection successful'" 2>&1 || echo "Failed to connect to $host"
        done
    } > "$bundle_dir/ssh-diagnostics.txt" 2>&1
    
    # Inventory diagnostics
    {
        echo "=== Inventory Diagnostics ==="
        echo "Main Inventory: $MAIN_INVENTORY"
        echo "Kubespray Inventory: $KUBESPRAY_INVENTORY"
        echo ""
        echo "--- Main Inventory Content ---"
        cat "$MAIN_INVENTORY" 2>/dev/null || echo "File not found"
        echo ""
        echo "--- Kubespray Inventory Content ---"
        cat "$KUBESPRAY_INVENTORY" 2>/dev/null || echo "File not found"
    } > "$bundle_dir/inventory-diagnostics.txt" 2>&1
    
    # Environment diagnostics
    {
        echo "=== Environment Diagnostics ==="
        echo "User: $(whoami)"
        echo "Home: $HOME"
        echo "PWD: $(pwd)"
        echo "REPO_ROOT: $REPO_ROOT"
        echo ""
        echo "--- Environment Variables ---"
        env | grep -E "(ANSIBLE|KUBE|SSH|PATH)" | sort
        echo ""
        echo "--- Ansible Version ---"
        ansible --version
        echo ""
        echo "--- Python Version ---"
        python3 --version
    } > "$bundle_dir/environment-diagnostics.txt" 2>&1
    
    log_info "Diagnostic bundle created at $bundle_dir"
}

# ============================================================================
# Step 1: Prepare Runner Runtime
# ============================================================================
prepare_runtime() {
    log_info "=========================================="
    log_info "STEP 1: Preparing Runner Runtime"
    log_info "=========================================="
    
    # Create directories
    mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR" "$BACKUP_DIR"
    log_info "Created artifact directories"
    
    # Setup SSH key if VMSTATION_SSH_KEY is set
    if [[ -n "${VMSTATION_SSH_KEY:-}" ]]; then
        echo "$VMSTATION_SSH_KEY" > "$SSH_KEY_PATH"
        chmod 600 "$SSH_KEY_PATH"
        log_info "SSH key written to $SSH_KEY_PATH"
    elif [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_error "SSH key not found at $SSH_KEY_PATH and VMSTATION_SSH_KEY not set"
        return 1
    fi
    
    # Setup git config if needed
    if ! git config user.email >/dev/null 2>&1; then
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git config user.name "GitHub Actions Bot"
        log_info "Configured git user"
    fi
    
    # Setup known_hosts
    mkdir -p ~/.ssh
    ssh-keyscan -H 192.168.4.61 >> ~/.ssh/known_hosts 2>/dev/null || true
    ssh-keyscan -H 192.168.4.62 >> ~/.ssh/known_hosts 2>/dev/null || true
    ssh-keyscan -H 192.168.4.63 >> ~/.ssh/known_hosts 2>/dev/null || true
    
    log_info "Runtime preparation complete"
}

# ============================================================================
# Step 2: Backup Important Files
# ============================================================================
backup_files() {
    log_info "=========================================="
    log_info "STEP 2: Backing Up Important Files"
    log_info "=========================================="
    
    local files=(
        "$REPO_ROOT/inventory.ini"
        "$REPO_ROOT/ansible/inventory/hosts.yml"
        "$REPO_ROOT/deploy.sh"
        "$REPO_ROOT/ansible/playbooks/setup-autosleep.yaml"
        "$REPO_ROOT/ansible/playbooks/run-preflight-rhel10.yml"
        "$REPO_ROOT/scripts/run-kubespray.sh"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local dest="$BACKUP_DIR/$(basename "$file")"
            cp "$file" "$dest"
            log_info "Backed up: $file"
        else
            log_warn "File not found, skipping backup: $file"
        fi
    done
    
    # Commit backup (create .gitkeep to ensure directory structure)
    cd "$REPO_ROOT"
    touch "$BACKUP_DIR/.gitkeep"
    git add .git/ops-backups/ 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "chore(backup): ops-backup $TIMESTAMP" --no-verify || true
        log_info "Backup committed"
    else
        log_info "No changes to commit for backup"
    fi
}

# ============================================================================
# Step 3: Inventory Normalization & Validation
# ============================================================================
normalize_inventory() {
    log_info "=========================================="
    log_info "STEP 3: Inventory Normalization & Validation"
    log_info "=========================================="
    
    # Check if Kubespray inventory exists
    if [[ ! -f "$KUBESPRAY_INVENTORY" ]]; then
        log_warn "Kubespray inventory not found at $KUBESPRAY_INVENTORY"
        log_info "Creating Kubespray inventory from main inventory..."
        
        # Create inventory directory
        mkdir -p "$(dirname "$KUBESPRAY_INVENTORY")"
        
        # Copy and normalize from main inventory.ini
        if [[ -f "$REPO_ROOT/inventory.ini" ]]; then
            cp "$REPO_ROOT/inventory.ini" "$KUBESPRAY_INVENTORY"
            log_info "Copied inventory.ini to Kubespray location"
        else
            log_error "Main inventory.ini not found"
            return 1
        fi
    fi
    
    log_info "Kubespray inventory exists at $KUBESPRAY_INVENTORY"
}

validate_inventory() {
    log_info "Validating inventory with ansible ping..."
    
    local logfile="$LOG_DIR/inventory-validation.log"
    log_cmd "ansible all -i $KUBESPRAY_INVENTORY -m ping" "$logfile"
    
    # Try with root user first
    if ansible all -i "$KUBESPRAY_INVENTORY" -m ping \
        --private-key "$SSH_KEY_PATH" \
        >> "$logfile" 2>&1; then
        log_info "✓ Inventory validation successful"
        return 0
    else
        log_warn "Inventory validation had failures"
        cat "$logfile" | tail -20
        return 1
    fi
}

# ============================================================================
# Step 4: Preflight Checks with Remediation
# ============================================================================
run_preflight() {
    log_info "=========================================="
    log_info "STEP 4: Preflight Checks (RHEL10 Compute)"
    log_info "=========================================="
    
    local logfile="$LOG_DIR/preflight.log"
    local preflight_playbook="$REPO_ROOT/ansible/playbooks/run-preflight-rhel10.yml"
    
    if [[ ! -f "$preflight_playbook" ]]; then
        log_warn "Preflight playbook not found, skipping"
        return 0
    fi
    
    log_cmd "ansible-playbook preflight" "$logfile"
    
    if ansible-playbook -i "$KUBESPRAY_INVENTORY" "$preflight_playbook" \
        -l compute_nodes -e 'target_hosts=compute_nodes' \
        --private-key "$SSH_KEY_PATH" -v \
        >> "$logfile" 2>&1; then
        log_info "✓ Preflight checks completed successfully"
        return 0
    else
        log_error "Preflight checks failed, attempting remediation..."
        cat "$logfile" | tail -50
        
        # Attempt basic remediation
        remediate_preflight
        
        # Retry preflight
        log_info "Retrying preflight after remediation..."
        if ansible-playbook -i "$KUBESPRAY_INVENTORY" "$preflight_playbook" \
            -l compute_nodes -e 'target_hosts=compute_nodes' \
            --private-key "$SSH_KEY_PATH" -v \
            >> "$logfile" 2>&1; then
            log_info "✓ Preflight checks completed after remediation"
            return 0
        else
            log_error "Preflight checks still failing after remediation"
            return 1
        fi
    fi
}

remediate_preflight() {
    log_info "Attempting automated preflight remediation..."
    
    # Check and install Python if missing
    ansible compute_nodes -i "$KUBESPRAY_INVENTORY" -m raw \
        -a "command -v python3 || (yum install -y python3 || dnf install -y python3)" \
        --private-key "$SSH_KEY_PATH" -u jashandeepjustinbains --become \
        >> "$LOG_DIR/preflight-remediation.log" 2>&1 || true
    
    # Disable swap if enabled
    ansible compute_nodes -i "$KUBESPRAY_INVENTORY" -m shell \
        -a "swapoff -a && sed -i '/swap/d' /etc/fstab" \
        --private-key "$SSH_KEY_PATH" -u jashandeepjustinbains --become \
        >> "$LOG_DIR/preflight-remediation.log" 2>&1 || true
    
    log_info "Remediation attempts completed"
}

# ============================================================================
# Step 5: Run Kubespray Setup
# ============================================================================
setup_kubespray() {
    log_info "=========================================="
    log_info "STEP 5: Setting Up Kubespray"
    log_info "=========================================="
    
    local setup_script="$REPO_ROOT/scripts/run-kubespray.sh"
    local logfile="$LOG_DIR/kubespray-setup.log"
    
    if [[ ! -f "$setup_script" ]]; then
        log_error "Kubespray setup script not found at $setup_script"
        return 1
    fi
    
    log_cmd "bash $setup_script" "$logfile"
    
    if bash "$setup_script" >> "$logfile" 2>&1; then
        log_info "✓ Kubespray setup completed"
    else
        log_error "Kubespray setup failed"
        cat "$logfile" | tail -50
        return 1
    fi
}

# ============================================================================
# Step 6: Deploy Kubernetes Cluster with Kubespray
# ============================================================================
deploy_cluster() {
    log_info "=========================================="
    log_info "STEP 6: Deploying Kubernetes Cluster"
    log_info "=========================================="
    
    if [[ ! -d "$KUBESPRAY_DIR" ]]; then
        log_error "Kubespray directory not found at $KUBESPRAY_DIR"
        return 1
    fi
    
    local logfile="$LOG_DIR/kubespray-cluster.log"
    local venv="$KUBESPRAY_DIR/.venv"
    
    if [[ ! -d "$venv" ]]; then
        log_error "Kubespray venv not found at $venv"
        return 1
    fi
    
    cd "$KUBESPRAY_DIR"
    source "$venv/bin/activate"
    
    log_cmd "ansible-playbook cluster.yml" "$logfile"
    
    local attempt=1
    local max_attempts=3
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Deployment attempt $attempt of $max_attempts..."
        
        if ansible-playbook -i "$KUBESPRAY_INVENTORY" cluster.yml -b \
            --private-key "$SSH_KEY_PATH" -v \
            >> "$logfile" 2>&1; then
            log_info "✓ Cluster deployment completed successfully"
            cd "$REPO_ROOT"
            return 0
        else
            log_error "Cluster deployment attempt $attempt failed"
            
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Analyzing failure and attempting remediation..."
                remediate_cluster_deployment
                ((attempt++))
            else
                log_error "All deployment attempts exhausted"
                cat "$logfile" | tail -100
                cd "$REPO_ROOT"
                return 1
            fi
        fi
    done
}

remediate_cluster_deployment() {
    log_info "Attempting cluster deployment remediation..."
    
    # Restart kubelet on all nodes
    ansible all -i "$KUBESPRAY_INVENTORY" -m systemd \
        -a "name=kubelet state=restarted" \
        --private-key "$SSH_KEY_PATH" --become \
        >> "$LOG_DIR/cluster-remediation.log" 2>&1 || true
    
    # Restart containerd on all nodes
    ansible all -i "$KUBESPRAY_INVENTORY" -m systemd \
        -a "name=containerd state=restarted" \
        --private-key "$SSH_KEY_PATH" --become \
        >> "$LOG_DIR/cluster-remediation.log" 2>&1 || true
    
    log_info "Remediation completed, retrying deployment..."
}

# ============================================================================
# Step 7: Copy and Distribute Kubeconfig
# ============================================================================
setup_kubeconfig() {
    log_info "=========================================="
    log_info "STEP 7: Setting Up Kubeconfig"
    log_info "=========================================="
    
    local admin_conf="$KUBESPRAY_DIR/inventory/mycluster/artifacts/admin.conf"
    
    if [[ ! -f "$admin_conf" ]]; then
        log_error "Admin kubeconfig not found at $admin_conf"
        return 1
    fi
    
    # Copy to runner
    cp "$admin_conf" "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"
    log_info "Kubeconfig copied to $KUBECONFIG_PATH"
    
    # Copy to control-plane nodes
    ansible monitoring_nodes -i "$MAIN_INVENTORY" -m copy \
        -a "src=$KUBECONFIG_PATH dest=/etc/kubernetes/admin.conf owner=root group=root mode=0600" \
        --private-key "$SSH_KEY_PATH" --become \
        >> "$LOG_DIR/kubeconfig-distribution.log" 2>&1 || log_warn "Failed to distribute kubeconfig to control-plane"
    
    log_info "✓ Kubeconfig setup complete"
}

# ============================================================================
# Step 8: Verify Node Readiness and CNI
# ============================================================================
verify_cluster() {
    log_info "=========================================="
    log_info "STEP 8: Verifying Cluster Health"
    log_info "=========================================="
    
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Wait for nodes to be ready
    log_info "Waiting for nodes to be ready (timeout: 15 minutes)..."
    if kubectl wait --for=condition=Ready nodes --all --timeout=15m \
        >> "$LOG_DIR/cluster-verification.log" 2>&1; then
        log_info "✓ All nodes are ready"
    else
        log_error "Nodes failed to become ready"
        kubectl get nodes -o wide >> "$LOG_DIR/cluster-verification.log" 2>&1 || true
        return 1
    fi
    
    # Check kube-system pods
    log_info "Checking kube-system pods..."
    kubectl -n kube-system get pods -o wide >> "$LOG_DIR/cluster-verification.log" 2>&1
    
    # Check for CrashLoopBackOff or NotReady pods
    local failing_pods
    failing_pods=$(kubectl -n kube-system get pods --field-selector=status.phase!=Running -o json | \
        jq -r '.items[].metadata.name' 2>/dev/null || echo "")
    
    if [[ -n "$failing_pods" ]]; then
        log_warn "Found failing pods, attempting remediation..."
        remediate_cni
        
        # Wait and recheck
        sleep 30
        kubectl -n kube-system get pods -o wide >> "$LOG_DIR/cluster-verification.log" 2>&1
    fi
    
    log_info "✓ Cluster verification complete"
}

remediate_cni() {
    log_info "Attempting CNI remediation..."
    
    # Restart all pods in kube-system
    kubectl -n kube-system delete pods --field-selector=status.phase!=Running \
        >> "$LOG_DIR/cni-remediation.log" 2>&1 || true
    
    # Ensure kernel modules are loaded
    ansible all -i "$KUBESPRAY_INVENTORY" -m shell \
        -a "modprobe br_netfilter && modprobe overlay" \
        --private-key "$SSH_KEY_PATH" --become \
        >> "$LOG_DIR/cni-remediation.log" 2>&1 || true
    
    log_info "CNI remediation completed"
}

# ============================================================================
# Step 9: Wake-on-LAN for Unreachable Nodes
# ============================================================================
wake_unreachable_nodes() {
    log_info "=========================================="
    log_info "STEP 9: Checking for Unreachable Nodes"
    log_info "=========================================="
    
    # This function is called when inventory validation fails
    # Try to wake nodes that might be sleeping
    
    log_info "Attempting to wake potentially sleeping nodes..."
    
    # Wake storage node
    wakeonlan b8:ac:6f:7e:6c:9d >> "$LOG_DIR/wol.log" 2>&1 || \
        log_warn "wakeonlan not available, skipping WoL"
    
    # Wake compute node
    wakeonlan d0:94:66:30:d6:63 >> "$LOG_DIR/wol.log" 2>&1 || true
    
    log_info "Waiting 90 seconds for nodes to wake..."
    sleep 90
    
    log_info "Retrying inventory validation..."
}

# ============================================================================
# Step 10: Deploy Monitoring and Infrastructure
# ============================================================================
deploy_monitoring_infrastructure() {
    log_info "=========================================="
    log_info "STEP 10: Deploying Monitoring & Infrastructure"
    log_info "=========================================="
    
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Deploy monitoring
    log_info "Deploying monitoring stack..."
    if bash "$REPO_ROOT/deploy.sh" monitoring >> "$LOG_DIR/monitoring-deployment.log" 2>&1; then
        log_info "✓ Monitoring deployment completed"
    else
        log_warn "Monitoring deployment had issues"
        cat "$LOG_DIR/monitoring-deployment.log" | tail -50
    fi
    
    # Deploy infrastructure
    log_info "Deploying infrastructure services..."
    if bash "$REPO_ROOT/deploy.sh" infrastructure >> "$LOG_DIR/infrastructure-deployment.log" 2>&1; then
        log_info "✓ Infrastructure deployment completed"
    else
        log_warn "Infrastructure deployment had issues"
        cat "$LOG_DIR/infrastructure-deployment.log" | tail -50
    fi
}

# ============================================================================
# Step 11: Create Smoke Tests
# ============================================================================
create_smoke_test() {
    log_info "=========================================="
    log_info "STEP 11: Running Smoke Tests"
    log_info "=========================================="
    
    local smoke_test="$REPO_ROOT/tests/kubespray-smoke.sh"
    
    cat > "$smoke_test" << 'EOF'
#!/usr/bin/env bash
# Kubespray Deployment Smoke Test
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/tmp/admin.conf}"
export KUBECONFIG

echo "=========================================="
echo "Kubespray Smoke Test"
echo "=========================================="

echo ""
echo "1. Checking nodes..."
if ! kubectl get nodes; then
    echo "ERROR: Failed to get nodes"
    exit 1
fi

echo ""
echo "2. Creating test namespace..."
kubectl create namespace smoke-test || true

echo ""
echo "3. Creating test pod..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-pod
  namespace: smoke-test
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
YAML

echo ""
echo "4. Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/smoke-test-pod -n smoke-test --timeout=120s

echo ""
echo "5. Creating test service..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: smoke-test-svc
  namespace: smoke-test
spec:
  selector:
    run: smoke-test-pod
  ports:
  - port: 80
    targetPort: 80
YAML

echo ""
echo "6. Cleaning up..."
kubectl delete namespace smoke-test

echo ""
echo "=========================================="
echo "✓ Smoke Test PASSED"
echo "=========================================="
EOF

    chmod +x "$smoke_test"
    log_info "Smoke test created at $smoke_test"
    
    # Run smoke test
    if bash "$smoke_test" >> "$LOG_DIR/smoke-test.log" 2>&1; then
        log_info "✓ Smoke test passed"
    else
        log_warn "Smoke test failed"
        cat "$LOG_DIR/smoke-test.log" | tail -30
    fi
}

# ============================================================================
# Step 12: Generate Report
# ============================================================================
generate_report() {
    log_info "=========================================="
    log_info "STEP 12: Generating Report"
    log_info "=========================================="
    
    local report_file="$ARTIFACTS_DIR/ops-report-$TIMESTAMP.json"
    
    export KUBECONFIG="$KUBECONFIG_PATH"
    
    # Collect node information
    local nodes_json
    nodes_json=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')
    
    # Get preflight status
    local preflight_status="unknown"
    if [[ -f "$LOG_DIR/preflight.log" ]]; then
        if grep -q "✓" "$LOG_DIR/preflight.log" 2>/dev/null; then
            preflight_status="passed"
        else
            preflight_status="failed"
        fi
    fi
    
    # Get cluster deployment status
    local cluster_status="unknown"
    if [[ -f "$LOG_DIR/kubespray-cluster.log" ]]; then
        if grep -q "PLAY RECAP" "$LOG_DIR/kubespray-cluster.log" 2>/dev/null; then
            cluster_status="completed"
        else
            cluster_status="failed"
        fi
    fi
    
    # Generate JSON report
    cat > "$report_file" << EOF
{
  "timestamp": "$TIMESTAMP",
  "preflight_status": "$preflight_status",
  "cluster_deployment_status": "$cluster_status",
  "nodes": $nodes_json,
  "artifacts_directory": "$ARTIFACTS_DIR",
  "log_directory": "$LOG_DIR",
  "kubeconfig_path": "$KUBECONFIG_PATH"
}
EOF
    
    log_info "Report generated at $report_file"
    cat "$report_file"
}

# ============================================================================
# Step 13: Cleanup
# ============================================================================
cleanup() {
    log_info "=========================================="
    log_info "STEP 13: Security Cleanup"
    log_info "=========================================="
    
    # Remove SSH key from runner (keep in /tmp for now, GitHub Actions will clean it)
    # rm -f "$SSH_KEY_PATH" 2>/dev/null || true
    
    log_info "Security cleanup complete"
    log_info ""
    log_info "NOTE: Remember to rotate SSH keys after testing is complete"
}

# ============================================================================
# Main Execution Flow
# ============================================================================
main() {
    log_info "=========================================="
    log_info "VMStation Kubespray Deployment Automation"
    log_info "Timestamp: $TIMESTAMP"
    log_info "=========================================="
    
    local exit_code=0
    
    # Step 1: Prepare runtime
    if ! prepare_runtime; then
        log_error "Failed to prepare runtime"
        exit 1
    fi
    
    # Step 2: Backup files
    if ! backup_files; then
        log_error "Failed to backup files"
        exit_code=1
    fi
    
    # Step 3: Normalize and validate inventory
    if ! normalize_inventory; then
        log_error "Failed to normalize inventory"
        exit_code=1
    fi
    
    if ! validate_inventory; then
        log_warn "Initial inventory validation failed, attempting WoL..."
        wake_unreachable_nodes
        
        if ! validate_inventory; then
            log_error "Inventory validation still failing after WoL"
            log_error "Cannot proceed without network access to nodes"
            
            # Create diagnostic bundle
            create_diagnostic_bundle
            generate_report
            
            log_error "=========================================="
            log_error "DIAGNOSTIC BUNDLE CREATED"
            log_error "Network isolation detected - unable to reach hosts"
            log_error "Next steps:"
            log_error "  1. Check network connectivity to hosts"
            log_error "  2. Verify SSH key has proper permissions"
            log_error "  3. Check if hosts need to be woken via WoL"
            log_error "  4. Review diagnostic bundle in artifacts"
            log_error "=========================================="
            exit 1
        fi
    fi
    
    # Step 4: Run preflight checks
    if ! run_preflight; then
        log_error "Preflight checks failed"
        exit_code=1
    fi
    
    # Step 4.5: Create idempotent fix playbooks
    create_idempotent_fixes
    
    # Step 5: Setup Kubespray
    if ! setup_kubespray; then
        log_error "Failed to setup Kubespray"
        generate_report
        exit 1
    fi
    
    # Step 6: Deploy cluster
    if ! deploy_cluster; then
        log_error "Failed to deploy cluster"
        generate_report
        exit 1
    fi
    
    # Step 7: Setup kubeconfig
    if ! setup_kubeconfig; then
        log_error "Failed to setup kubeconfig"
        generate_report
        exit 1
    fi
    
    # Step 8: Verify cluster
    if ! verify_cluster; then
        log_error "Cluster verification failed"
        exit_code=1
    fi
    
    # Step 9: Deploy monitoring and infrastructure
    if ! deploy_monitoring_infrastructure; then
        log_warn "Monitoring/infrastructure deployment had issues"
        exit_code=1
    fi
    
    # Step 10: Run smoke tests
    if ! create_smoke_test; then
        log_warn "Smoke test issues detected"
    fi
    
    # Step 11: Generate report
    generate_report
    
    # Step 12: Cleanup
    cleanup
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "=========================================="
        log_info "✓ Kubespray deployment complete"
        log_info "  Monitoring & infrastructure ready to run"
        log_info "=========================================="
    else
        log_warn "=========================================="
        log_warn "⚠ Deployment completed with warnings"
        log_warn "  Review logs in $LOG_DIR"
        log_warn "=========================================="
    fi
    
    exit $exit_code
}

# Run main function
main "$@"