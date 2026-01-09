# Identity Stack Scheduling Strategy

## Problem Statement

**Masternode**: Low TDP, cost-effective to run 24/7, but limited memory  
**Homelab Node**: High resources, but expensive to run continuously  

**Goal**: Keep masternode running constantly for control-plane duties, schedule resource-intensive workloads on homelab node only when needed.

## Scheduling Decisions

### Control-Plane Node (masternode) - Always On
**Schedule**: Lightweight, critical infrastructure
- Kubernetes control-plane components (kube-apiserver, etcd, scheduler, controller-manager)
- CoreDNS
- Kube-proxy
- Calico networking (if not using hostNetwork on all nodes)
- Small monitoring agents (node-exporter, promtail)

**Memory footprint**: ~1-2Gi

### Worker Node (homelab) - On-Demand
**Schedule**: Resource-intensive identity and monitoring workloads
- **FreeIPA**: 2-4Gi memory, CPU-intensive during install
- **Keycloak**: 1-2Gi memory
- **PostgreSQL** (Keycloak backend): 512Mi-1Gi memory
- **Grafana**: 512Mi-1Gi memory
- **Prometheus**: 2-4Gi memory (depends on retention)
- **Loki**: 1-2Gi memory

**Total memory footprint**: ~8-14Gi for full stack

## Implementation

### Current Configuration

#### FreeIPA (identity namespace)
```yaml
nodeSelector:
  node-role.kubernetes.io/worker: ""
# No tolerations needed for worker nodes
```

**Rationale**: FreeIPA is the most resource-intensive component (2-4Gi). Must run on homelab node.

#### Keycloak (identity namespace)
**Current**: Scheduled on control-plane via nodeSelector patch in Ansible role  
**Recommendation**: Move to worker node if masternode memory < 4Gi free

**To move Keycloak to worker**:
```yaml
nodeSelector:
  node-role.kubernetes.io/worker: ""
```

#### PostgreSQL (identity namespace)
**Current**: No explicit nodeSelector  
**Recommendation**: Add worker nodeSelector if memory constrained

**To move PostgreSQL to worker**:
```yaml
nodeSelector:
  node-role.kubernetes.io/worker: ""
```

### Node Labels

Ensure your homelab node has the worker role label:
```bash
kubectl label nodes homelab node-role.kubernetes.io/worker=
```

Verify labels:
```bash
kubectl get nodes --show-labels
```

### Storage Considerations

When scheduling on worker nodes, ensure storage paths exist:
```bash
# On homelab node
sudo mkdir -p /srv/monitoring-data/freeipa
sudo mkdir -p /srv/monitoring-data/postgresql
sudo chmod 755 /srv/monitoring-data
```

The PersistentVolume `nodeAffinity` now allows both worker and control-plane nodes, so storage will be created on whichever node the pod lands on.

## Cost Optimization Strategy

### Option 1: Manual Power Management (Recommended)
1. Keep masternode on 24/7 (control-plane duties)
2. **Power on homelab node only when using identity/monitoring services**
3. Use wake-on-LAN or IPMI to start homelab remotely
4. Power off homelab when not actively developing/monitoring

**Savings**: ~80% reduction in homelab runtime costs

### Option 2: Scheduled Power Management
1. Keep masternode on 24/7
2. Schedule homelab node:
   - Power ON: Weekdays 9am-6pm (during work hours)
   - Power OFF: Nights and weekends
3. Use cron + IPMI for automation

**Savings**: ~60% reduction in homelab runtime costs

### Option 3: Hybrid Scheduling (If Masternode Has 4-6Gi Free)
1. Schedule **only FreeIPA** on homelab (most resource-intensive)
2. Keep Keycloak, PostgreSQL on control-plane (smaller footprint)
3. Power on homelab only for FreeIPA operations (user/group creation, auth)

**Savings**: ~70% reduction, more flexibility

## Checking Available Resources

### Check node memory capacity
```bash
kubectl describe nodes masternode | grep -A 5 "Allocatable"
kubectl describe nodes homelab | grep -A 5 "Allocatable"
```

