# Identity Stack Automation and Desktop Access Configuration
**Date:** 2025-12-10T17:56:47Z  
**Status:** IMPLEMENTED

## Summary
This document describes the automation added to the identity-deploy-and-handover.yml playbook to provide:
1. Automatic cert-manager pod placement on masternode
2. Keycloak admin user creation with secure password generation
3. Desktop network access to Keycloak via NodePort service
4. Secure credential storage for cluster recovery

---

## Issues Addressed

### 1. Cert-Manager Pod Misplacement
**Problem:** cert-manager-cainjector and cert-manager-webhook were running on homelab node instead of masternode.

**Root Cause:** The Helm chart only applies nodeSelector to the main controller deployment via `--set` flag. The cainjector and webhook inherit only the default `kubernetes.io/os=linux` selector.

**Solution:** Added explicit patches after Helm install to enforce nodeSelector on all cert-manager deployments.

**Implementation Location:** Lines 816-831 in identity-deploy-and-handover.yml

```yaml
- name: Patch cert-manager cainjector with nodeSelector for masternode
  shell: >-
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl patch deployment cert-manager-cainjector 
    -n {{ namespace_cert_manager }} 
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"{{ infra_node }}"}}}}}'

- name: Patch cert-manager webhook with nodeSelector for masternode
  shell: >-
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl patch deployment cert-manager-webhook 
    -n {{ namespace_cert_manager }} 
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"{{ infra_node }}"}}}}}'
```

**Verification:**
```bash
sudo kubectl get pods -n cert-manager -o wide
# All pods should show NODE=masternode
```

---

### 2. Keycloak Desktop Access
**Problem:** No ingress controller installed and no external access configured for Keycloak from desktop workstations.

**Solution:** Deploy NodePort service to expose Keycloak on ports 30080 (HTTP) and 30443 (HTTPS) on all cluster nodes.

**Implementation Location:** Lines 983-1023 in identity-deploy-and-handover.yml

**Service Configuration:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak-nodeport
  namespace: identity
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: 30080
    - name: https
      port: 8443
      targetPort: 8443
      nodePort: 30443
  selector:
    app.kubernetes.io/name: keycloak
```

**Desktop Access URLs:**
- `http://192.168.4.63:30080/auth` (masternode)
- `http://192.168.4.62:30080/auth` (homelab)
- `http://192.168.4.61:30080/auth` (storagenodet3500)

**Admin Console:**
- `http://<any-node-ip>:30080/auth/admin`

---

### 3. Keycloak Admin User Automation
**Problem:** Manual admin user creation required after deployment.

**Solution:** Automated admin user creation with secure password generation and credential storage.

**Implementation Location:** Lines 1025-1103 in identity-deploy-and-handover.yml

**Process:**
1. Generate secure 32-character base64 password (or use provided password)
2. Wait for Keycloak pod readiness
3. Check if admin user exists
4. Create admin user if not present using add-user-keycloak.sh
5. Restart Keycloak pod to activate admin user
6. Save credentials to `/root/identity-backup/keycloak-admin-credentials.txt`
7. Display access information

**Security Features:**
- Passwords generated using `openssl rand -base64 32`
- Credentials stored root-only (mode 0600) in `/root/identity-backup/`
- Idempotent - won't overwrite existing admin user
- Credentials displayed once during deployment for operator capture

---

## Files Created in diff-patches/

### 1. 20251210T175647Z-cert-manager-nodeSelector-fix.patch
Manual kubectl patches applied and automated in playbook.

**Contents:**
- Description of cert-manager pod placement issue
- Manual patch commands used
- Playbook automation code snippet
- Verification commands

**Apply manually (if needed):**
```bash
kubectl patch deployment cert-manager-cainjector -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"masternode"}}}}}'

kubectl patch deployment cert-manager-webhook -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"masternode"}}}}}'
```

### 2. 20251210T175647Z-keycloak-nodeport-service.yaml
NodePort service manifest for desktop access.

**Apply:**
```bash
kubectl apply -f /opt/vmstation-org/diff-patches/20251210T175647Z-keycloak-nodeport-service.yaml
```

**Verify:**
```bash
kubectl get svc -n identity keycloak-nodeport
curl -I http://<node-ip>:30080/auth
```

### 3. 20251210T175647Z-keycloak-admin-setup.sh
Standalone script for Keycloak admin user setup (backup/manual execution).

**Usage:**
```bash
sudo /opt/vmstation-org/diff-patches/20251210T175647Z-keycloak-admin-setup.sh

# With custom credentials
sudo KEYCLOAK_ADMIN_PASSWORD="your-password" \
  /opt/vmstation-org/diff-patches/20251210T175647Z-keycloak-admin-setup.sh
```

**Features:**
- Idempotent execution
- Automatic password generation
- Credential backup to `/root/identity-backup/`
- NodePort service deployment

### 4. 20251210T175647Z-IDENTITY-AUTOMATION.md (this file)
Comprehensive documentation of all changes.

---

## Playbook Modifications

### Added Variables
No new variables required. Uses existing:
- `namespace_identity` - Keycloak namespace
- `namespace_cert_manager` - cert-manager namespace
- `infra_node` - Control plane node for scheduling
- `backup_dir` - Credential storage location

### Optional Variables
Can be set when running playbook:
```bash
ansible-playbook identity-deploy-and-handover.yml \
  -e keycloak_admin_password="custom-password"
```

