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
- **Path**: `/srv/identity_data/postgresql`
- **Node Affinity**: Control plane nodes only

## Deployment

These manifests are automatically deployed by the `identity-deploy-and-handover.yml` playbook in the following order:

1. Create storage directory: `/srv/identity_data/postgresql`
2. Deploy StorageClass: `storage-class-manual.yaml`
3. Deploy PersistentVolume: `keycloak-postgresql-pv.yaml`
4. Deploy Keycloak (which creates the PVC that binds to the PV)

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
   ls -la /srv/identity_data/postgresql
   ```

4. Check PVC status and events:
   ```bash
   kubectl describe pvc data-keycloak-postgresql-0 -n identity
   ```

### Node Scheduling Issues

The PV is configured with node affinity to control plane nodes. If you need to schedule on different nodes:

1. Edit `keycloak-postgresql-pv.yaml` and modify the `nodeAffinity` section
2. Reapply the manifest: `kubectl apply -f keycloak-postgresql-pv.yaml`

## Storage Considerations

- **Backup**: The data in `/srv/identity_data/postgresql` should be backed up regularly
- **Capacity**: Monitor disk usage; expand the PV if needed (requires cluster downtime)
- **Performance**: hostPath storage is suitable for single-node or small deployments. For production, consider using a proper storage solution like NFS, Ceph, or cloud-provided block storage.
