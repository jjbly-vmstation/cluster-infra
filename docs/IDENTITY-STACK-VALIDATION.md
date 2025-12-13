# Identity Stack Validation Guide

This guide provides steps to validate the identity stack deployment after applying the pod scheduling and external access fixes.

## Overview of Changes

### 1. Keycloak Pod Scheduling
- **Issue**: Keycloak pods were scheduled on homelab node instead of masternode (control-plane)
- **Fix**: Moved `nodeSelector` and `tolerations` to root level in `helm/keycloak-values.yaml`
- **Expected Result**: Keycloak pods should be scheduled on control-plane nodes

### 2. FreeIPA External Access
- **Issue**: No NodePort service for external access to FreeIPA
- **Fix**: Added NodePort service in `manifests/identity/freeipa.yaml`
- **Expected Result**: FreeIPA accessible from desktop via NodePort

### 3. External Access Ports
- **Keycloak**: HTTP 30180, HTTPS 30543
- **FreeIPA**: HTTP 30088, HTTPS 30445, LDAP 30389, LDAPS 30636

## Validation Steps

### Prerequisites
```bash
# Ensure you have kubectl access to the cluster
kubectl cluster-info

# Verify identity namespace exists
kubectl get namespace identity
```

### Step 1: Verify Pod Scheduling

Check that all identity pods are running on control-plane nodes:

```bash
kubectl get pods -n identity -o wide
```

**Expected Output:**
```
NAME                        READY   STATUS    RESTARTS   AGE   IP              NODE         NOMINATED NODE   READINESS GATES
keycloak-0                  1/1     Running   0          Xm    10.233.X.X      masternode   <none>           <none>
keycloak-postgresql-0       1/1     Running   0          Xm    10.233.X.X      masternode   <none>           <none>
freeipa-0                   1/1     Running   0          Xm    10.233.X.X      masternode   <none>           <none>
```

**Key Points:**
- All pods should show `NODE` as `masternode` (or your control-plane node name)
- No pods should be on `homelab` or other worker nodes
- All pods should be in `Running` status

### Step 2: Verify StatefulSets

Check StatefulSet node affinity configuration:

```bash
# Keycloak
kubectl get statefulset keycloak -n identity -o jsonpath='{.spec.template.spec.nodeSelector}' | jq
kubectl get statefulset keycloak -n identity -o jsonpath='{.spec.template.spec.tolerations}' | jq

# PostgreSQL
kubectl get statefulset keycloak-postgresql -n identity -o jsonpath='{.spec.template.spec.nodeSelector}' | jq
kubectl get statefulset keycloak-postgresql -n identity -o jsonpath='{.spec.template.spec.tolerations}' | jq

# FreeIPA
kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.nodeSelector}' | jq
kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.tolerations}' | jq
```

**Expected Configuration:**
- `nodeSelector` should include `"node-role.kubernetes.io/control-plane": ""`
- `tolerations` should include toleration for `node-role.kubernetes.io/control-plane:NoSchedule`

### Step 3: Verify NodePort Services

Check that NodePort services are created:

```bash
kubectl get svc -n identity
```

**Expected Output:**
```
NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                                      AGE
keycloak-http          ClusterIP   10.233.X.X      <none>        80/TCP,8443/TCP                                              Xm
keycloak-nodeport      NodePort    10.233.X.X      <none>        80:30180/TCP,8443:30543/TCP                                  Xm
keycloak-postgresql    ClusterIP   10.233.X.X      <none>        5432/TCP                                                     Xm
freeipa                ClusterIP   10.233.X.X      <none>        80/TCP,443/TCP,389/TCP,636/TCP,88/TCP,88/UDP,464/TCP...     Xm
freeipa-nodeport       NodePort    10.233.X.X      <none>        80:30088/TCP,443:30445/TCP,389:30389/TCP,636:30636/TCP      Xm
```

**Key Points:**
- `keycloak-nodeport` service should exist with NodePort type
- `freeipa-nodeport` service should exist with NodePort type
- Port mappings should match expected values

### Step 4: Test External Access

Get the node IP address:

```bash
kubectl get nodes -o wide | grep masternode
```

Test Keycloak access:

