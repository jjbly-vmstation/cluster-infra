# VMStation Cluster Deployment Sequence

This document outlines the complete deployment sequence for the VMStation Kubernetes cluster, including infrastructure services, identity management, and monitoring stack.

## Overview

The deployment follows a modular, phased approach to ensure reliability and maintainability:

1. **Steps 1-3**: Identity Stack Foundation (FreeIPA, Keycloak, PostgreSQL)
2. **Step 4a**: DNS and Network Configuration ← **Current Step**
3. **Step 4b-6**: Infrastructure Services and Monitoring
4. **Step 7+**: Application Deployment

## Prerequisites

- Kubernetes cluster deployed and running
- kubectl access configured (`/etc/kubernetes/admin.conf`)
- Ansible 2.9+ installed
- SSH access to all cluster nodes
- Canonical inventory file at `/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`

## Deployment Steps

### Steps 1-3: Identity Stack Deployment

**Status**: ✅ Completed

Deploy FreeIPA, Keycloak, PostgreSQL, and cert-manager:

```bash
cd /path/to/cluster-infra
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

**Components Deployed**:
- PostgreSQL StatefulSet (database for Keycloak)
- Keycloak StatefulSet (SSO and OIDC provider)
- FreeIPA StatefulSet (LDAP, Kerberos, CA)
- cert-manager (automated TLS certificates)
- Administrator accounts and credentials

**Verification**:
```bash
./scripts/verify-identity-deployment.sh
kubectl get pods -n identity
kubectl get pods -n cert-manager
```

**Documentation**: See [IDENTITY-SSO-SETUP.md](IDENTITY-SSO-SETUP.md)

---

### Step 4a: Configure DNS Records and Network Ports

**Status**: 🔄 Current Step

After completing the identity stack deployment, configure DNS records and network ports to enable proper communication between cluster nodes, FreeIPA, Keycloak, and clients.

#### Requirements

1. **DNS Records**
   - Extract DNS records from FreeIPA pod
   - Distribute to all cluster nodes
   - Ensure `ipa.vmstation.local` resolves correctly
   - Add records to `/etc/hosts` on all nodes

2. **Network Ports**
   - Configure firewall rules for required ports
   - Ensure SSH (port 22) remains open and unrestricted
   - Support both firewalld (RHEL 10) and iptables (Debian 12)

#### Required Ports

**TCP Ports**:
- 22: SSH (must always be open and unrestricted)
- 80, 443: HTTP/HTTPS
- 389, 636: LDAP/LDAPS
- 88, 464: Kerberos
- 53: DNS (if used)

**UDP Ports**:
- 88, 464: Kerberos
- 53: DNS (if used)

#### Automated Deployment

**Option 1: Full Ansible Playbook** (Recommended)
```bash
cd /path/to/cluster-infra
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml
```

**Option 2: Individual Scripts**
```bash
# 1. Extract DNS records from FreeIPA
./scripts/extract-freeipa-dns-records.sh -v

# 2. Configure DNS records on all nodes
./scripts/configure-dns-records.sh

# 3. Configure firewall rules
./scripts/configure-network-ports.sh