### Added Tasks (in order)
1. **Patch cert-manager cainjector** (line 816)
2. **Patch cert-manager webhook** (line 826)
3. **Deploy Keycloak NodePort Service** (line 988)
4. **Setup Keycloak admin user and desktop access** (line 1025)
   - Generate password
   - Wait for pod readiness
   - Check admin user existence
   - Create admin user
   - Restart Keycloak
   - Save credentials
   - Display access info

---

## Verification Steps

### 1. Verify Cert-Manager Pod Placement
```bash
sudo kubectl get pods -n cert-manager -o wide
```
**Expected:** All pods on `masternode`

### 2. Verify ClusterIssuer Handover
```bash
sudo kubectl get clusterissuers
```
**Expected:** `freeipa-ca-issuer` status: `Ready: True`

### 3. Verify Keycloak Service
```bash
sudo kubectl get svc -n identity keycloak-nodeport
```
**Expected:** NodePort service with ports 30080/30443

### 4. Verify Desktop Access
From desktop browser:
```
http://192.168.4.63:30080/auth
```
**Expected:** Keycloak welcome page

### 5. Verify Admin Credentials
```bash
sudo cat /root/identity-backup/keycloak-admin-credentials.txt
```
**Expected:** Username, password, and access URLs

### 6. Test Admin Login
1. Navigate to `http://192.168.4.63:30080/auth/admin`
2. Login with credentials from step 5
3. Verify access to Keycloak Admin Console

---

## Security Considerations

### Password Management
- **Generation:** `openssl rand -base64 32` provides cryptographically secure passwords
- **Storage:** Credentials stored in `/root/identity-backup/` with mode 0600
- **Transmission:** Passwords only displayed during playbook run for operator capture
- **Rotation:** Admin should change passwords via Keycloak UI after initial login

### Network Access
- **NodePort Range:** Uses standard K8s NodePort range (30000-32767)
- **Firewall:** Ensure desktop network has access to cluster node IPs on ports 30080/30443
- **TLS:** HTTP-only by default; production should use ingress with TLS termination

### Recommendations for Production
1. Replace NodePort with Ingress + TLS certificates
2. Use cert-manager to issue certificates from freeipa-ca-issuer
3. Configure Keycloak LDAP federation with FreeIPA
4. Enable RBAC and create non-admin users
5. Integrate with monitoring stack (Prometheus/Grafana)
6. Configure backup automation for PostgreSQL data

---

## Future Integration: Monitoring Stack

### Keycloak Metrics Exposure
Keycloak exposes metrics at `/auth/realms/master/metrics`

**Prometheus ServiceMonitor:**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keycloak
  namespace: identity
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: keycloak
  endpoints:
    - port: http
      path: /auth/realms/master/metrics
      interval: 30s
```

### Grafana Dashboard
Import Keycloak dashboard ID: 10441 (Keycloak Metrics)

**Datasource:** Prometheus from monitoring stack

### Alerting Rules
Example alerts for monitoring:
- Keycloak pod down
- High authentication failure rate
- Database connection issues
- Certificate expiration warnings

---

## Rollback Procedures

### Remove NodePort Service
```bash
kubectl delete svc keycloak-nodeport -n identity
```

### Remove Admin User
```bash
kubectl exec -n identity keycloak-0 -- \
  /opt/jboss/keycloak/bin/kcadm.sh delete users/<user-id> -r master
```

### Revert Cert-Manager Patches
```bash
# Reset to default nodeSelector
kubectl patch deployment cert-manager-cainjector -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'

kubectl patch deployment cert-manager-webhook -n cert-manager \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'
```

---

## Testing Checklist

- [ ] Cert-manager pods all on masternode
- [ ] ClusterIssuer freeipa-ca-issuer is Ready
- [ ] NodePort service exists and accessible
- [ ] Keycloak responds on http://<node-ip>:30080/auth
- [ ] Admin credentials saved to /root/identity-backup/
- [ ] Admin login successful via browser
- [ ] Can create test realm in Keycloak
- [ ] Can create test user in Keycloak
- [ ] Credentials file has correct permissions (0600)
- [ ] Playbook is idempotent (safe to re-run)

---

## Related Documentation
- `/opt/vmstation-org/cluster-infra/ansible/playbooks/identity-deploy-and-handover.yml` - Main playbook
- `/opt/vmstation-org/cluster-infra/helm/keycloak-values.yaml` - Keycloak Helm values
- `/opt/vmstation-org/diff-patches/20251210-DEPLOYMENT-GUIDE.md` - Deployment guide
- `/root/identity-backup/` - Backup and credentials storage

---

## Support and Troubleshooting

### Common Issues

**Issue:** Admin login fails  
**Solution:** Check credentials in `/root/identity-backup/keycloak-admin-credentials.txt`

**Issue:** Cannot access from desktop  
**Solution:** Verify firewall rules allow desktop → cluster on ports 30080/30443

**Issue:** Pods still on wrong node  
**Solution:** Delete pods to trigger rescheduling with new nodeSelector

**Issue:** Keycloak pod not ready  
**Solution:** Check logs: `kubectl logs -n identity keycloak-0 --tail=100`

### Debug Commands
```bash
# Check all identity stack
sudo kubectl get all -n identity -o wide

# Check cert-manager
sudo kubectl get all -n cert-manager -o wide

# View Keycloak logs
sudo kubectl logs -n identity keycloak-0 --tail=100

# View PostgreSQL logs
sudo kubectl logs -n identity keycloak-postgresql-0 --tail=100

# Check events
sudo kubectl get events -n identity --sort-by='.lastTimestamp'
```

---

**Document Version:** 1.0  
**Last Updated:** 2025-12-10T17:56:47Z  
**Maintainer:** Cluster Operations Team
