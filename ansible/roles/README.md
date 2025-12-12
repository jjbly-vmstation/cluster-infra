# Identity Deployment Roles

This directory contains modular Ansible roles for deploying the identity stack (Keycloak, PostgreSQL, FreeIPA, cert-manager) on Kubernetes.

## Overview

The identity deployment has been refactored from a monolithic 1300+ line playbook into 7 modular roles totaling ~100 lines in the main playbook. This improves maintainability, reusability, and testability.

## Roles

### identity-prerequisites
**Purpose:** Ensures required binaries exist, detects the infra node (control-plane/masternode), and creates necessary namespaces.

**Key Tasks:**
- Check for kubectl and helm
- Detect control-plane node for scheduling
- Create identity, cert-manager, and platform namespaces
- Uncordon all nodes

**Variables:** See `defaults/main.yml`

### identity-storage
**Purpose:** Manages storage classes, persistent volumes, PVCs, and hostPath ownership.

**Key Tasks:**
- Create identity data directories with proper ownership
- Deploy StorageClass and PersistentVolumes
- Clear stale PV claimRefs
- Fix hostPath ownership via privileged Jobs (PostgreSQL and FreeIPA)

**Variables:** See `defaults/main.yml`

**Templates:**
- `postgres-chown-job.yml.j2` - Job to fix PostgreSQL directory ownership
- `freeipa-chown-job.yml.j2` - Job to fix FreeIPA directory ownership

### identity-postgresql
**Purpose:** Deploys and manages PostgreSQL StatefulSet for Keycloak.

**Key Tasks:**
- Deploy PostgreSQL StatefulSet
- Wait for PVC creation
- Bind available PVs to PVCs
- Wait for StatefulSet rollout

**Variables:** See `defaults/main.yml`

### identity-keycloak
**Purpose:** Deploys and manages Keycloak via Helm.

**Key Tasks:**
- Install/upgrade Keycloak Helm chart (with PostgreSQL disabled)
- Wait for StatefulSet rollout
- Create NodePort service for desktop access

**Variables:** See `defaults/main.yml`

### identity-freeipa
**Purpose:** Deploys and manages FreeIPA StatefulSet.

**Key Tasks:**
- Check for FreeIPA manifest existence
- Deploy FreeIPA StatefulSet
- Clear stale PV claimRefs

**Variables:** See `defaults/main.yml`

### identity-certmanager
**Purpose:** Installs cert-manager and creates ClusterIssuer.

**Key Tasks:**
- Install cert-manager CRDs
- Add cert-manager Helm repo
- Install cert-manager with node affinity and tolerations
- Wait for cert-manager deployments
- Create CA secret from existing certificates
- Create ClusterIssuer for cert-manager

**Variables:** See `defaults/main.yml`

**Templates:**
- `clusterissuer-freeipa.yml.j2` - ClusterIssuer manifest

### identity-backup
**Purpose:** Handles backup operations for identity components.

**Key Tasks:**
- Create backup directory
- Backup PostgreSQL data
- Backup FreeIPA data
- Compute SHA256 checksums

**Variables:** See `defaults/main.yml`

## Control-Plane Taint Resolution

The original issue where pods couldn't schedule on the masternode due to the `node-role.kubernetes.io/control-plane:NoSchedule` taint has been resolved by ensuring all StatefulSets include the proper toleration:

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

This toleration is present in:
- `manifests/identity/postgresql-statefulset.yaml`
- `manifests/identity/freeipa.yaml`
- Keycloak (via Helm values)
- cert-manager (via Helm parameters)
- All chown jobs (via templates)

## Usage

### Basic deployment:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

### With destructive replace (includes backup):
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml -e identity_force_replace=true
```

### Run specific phases (tags):
```bash
# Only prerequisites and storage
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags prerequisites,storage

# Only PostgreSQL and Keycloak
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags postgresql,keycloak

# Only cert-manager
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags certmanager
```

## Variables

Key variables that can be overridden:

- `identity_force_replace`: (default: false) Enable destructive replace workflow
- `identity_backup_before_replace`: (default: true) Backup before replace
- `repo_root`: Auto-detected repository root
- `namespace_identity`: (default: identity) Identity namespace
- `namespace_cert_manager`: (default: cert-manager) cert-manager namespace
- `identity_data_dir`: (default: /srv/monitoring-data) Host path for data
- `enable_postgres_chown`: (default: true) Fix PostgreSQL directory ownership
- `enable_freeipa_chown`: (default: true) Fix FreeIPA directory ownership

See individual role `defaults/main.yml` files for complete variable lists.

## Migration from Old Playbook

The old monolithic playbook has been preserved as `identity-deploy-and-handover-old.yml` for reference. The refactored version maintains the same functionality but with improved organization:

- **Old:** 1373 lines, all tasks in one file
- **New:** 91 lines in main playbook + modular roles
- **Benefit:** Easier to maintain, test, and extend individual components

## Testing

To test individual roles, you can create a test playbook:

```yaml
---
- name: Test individual role
  hosts: localhost
  roles:
    - identity-prerequisites
```

## Contributing

When modifying the identity deployment:

1. Update the appropriate role's tasks
2. Update role defaults if adding new variables
3. Add templates to role's `templates/` directory
4. Test with `ansible-playbook --syntax-check`
5. Test in a dev environment before production

## Notes

- All roles assume execution on localhost with connection: local
- Most tasks require become: true for privileged operations
- KUBECONFIG is set to /etc/kubernetes/admin.conf for kubectl commands
- Tolerations for control-plane taint are included in all manifest templates