# 4. Verify configuration
./scripts/verify-network-ports.sh
./scripts/verify-freeipa-keycloak-readiness.sh
```

#### Manual Deployment

If you prefer manual configuration or need to troubleshoot:

1. **Extract DNS Records**
   ```bash
   kubectl -n identity exec freeipa-0 -- \
     find /tmp -name "ipa.system.records.*.db" -exec cat {} \;
   ```

2. **Add to /etc/hosts on Each Node**
   ```bash
   # Add these lines to /etc/hosts on all nodes:
   192.168.4.63    ipa.vmstation.local ipa
   192.168.4.63    vmstation.local
   ```

3. **Configure Firewall (RHEL 10 - firewalld)**
   ```bash
   # Add TCP ports
   sudo firewall-cmd --permanent --add-port=22/tcp
   sudo firewall-cmd --permanent --add-port=80/tcp
   sudo firewall-cmd --permanent --add-port=443/tcp
   sudo firewall-cmd --permanent --add-port=389/tcp
   sudo firewall-cmd --permanent --add-port=636/tcp
   sudo firewall-cmd --permanent --add-port=88/tcp
   sudo firewall-cmd --permanent --add-port=464/tcp
   
   # Add UDP ports
   sudo firewall-cmd --permanent --add-port=88/udp
   sudo firewall-cmd --permanent --add-port=464/udp
   
   # Add services
   sudo firewall-cmd --permanent --add-service=ssh
   sudo firewall-cmd --permanent --add-service=http
   sudo firewall-cmd --permanent --add-service=https
   sudo firewall-cmd --permanent --add-service=ldap
   sudo firewall-cmd --permanent --add-service=ldaps
   sudo firewall-cmd --permanent --add-service=kerberos
   
   # Trust cluster subnets
   sudo firewall-cmd --permanent --add-source=192.168.4.0/24
   sudo firewall-cmd --permanent --add-source=10.244.0.0/16
   sudo firewall-cmd --permanent --add-source=10.96.0.0/12
   
   # Reload
   sudo firewall-cmd --reload
   ```

4. **Configure Firewall (Debian 12 - iptables)**
   ```bash
   # Install iptables-persistent
   sudo apt-get install -y iptables-persistent
   
   # Add TCP ports
   sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 389 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 636 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 88 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 464 -j ACCEPT
   
   # Add UDP ports
   sudo iptables -A INPUT -p udp --dport 88 -j ACCEPT
   sudo iptables -A INPUT -p udp --dport 464 -j ACCEPT
   
   # Allow cluster subnets
   sudo iptables -A INPUT -s 192.168.4.0/24 -j ACCEPT
   sudo iptables -A INPUT -s 10.244.0.0/16 -j ACCEPT
   sudo iptables -A INPUT -s 10.96.0.0/12 -j ACCEPT
   
   # Save rules
   sudo iptables-save > /etc/iptables/rules.v4
   ```

#### Verification

Run the verification scripts to ensure everything is configured correctly:

```bash
# Verify network ports
./scripts/verify-network-ports.sh

# Verify FreeIPA and Keycloak readiness
./scripts/verify-freeipa-keycloak-readiness.sh
```

**Expected Results**:
- ✅ DNS resolution: `ipa.vmstation.local` resolves to `192.168.4.63`
- ✅ All required ports are accessible
- ✅ FreeIPA pod is Running and Ready (1/1)
- ✅ Keycloak pod is Running and Ready (1/1)
- ✅ FreeIPA web UI is accessible: https://192.168.4.63:30445/ipa/ui
- ✅ Keycloak admin console is accessible: http://192.168.4.63:30180/auth/admin/

#### Troubleshooting

**DNS Not Resolving**:
```bash
# Check /etc/hosts
cat /etc/hosts | grep ipa.vmstation.local

# Test resolution
getent hosts ipa.vmstation.local
ping -c 2 ipa.vmstation.local
```

**Ports Not Accessible**:
```bash
# Check firewall rules
## firewalld (RHEL)
sudo firewall-cmd --list-all

## iptables (Debian)
sudo iptables -L -n -v

# Test port connectivity
nc -zv 192.168.4.63 30088
curl -k https://192.168.4.63:30445/ipa/ui
```

**FreeIPA/Keycloak Not Ready**:
```bash
# Check pod status
kubectl get pods -n identity -o wide

# Check pod logs
kubectl logs -n identity freeipa-0
kubectl logs -n identity <keycloak-pod-name>

