# Identity Stack Manifests

This directory contains Kubernetes manifests for the identity stack components, including storage configuration for Keycloak.

## Files

### storage-class-manual.yaml
Defines a StorageClass named `manual` that uses manual PV provisioning. This StorageClass does not have a provisioner and requires PersistentVolumes to be created manually before PVCs can bind to them.

- **Name**: `manual`
- **Provisioner**: `kubernetes.io/no-provisioner`
- **Volume Binding Mode**: `WaitForFirstConsumer` (delays binding until a pod using the PVC is scheduled)

### keycloak-postgresql-pv.yaml
Creates a PersistentVolume for Keycloak's PostgreSQL database using hostPath storage on the control plane node.

- **Name**: `keycloak-postgresql-pv`
- **Capacity**: 10Gi
- **Access Mode**: ReadWriteOnce
- **Storage Class**: `manual`
- **Path**: `/srv/monitoring-data/postgresql`
- **Node Affinity**: Control plane nodes only

### freeipa.yaml
Deploys FreeIPA (Identity Management) with LDAP, Kerberos, and CA services.

- **StatefulSet**: `freeipa` (1 replica)
- **Storage**: 20Gi PersistentVolume at `/srv/monitoring-data/freeipa`
- **Node Scheduling**: Control plane nodes only (with tolerations)
- **ClusterIP Service**: Internal cluster access on standard ports (80, 443, 389, 636, 88, 464)
- **NodePort Service**: External desktop access on:
  - HTTP: 30088
  - HTTPS: 30445
  - LDAP: 30389
  - LDAPS: 30636

## Deployment

These manifests are automatically deployed by the `identity-deploy-and-handover.yml` playbook in the following order:

1. Create storage directories: `/srv/monitoring-data/postgresql` and `/srv/monitoring-data/freeipa`
2. Deploy StorageClass: `storage-class-manual.yaml`
3. Deploy PersistentVolume: `keycloak-postgresql-pv.yaml`
4. Deploy PostgreSQL StatefulSet: `postgresql-statefulset.yaml`
5. Deploy Keycloak via Helm (with NodePort service for external access on ports 30180/30543)
6. Deploy FreeIPA: `freeipa.yaml` (with NodePort service for external access)

## External Access

### Keycloak
- **NodePort HTTP**: Port 30180 (mapped to container port 8080)
- **NodePort HTTPS**: Port 30543 (mapped to container port 8443)
- **Access URL**: `http://<node-ip>:30180/auth` or `https://<node-ip>:30543/auth`

### FreeIPA
- **NodePort HTTP**: Port 30088
- **NodePort HTTPS**: Port 30445
- **NodePort LDAP**: Port 30389
- **NodePort LDAPS**: Port 30636
- **Access URL**: `https://<node-ip>:30445`

## Troubleshooting

### PVC Remains Pending

If the PVC `data-keycloak-postgresql-0` remains in Pending state:

1. Check if the StorageClass exists:
   ```bash
   kubectl get storageclass manual
   ```

2. Check if the PersistentVolume exists and is Available:
   ```bash
   kubectl get pv keycloak-postgresql-pv
   ```

3. Verify the storage directory exists on the control plane node:
   ```bash
   ls -la /srv/monitoring-data/postgresql
   ```

4. Check PVC status and events:
   ```bash
   kubectl describe pvc data-keycloak-postgresql-0 -n identity
   ```

### Node Scheduling Issues

All identity stack components (Keycloak, PostgreSQL, FreeIPA) are configured to run on control-plane nodes with appropriate tolerations. This ensures critical identity services are always available.

**Keycloak Pod Scheduling:**
- Node affinity is configured in `helm/keycloak-values.yaml` with `nodeSelector` and `tolerations` at the root level
- The pod should be scheduled on nodes with label `node-role.kubernetes.io/control-plane`

**PostgreSQL Pod Scheduling:**
- Configured in `postgresql-statefulset.yaml` with `nodeSelector` and `tolerations`
- PV has node affinity matching control-plane nodes

**FreeIPA Pod Scheduling:**
- Configured in `freeipa.yaml` StatefulSet with `nodeSelector` and `tolerations`
- PV has node affinity matching control-plane nodes

To verify pod placement:
```bash
kubectl get pods -n identity -o wide
```

If pods are scheduled on wrong nodes, check:
1. Node labels: `kubectl get nodes --show-labels`
2. Pod node affinity: `kubectl describe pod <pod-name> -n identity`
3. StatefulSet/Deployment configuration: `kubectl get statefulset <name> -n identity -o yaml`

## Storage Considerations

- **Backup**: The data in `/srv/monitoring-data/postgresql` should be backed up regularly
- **Capacity**: Monitor disk usage; expand the PV if needed (requires cluster downtime)
- **Performance**: hostPath storage is suitable for single-node or small deployments. For production, consider using a proper storage solution like NFS, Ceph, or cloud-provided block storage.

## Permissions and fsGroup

- The Keycloak PostgreSQL subchart (`helm/keycloak-values.yaml`) configures `securityContext.runAsUser: 999`
   and `securityContext.fsGroup: 999`. `fsGroup` instructs kubelet to ensure mounted volumes
   are accessible to the Pod's group which prevents common hostPath permission issues.
- During a destructive replace or recovery, the `identity-deploy-and-handover.yml` playbook will
   automatically attempt to repair hostPath ownership by running a short-lived privileged Job
   (or via a delegated host chown). This behavior is enabled by default (`enable_postgres_chown=true`)
   and also runs when `identity_force_replace=true`.
- If your environment uses an NFS export with `root_squash`, in-cluster Jobs cannot change
   ownership; you must chown on the NFS server or adjust the export mapping.
