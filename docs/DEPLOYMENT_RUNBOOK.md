# Identity Stack Deployment Runbook

This runbook provides step-by-step instructions for deploying the identity stack with automated network remediation and validation.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Pre-Deployment Validation](#pre-deployment-validation)
3. [Network Remediation Gate](#network-remediation-gate)
4. [Component Deployment](#component-deployment)
5. [Verification and Handover](#verification-and-handover)
6. [Emergency Procedures](#emergency-procedures)
7. [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Tools
- Ansible 2.9+
- kubectl configured with cluster access
- Python 3.8+
- Access to cluster nodes via SSH

### Required Environment Variables
```bash
export POSTGRES_PASSWORD="your-secure-password"
export KEYCLOAK_ADMIN_PASSWORD="your-secure-password"
export FREEIPA_ADMIN_PASSWORD="your-secure-password"
```

**Security Note**: Use Ansible Vault for production deployments:
```bash
ansible-vault create ansible/inventory/group_vars/secrets.yml
```

### Cluster Requirements
- Kubernetes 1.23+
- CoreDNS running
- kube-proxy functional
- At least 8GB RAM available for identity workloads
- Storage provisioner or manual PV creation

## Pre-Deployment Validation

### Step 1: Validate Cluster Health

Run the cluster validation playbook to ensure the cluster is ready:

```bash
ansible-playbook ansible/playbooks/01-validate-cluster.yml
```

This playbook checks:
- ✓ kubectl connectivity
- ✓ All nodes are Ready
- ✓ CoreDNS is running
- ✓ kube-proxy is functional
- ✓ Storage availability

**Expected Output:**
```
TASK [Validation summary] 
ok: [localhost] => {
    "msg": [
        "==========================================",
        "Cluster Validation: PASSED",
        ...
    ]
}
```

**If validation fails:**
- Fix node issues before proceeding
- Ensure kube-system pods are healthy
- Check CoreDNS and kube-proxy logs

## Network Remediation Gate

### Step 2: Run Network Remediation Gate

This is a **CRITICAL GATE** - do not proceed with identity deployment if this fails.

```bash
ansible-playbook ansible/playbooks/02-remediate-network-gate.yml
```

This playbook:
1. Tests pod→ClusterIP DNS connectivity
2. Automatically remediates common issues:
   - Enables `ip_forward`
   - Loads `br_netfilter` kernel module
   - Fixes iptables FORWARD chain
   - Clears stale IPVS state (if applicable)
   - Restarts kube-proxy if needed
3. Collects diagnostics if remediation fails
4. Provides actionable error messages

**Remediation attempts:** Up to 3 attempts with 10-second delays

**Expected Output (success):**
```
TASK [Network gate passed]
ok: [localhost] => {
    "msg": [
        "==========================================",
        "Network Remediation Gate: PASSED",
        ...
    ]
}
```

**If gate fails after 3 attempts:**
1. Check diagnostics: `/tmp/network-diagnostics/`
2. Review archived diagnostics: `/root/identity-backup/network-diagnostics-*.tar.gz`
3. See [Troubleshooting](#troubleshooting) section
4. Consider running emergency procedures (see below)

### Optional: Fix kube-proxy Service CIDR Mismatch

If you suspect kube-proxy is configured with the wrong service CIDR:

```bash
ansible-playbook ansible/playbooks/fix-kubeproxy-servicecidr.yml
```

This playbook:
- Detects `kube-apiserver --service-cluster-ip-range`
- Compares with kube-proxy ConfigMap `clusterCIDR`
- Backs up and patches ConfigMap if mismatched
- Restarts kube-proxy to reprogram rules

**Idempotent:** Safe to run multiple times.

### Optional: Clear IPVS State Manually

If IPVS state is causing issues and you're using iptables mode:

```bash
ansible-playbook ansible/playbooks/fix-ipvs.yml
```

**Warning:** This playbook restarts kube-proxy on all nodes.

## Component Deployment

### Step 3: Deploy PostgreSQL

```bash
ansible-playbook ansible/playbooks/03-deploy-db.yml
```

Deploys PostgreSQL StatefulSet for Keycloak backend.

**Validation:**
```bash
kubectl -n identity get pods -l app=postgresql
kubectl -n identity logs -l app=postgresql --tail=50
```

### Step 4: Deploy FreeIPA (Optional)

```bash
ansible-playbook ansible/playbooks/04-deploy-freeipa.yml
```

Deploys FreeIPA LDAP server. Can be skipped if you don't need LDAP integration.

**Note:** FreeIPA may take 10-15 minutes to initialize on first run.

**Validation:**
```bash
kubectl -n identity get pods -l app=freeipa
kubectl -n identity logs -l app=freeipa --tail=100
```

### Step 5: Deploy Keycloak with Automated Realm Import

```bash
ansible-playbook ansible/playbooks/05-deploy-keycloak.yml
```

Deploys Keycloak and automatically:
1. Waits for Keycloak to be ready
2. Imports realm configuration via Admin API
3. Configures LDAP federation (if FreeIPA deployed)
4. Sets up client credentials

**Validation:**
```bash
kubectl -n identity get pods -l app=keycloak
kubectl -n identity logs -l app=keycloak --tail=50
```

**Access Keycloak:**
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Keycloak URL: http://${NODE_IP}:30180"
echo "Username: admin"
echo "Password: $KEYCLOAK_ADMIN_PASSWORD"
```

## Verification and Handover

### Step 6: Verify Deployment

```bash
ansible-playbook ansible/playbooks/06-verify-and-handover.yml
```

This playbook:
- Verifies all components are running
- Generates deployment summary
- Saves handover documentation

**Verification checks:**
- PostgreSQL ready replicas
- Keycloak ready replicas
- FreeIPA ready replicas (if deployed)
- Pod status in identity namespace

### Step 7: Test Idempotency

Validate that deployments are idempotent:

```bash
ansible-playbook ansible/playbooks/test-idempotency.yml
```

This runs each deployment step twice and ensures no changes on second run.

## Emergency Procedures

### Emergency: Global IPVS/ipset Clear

**WARNING:** Use this only as a last resort when network remediation cannot fix IPVS issues.

This is **NOT** auto-applied. Requires explicit operator action.

#### Option 1: Manual IPVS Clear on All Nodes

```bash
ansible all -b -m shell -a "command -v ipvsadm && ipvsadm -C || echo 'ipvsadm not available'"
ansible-playbook ansible/playbooks/fix-ipvs.yml
```

#### Option 2: DaemonSet-based Emergency Clear (Future Enhancement)

A constrained emergency DaemonSet pattern can be added to clear IPVS/ipset globally:

```bash
# Enable emergency clear (add to inventory or pass as extra var)
emergency_clear_ipvs: true

# Run remediation with emergency mode
ansible-playbook ansible/playbooks/02-remediate-network-gate.yml -e emergency_clear_ipvs=true
```

**When to use:**
- kube-proxy switched from IPVS to iptables mode but IPVS state persists
- KUBE-SERVICES chain shows zero packet counters despite traffic
- Pod→ClusterIP connectivity broken after multiple remediation attempts

**What it does:**
- Flushes IPVS tables on all nodes
- Clears ipset entries (if needed)
- Restarts kube-proxy to reprogram iptables rules

## Troubleshooting

### Network Gate Fails After 3 Attempts

1. **Check diagnostics:**
   ```bash
   ls -lh /tmp/network-diagnostics/
   tar -tzf /root/identity-backup/network-diagnostics-*.tar.gz
   ```

2. **Review collected data:**
   - Cluster diagnostics: `cluster-diagnostics-*.txt`
   - Node diagnostics: `node-diagnostics-<hostname>-*.txt`
   - kube-proxy logs
   - CoreDNS logs
   - iptables rules
   - IPVS tables (if applicable)

3. **Common issues and fixes:**

   **Issue:** `net.ipv4.ip_forward = 0`
   ```bash
   ansible all -b -m sysctl -a "name=net.ipv4.ip_forward value=1 state=present sysctl_file=/etc/sysctl.d/k8s.conf reload=yes"
   ```

   **Issue:** `br_netfilter` module not loaded
   ```bash
   ansible all -b -m modprobe -a "name=br_netfilter state=present"
   ansible all -b -m lineinfile -a "path=/etc/modules-load.d/k8s.conf line=br_netfilter create=yes"
   ```

   **Issue:** iptables FORWARD policy DROP with no CNI rules
   ```bash
   kubectl -n kube-system rollout restart daemonset/calico-node
   kubectl -n kube-system rollout restart daemonset/kube-proxy
   ```

   **Issue:** KUBE-SERVICES chain has zero packet counters
   ```bash
   # Check for service CIDR mismatch
   ansible-playbook ansible/playbooks/fix-kubeproxy-servicecidr.yml
   
   # Or manually compare:
   kubectl -n kube-system get pod -l component=kube-apiserver -o yaml | grep service-cluster-ip-range
   kubectl -n kube-system get configmap kube-proxy -o yaml | grep clusterCIDR
   ```

### Pod→ClusterIP DNS Test Fails

**Symptoms:**
- DNS validation pod phase: Failed
- Logs show "connection timed out" or "no route to host"

**Diagnosis:**
```bash
# Check kube-dns service and endpoints
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpoints kube-dns

# Check CoreDNS pods
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Check kube-proxy mode and logs
kubectl -n kube-system get configmap kube-proxy -o yaml | grep mode
kubectl -n kube-system logs daemonset/kube-proxy --tail=200
```

**Fix:**
1. Ensure CoreDNS pods are Running and Ready
2. Verify kube-dns service has valid endpoints
3. Run network remediation gate again
4. Check iptables rules manually (see diagnostics)

### Keycloak Realm Import Fails

**Symptoms:**
- Keycloak deployed but realm not created
- SSO configuration errors

**Diagnosis:**
```bash
# Check Keycloak logs
kubectl -n identity logs deployment/keycloak --tail=200

# Check Keycloak health
kubectl -n identity exec deployment/keycloak -- curl -s http://localhost:8080/health/ready
```

**Fix:**
1. Verify Keycloak is fully started (check logs for "Keycloak.*started")
2. Ensure PostgreSQL is running and accessible
3. Re-run realm import:
   ```bash
   ansible-playbook ansible/playbooks/05-deploy-keycloak.yml --tags=sso
   ```

### FreeIPA Network Connectivity Issues

**Symptoms:**
- FreeIPA deployed but not reachable from nodes
- ipa-client-install fails

**Fix:**
See detailed troubleshooting in: `docs/NOTE_FREEIPA_NETWORKING.md`

Quick fixes:
1. Enable hostNetwork: `-e freeipa_enable_hostnetwork=true`
2. Open firewall: `-e identity_open_firewall=true`
3. Use socat for port forwarding (see docs)

## Rollback Procedures

### Rollback Keycloak

```bash
# Use backup ConfigMap
kubectl -n kube-system apply -f /root/identity-backup/kube-proxy-configmap-backup-*.yaml
kubectl -n kube-system rollout restart daemonset/kube-proxy
```

### Rollback Identity Stack

```bash
# Use backup script
bash scripts/reset-identity-stack.sh

# Or manual cleanup
kubectl delete namespace identity
```

### Restore from Backup

```bash
# Backups are in /root/identity-backup/
ls -lh /root/identity-backup/

# Restore specific backup
kubectl apply -f /root/identity-backup/identity-stack-backup-*.yaml
```

## Additional Resources

- [Automated Identity Deployment Guide](AUTOMATED-IDENTITY-DEPLOYMENT.md)
- [Identity SSO Setup](IDENTITY-SSO-SETUP.md)
- [Keycloak Integration](KEYCLOAK-INTEGRATION.md)
- [Network Issue Resolution](DEPLOYMENT_ISSUE_RESOLUTION_SUMMARY.md)

## Support

For issues not covered in this runbook:
1. Review diagnostics collected during deployment
2. Check GitHub issues in the repository
3. Consult Kubernetes and Keycloak documentation
4. Contact cluster administrator

---

**Document Version:** 1.0  
**Last Updated:** 2025-12-30  
**Maintained By:** VMStation Infrastructure Team