# Check events
kubectl get events -n identity --sort-by=.metadata.creationTimestamp
```

#### Documentation

For detailed information, see [STEP4A_DNS_NETWORK_CONFIGURATION.md](STEP4A_DNS_NETWORK_CONFIGURATION.md)

---

### Step 4b: Deploy Infrastructure Services

**Status**: 📋 Planned

Deploy core infrastructure services:
- Ingress controller (Nginx or Traefik)
- Storage provisioner (if not using hostPath)
- Backup solutions

---

### Step 5: Deploy Monitoring Stack

**Status**: 📋 Planned

Deploy monitoring and observability stack:
- Prometheus (metrics collection)
- Grafana (visualization)
- Loki (log aggregation)
- Alertmanager (alerting)

**SSO Integration**: All monitoring tools will be integrated with Keycloak for single sign-on.

---

### Step 6: Configure LDAP Integration

**Status**: 📋 Planned

Configure LDAP client on all cluster nodes:
- Install and configure SSSD
- Configure PAM for LDAP authentication
- Enable automatic home directory creation
- Test user authentication

---

### Step 7: Application Deployment

**Status**: 📋 Planned

Deploy applications and services:
- Application workloads
- Service meshes (optional)
- Additional OIDC clients

---

## Node Inventory

### Cluster Nodes

| Hostname | IP Address | Role | OS | Notes |
|----------|------------|------|----|----|
| masternode | 192.168.4.63 | Control Plane | Debian 12 | Runs identity stack |
| storagenodet3500 | 192.168.4.61 | Worker | Debian 12 | Storage node |
| homelab | 192.168.4.62 | Worker | RHEL 10 | Compute node |

### Service Access Points

| Service | Access URL | NodePort | Notes |
|---------|-----------|----------|-------|
| FreeIPA HTTP | http://192.168.4.63:30088 | 30088 | Web UI |
| FreeIPA HTTPS | https://192.168.4.63:30445 | 30445 | Secure Web UI |
| FreeIPA LDAP | ldap://192.168.4.63:30389 | 30389 | LDAP directory |
| FreeIPA LDAPS | ldaps://192.168.4.63:30636 | 30636 | Secure LDAP |
| Keycloak HTTP | http://192.168.4.63:30180 | 30180 | Admin console |
| Keycloak HTTPS | https://192.168.4.63:30543 | 30543 | Secure admin |

---

## Success Criteria

Each step must meet its success criteria before proceeding to the next step.

### Step 4a Success Criteria

- [x] All DNS records extracted from FreeIPA pod
- [x] DNS records distributed to all cluster nodes
- [x] `ipa.vmstation.local` resolves correctly from all nodes
- [x] All required network ports are open and verified
- [x] SSH (port 22) remains accessible on all nodes
- [x] FreeIPA pod is READY (1/1)
- [x] Keycloak pod is READY (1/1)
- [x] FreeIPA web UI accessible at https://ipa.vmstation.local/ipa/ui
- [x] All verification scripts pass
- [x] Documentation is complete and accurate

---

## Quick Reference

### Important Files

- **Inventory**: `/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`
- **Kubeconfig**: `/etc/kubernetes/admin.conf`
- **Credentials**: `/root/identity-backup/cluster-admin-credentials.txt`
- **DNS Records**: `/tmp/freeipa-dns-records/freeipa-hosts.txt`

### Important Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Check identity stack
kubectl get pods -n identity
kubectl get services -n identity

# Test DNS resolution
getent hosts ipa.vmstation.local

# Check firewall rules
## RHEL/firewalld
sudo firewall-cmd --list-all

## Debian/iptables
sudo iptables -L -n -v

# View logs
kubectl logs -n identity freeipa-0
kubectl logs -n identity <keycloak-pod>
```

---

## Support and Documentation

- [Identity SSO Setup Guide](IDENTITY-SSO-SETUP.md)
- [Step 4a DNS and Network Configuration](STEP4A_DNS_NETWORK_CONFIGURATION.md)
- [Keycloak Integration Guide](KEYCLOAK-INTEGRATION.md)
- [Identity Stack Validation](IDENTITY-STACK-VALIDATION.md)
- [Troubleshooting Guide](../README.md#troubleshooting)

---

## Revision History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2024-12-16 | 1.0 | Initial deployment sequence documentation | VMStation Team |
| 2024-12-16 | 1.1 | Added Step 4a DNS and network configuration | VMStation Team |

---

*This document is maintained as part of the VMStation cluster infrastructure repository.*
