# Control-Plane Taint Resolution for Identity Stack

## Problem Statement

Pods in the identity stack (PostgreSQL, FreeIPA, Keycloak) were unable to schedule on the masternode due to the Kubernetes control-plane taint:
```
node-role.kubernetes.io/control-plane:NoSchedule
```

The PersistentVolumes (PVs) have node affinity requiring the control-plane node, but pods couldn't schedule there because of the taint.

## Root Cause

Kubernetes control-plane nodes are tainted by default to prevent regular workloads from running on them. However, our identity stack components need to run on the control-plane node because:

1. The PVs use hostPath storage located at `/srv/monitoring-data/` on the control-plane node
2. The PV `nodeAffinity` explicitly requires `node-role.kubernetes.io/control-plane`
3. Running infrastructure services (identity, storage) on the control-plane is acceptable for single-node or small cluster setups

## Solution

The solution is to add tolerations to all pod specifications that need to run on the control-plane node. This allows pods to "tolerate" the control-plane taint and be scheduled there.

### Implemented Tolerations

All identity stack components now include the following toleration:

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

This toleration is implemented in:

1. **PostgreSQL StatefulSet** (`manifests/identity/postgresql-statefulset.yaml`)
   ```yaml
   spec:
     template:
       spec:
         nodeSelector:
           node-role.kubernetes.io/control-plane: ""
         tolerations:
         - key: node-role.kubernetes.io/control-plane
           operator: Exists
           effect: NoSchedule
   ```

2. **FreeIPA StatefulSet** (`manifests/identity/freeipa.yaml`)
   ```yaml
   spec:
     template:
       spec:
         nodeSelector:
           node-role.kubernetes.io/control-plane: ""
         tolerations:
         - key: node-role.kubernetes.io/control-plane
           operator: Exists
           effect: NoSchedule
   ```

3. **Keycloak Deployment** (via Helm values in `helm/keycloak-values.yaml`)
   ```yaml
   tolerations:
   - key: node-role.kubernetes.io/control-plane
     operator: Exists
     effect: NoSchedule
   ```

4. **cert-manager Components** (via Helm parameters in the playbook)
   ```bash
   helm upgrade --install cert-manager jetstack/cert-manager \
     --set tolerations[0].key=node-role.kubernetes.io/control-plane \
     --set tolerations[0].operator=Exists \
     --set tolerations[0].effect=NoSchedule
   ```

5. **Chown Jobs** (via templates)
   - `ansible/roles/identity-storage/templates/postgres-chown-job.yml.j2`
   - `ansible/roles/identity-storage/templates/freeipa-chown-job.yml.j2`

## Verification

To verify pods are now scheduling correctly on the control-plane node:

```bash
# Check node taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Check pod scheduling
kubectl get pods -n identity -o wide

# Verify PV bindings
kubectl get pv,pvc -n identity

# Check if pods tolerate the taint
kubectl get pod <pod-name> -n identity -o yaml | grep -A5 tolerations
```

Expected output should show:
- Pods running on the control-plane node
- PVCs bound to PVs
- No scheduling errors in pod events

## Alternative Solutions (Not Implemented)

While we chose to add tolerations, here are alternative approaches:

### 1. Remove the Taint (Not Recommended)
```bash
kubectl taint nodes <node-name> node-role.kubernetes.io/control-plane:NoSchedule-
```
**Downside:** Removes protection for the control-plane node, allowing any workload to schedule there.

### 2. Use a Dedicated Storage Node (Not Applicable)
Move the identity stack to a dedicated node without the control-plane taint.
**Downside:** Requires additional infrastructure and doesn't work for single-node setups.

### 3. Use Network Storage (Not Applicable)
Replace hostPath with network storage (NFS, Ceph, etc.)
**Downside:** Adds complexity and dependencies for a homelab/development setup.

## Best Practices

1. **Use nodeSelector + tolerations together:** This ensures pods can tolerate the taint AND prefer to schedule on the control-plane node.

2. **Document taint requirements:** Any new infrastructure component that needs to run on the control-plane should have tolerations documented.

3. **Test scheduling:** After adding new workloads, verify they schedule correctly:
   ```bash
   kubectl describe pod <pod-name> -n <namespace> | grep -A10 Events
   ```

4. **Monitor control-plane resources:** Since we're running workloads on the control-plane, monitor resource usage:
   ```bash
   kubectl top nodes
   kubectl top pods -n identity
   ```

## Note on Terminology

In this cluster:
- **masternode** and **control-plane** refer to the same node
- The label `node-role.kubernetes.io/control-plane` is used instead of the deprecated `node-role.kubernetes.io/master`
- The `nodeSelector` uses `node-role.kubernetes.io/control-plane: ""` (empty string value)

## References

- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Node Affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#affinity-and-anti-affinity)
- [Control Plane Node Label](https://kubernetes.io/docs/reference/labels-annotations-taints/#node-role-kubernetes-io-control-plane)
