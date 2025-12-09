# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added - Identity Deployment Refactoring (2025-12-09)

#### Infrastructure
- **Infra node detection**: Automatic detection of control-plane node with fallback to first schedulable node
- **HostPath management**: Automated creation of `/srv/identity_data/postgresql` and `/srv/identity_data/freeipa` directories with proper permissions
- **FreeIPA manifest**: Added complete FreeIPA deployment manifest for Kerberos, LDAP, and CA services at `manifests/identity/freeipa.yaml`

#### Helm Deployments
- **Forced node scheduling**: All identity components (Keycloak, PostgreSQL, cert-manager) now explicitly scheduled on infra node via `nodeSelector`
- **Stable PostgreSQL image**: Default to `docker.io/postgres:11` to avoid registry rate limiting and missing Bitnami tags
- **Keycloak values file**: Created authoritative `helm/keycloak-values.yaml` with documented configuration options
- **Image pull secrets**: Documented `imagePullSecrets` configuration for private registries

#### Backup & Recovery
- **Opt-in destructive replace**: New playbook variables `identity_force_replace` (default: false) and `identity_backup_before_replace` (default: true)
- **Automated backups**: When `identity_force_replace=true`, creates timestamped backups of:
  - PostgreSQL hostPath data (`/srv/identity_data/postgresql`)
  - FreeIPA hostPath data (`/srv/identity_data/freeipa`)
  - CA certificates and keys (if available)
- **Checksum verification**: SHA256 checksums computed and stored for all backup archives
- **Backup location**: All backups stored in `/root/identity-backup` with mode 0700

#### PVC/PV Management
- **Automatic PV binding**: Detects Pending PVCs and binds to Available PVs with correct labels
- **Binding verification**: Logs each step of PV/PVC binding process
- **Node affinity**: PersistentVolumes use `nodeAffinity` to ensure scheduling on control-plane nodes

#### Rollout & Diagnostics
- **Configurable timeouts**: Rollout wait timeout configurable via `rollout_wait_timeout` (default: 180s)
- **Enhanced diagnostics**: On failure, automatically collects:
  - Pod status and descriptions
  - PVC/PV YAML dumps
  - Namespace events sorted by timestamp
  - Kubelet journal logs (best-effort)
- **Diagnostics storage**: All diagnostics saved to `/root/identity-backup/` with timestamps
- **Recovery workflow**: Automatic recovery attempt when `identity_force_replace=true`

#### Testing & Validation
- **Acceptance test script**: New `tests/verify-identity-deploy.sh` validates:
  - Namespace existence
  - Infra node detection
  - Storage configuration (StorageClass, PV, PVC)
  - Component health (cert-manager, Keycloak, PostgreSQL, FreeIPA)
  - Node scheduling verification
  - PostgreSQL image validation
- **Idempotence**: Playbook is fully idempotent - repeated runs without changes leave cluster unchanged

#### Documentation
- **CHANGELOG**: This changelog documenting all changes
- **Inline documentation**: Comprehensive comments in playbook and manifests
- **Usage examples**: Documented ansible-playbook commands for standard and destructive runs

### Changed
- **Playbook paths**: Updated to use auto-detected paths relative to playbook location instead of hardcoded `/opt/vmstation-org/` paths
- **Node selector syntax**: Updated Helm `--set` flags to use proper escaping for `kubernetes.io/hostname`
- **Error handling**: Improved error handling with block/rescue patterns for better diagnostics
- **CA backup**: CA backup now happens conditionally based on `identity_force_replace` flag
- **Security warnings**: Enhanced security warnings for CHANGEME password placeholders in both playbook and configuration files

### Fixed
- **Missing FreeIPA manifest**: Created complete FreeIPA manifest to resolve "manifest not found" warning
- **PVC Pending issue**: Enhanced PV binding logic to automatically bind Pending PVCs to Available PVs
- **Registry issues**: Forcing stable postgres:11 image prevents Docker Hub rate limiting and missing tag errors
- **Cert-manager CRD URL**: Pinned to v1.13.3 for reproducibility and security (instead of "latest")
- **Verbose output**: Removed redundant debug messages to reduce playbook verbosity

## Usage

### Standard Deployment
```bash
cd /home/runner/work/cluster-infra/cluster-infra/ansible/playbooks
ansible-playbook identity-deploy-and-handover.yml
```

### Destructive Replace with Backup
```bash
ansible-playbook identity-deploy-and-handover.yml -e identity_force_replace=true
```

### Skip Backup During Replace
```bash
ansible-playbook identity-deploy-and-handover.yml -e identity_force_replace=true -e identity_backup_before_replace=false
```

### Verification
```bash
/home/runner/work/cluster-infra/cluster-infra/tests/verify-identity-deploy.sh
```

## Security Notes

- All backup files stored in `/root/identity-backup` with restricted permissions (0700)
- CA material backed up securely when available
- Passwords in `helm/keycloak-values.yaml` have CHANGEME placeholders - **must be replaced before production use**
- FreeIPA default passwords in manifest **must be changed before deployment**

## Breaking Changes

None. This release is backward compatible with existing deployments.

## Migration Guide

For existing deployments:
1. Review new variables in playbook header (all have safe defaults)
2. Update any custom values to use new `helm/keycloak-values.yaml` location
3. Run playbook - it will upgrade existing installations in-place
4. Verify with acceptance test script

## Contributors

- GitHub Copilot Agent (automated refactoring and hardening)