```bash
# HTTP (from desktop/external machine)
curl -I http://<node-ip>:30180/auth
# Should return HTTP 200 or redirect to HTTPS

# HTTPS (from desktop/external machine)
curl -Ik https://<node-ip>:30543/auth
# Should return HTTP 200 or Keycloak response
```

Test FreeIPA access:

```bash
# HTTP (from desktop/external machine)
curl -I http://<node-ip>:30088
# Should return HTTP response or redirect

# HTTPS (from desktop/external machine)
curl -Ik https://<node-ip>:30445
# Should return HTTPS response (may have cert warning)

# LDAP connectivity test (requires ldapsearch)
ldapsearch -x -H ldap://<node-ip>:30389 -b "dc=vmstation,dc=local"
# Should return LDAP search results or connection confirmation
```

### Step 5: Verify Service Selectors

Ensure services are targeting the correct pods:

```bash
# Keycloak NodePort service selector
kubectl get svc keycloak-nodeport -n identity -o jsonpath='{.spec.selector}' | jq

# Expected: {"app.kubernetes.io/name": "keycloak"}

# FreeIPA NodePort service selector
kubectl get svc freeipa-nodeport -n identity -o jsonpath='{.spec.selector}' | jq

# Expected: {"app": "freeipa"}
```

Verify endpoints are populated:

```bash
kubectl get endpoints -n identity
```

**Expected Output:**
- Each NodePort service should have corresponding endpoints
- Endpoints should match pod IPs from Step 1

### Step 6: Check Logs

Review pod logs for any errors:

```bash
# Keycloak logs
kubectl logs keycloak-0 -n identity --tail=50

# PostgreSQL logs
kubectl logs keycloak-postgresql-0 -n identity --tail=50

# FreeIPA logs
kubectl logs freeipa-0 -n identity --tail=50
```

**Look for:**
- No error messages about database connectivity
- Keycloak startup completion messages
- FreeIPA service initialization completion

## Troubleshooting

### Pods Not Scheduled on Control-Plane

If pods are still on wrong nodes:

1. Check node labels:
   ```bash
   kubectl get nodes --show-labels | grep control-plane
   ```

2. Delete and recreate the pod to trigger rescheduling:
   ```bash
   kubectl delete pod <pod-name> -n identity
   # StatefulSet will automatically recreate it
   ```

3. Verify Helm values were applied:
   ```bash
   helm get values keycloak -n identity
   ```

### NodePort Services Not Accessible

If services are not reachable:

1. Check firewall rules on the node
2. Verify service is listening:
   ```bash
   kubectl get svc -n identity | grep NodePort
   ```

3. Check service endpoints:
   ```bash
   kubectl describe svc <service-name> -n identity
   ```

4. Test from within cluster first:
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- sh
   # From inside pod:
   curl http://keycloak-http.identity.svc.cluster.local
   ```

### Port Conflicts

If you see port allocation errors:

```bash
# Check all NodePort services in cluster
kubectl get svc --all-namespaces -o wide | grep NodePort

# Look for port conflicts in 30000-32767 range
```

## Success Criteria

✅ All identity pods running on control-plane node(s)
✅ Keycloak accessible via HTTP (30180) and HTTPS (30543)
✅ FreeIPA accessible via HTTP (30088), HTTPS (30445), LDAP (30389), LDAPS (30636)
✅ No error logs in pod containers
✅ Services have healthy endpoints
✅ StatefulSets have correct node affinity configuration

## Next Steps After Validation

1. Configure FreeIPA admin password and realm settings
2. Set up LDAP user federation in Keycloak
3. Create OIDC clients for cluster services (Grafana, Prometheus, etc.)
4. Configure DNS entries for `ipa.vmstation.local` and `keycloak.vmstation.local`
5. Set up TLS certificates for production use
6. Configure backup for identity data at `/srv/monitoring-data/`

## References

- [manifests/identity/README.md](../manifests/identity/README.md) - Identity stack manifest documentation
- [helm/keycloak-values.yaml](../helm/keycloak-values.yaml) - Keycloak Helm chart values
- [manifests/identity/freeipa.yaml](../manifests/identity/freeipa.yaml) - FreeIPA deployment manifest
- [ansible/playbooks/identity-deploy-and-handover.yml](../ansible/playbooks/identity-deploy-and-handover.yml) - Deployment playbook