### Check current memory usage
```bash
kubectl top nodes
```

### Check pod resource requests/limits
```bash
kubectl -n identity get pods -o custom-columns=NAME:.metadata.name,MEMORY_REQ:.spec.containers[*].resources.requests.memory,MEMORY_LIMIT:.spec.containers[*].resources.limits.memory
```

## Ansible Playbook Updates Needed

### 1. Remove Keycloak control-plane patch (identity-keycloak role)

**File**: `ansible/roles/identity-keycloak/tasks/main.yml`

**Find**:
```yaml
- name: Patch Keycloak StatefulSet to schedule on control-plane node
```

**Change to**:
```yaml
- name: Patch Keycloak StatefulSet to schedule on worker node
  shell: >-
    kubectl --kubeconfig=/etc/kubernetes/admin.conf -n identity
    patch statefulset keycloak --type=json
    -p='[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"node-role.kubernetes.io/worker":""}}]'
```

### 2. Update PostgreSQL manifest (identity-postgresql role)

**File**: `ansible/roles/identity-postgresql/tasks/main.yml`

Add nodeSelector to StatefulSet template.

### 3. Update identity-storage role

**File**: `ansible/roles/identity-storage/tasks/main.yml`

Ensure storage directories are created on homelab node:
```yaml
- name: Create identity data directories on worker node
  file:
    path: "{{ item.path }}"
    state: directory
    mode: "{{ item.mode }}"
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
  loop:
    - { path: '/srv/monitoring-data/postgresql', mode: '0755', owner: '999', group: '999' }
    - { path: '/srv/monitoring-data/freeipa', mode: '0755', owner: 'root', group: 'root' }
  delegate_to: homelab  # Run on homelab node
  become: true
```

## Migration Steps

If identity stack is already deployed on masternode:

### 1. Delete existing FreeIPA pod
```bash
kubectl -n identity delete pod freeipa-0
```

### 2. Update PV nodeAffinity
```bash
kubectl delete pv freeipa-data-pv
kubectl apply -f /opt/vmstation-org/cluster-infra/manifests/identity/freeipa.yaml
```

### 3. Ensure homelab node is ready
```bash
# Label homelab as worker if not already
kubectl label nodes homelab node-role.kubernetes.io/worker= --overwrite

# Create storage directories on homelab
ssh homelab "sudo mkdir -p /srv/monitoring-data/freeipa /srv/monitoring-data/postgresql && sudo chmod 755 /srv/monitoring-data"
```

### 4. Redeploy identity stack
```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo ../scripts/identity-full-deploy.sh --force-reset --reset-confirm
```

### 5. Verify scheduling
```bash
kubectl -n identity get pods -o wide
```

Expected output:
```
NAME                         READY   STATUS    NODE
freeipa-0                    1/1     Running   homelab
keycloak-0                   1/1     Running   homelab (or masternode if not patched)
keycloak-postgresql-0        1/1     Running   homelab (or masternode)
oauth2-proxy-xxx             1/1     Running   masternode
```

## Troubleshooting

### Pod stuck in Pending state
```bash
kubectl -n identity describe pod <pod-name>
```

Look for:
- `0/X nodes are available: X Insufficient memory`
- `0/X nodes are available: X node(s) didn't match Pod's node affinity`

**Solution**: 
1. Verify node labels: `kubectl get nodes --show-labels`
2. Check available resources: `kubectl top nodes`
3. Adjust nodeSelector if needed

### Storage not binding
```bash
kubectl get pv,pvc -n identity
```

**Solution**:
1. Ensure storage path exists on scheduled node
2. PV nodeAffinity must match pod's nodeSelector
3. Delete PV and recreate: `kubectl delete pv <pv-name> && kubectl apply -f manifest`

## Recommended Final Configuration

**For cost optimization**:
- Masternode: Control-plane components only
- Homelab: All identity and monitoring workloads
- Power management: Homelab on-demand only

**Storage**: Create on homelab node only  
**Memory**: Masternode ~2Gi used, Homelab ~10-12Gi used  
**Cost savings**: Run homelab only during work hours = ~60-80% cost reduction
