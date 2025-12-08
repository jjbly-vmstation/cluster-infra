# Identity Backup & Recovery (FreeIPA / Keycloak / CA)

This document describes the lightweight backup steps implemented by the `identity-deploy-and-handover.yml` playbook
and recommended additional measures for reliable recovery of the identity stack.

Summary of what the playbook backs up
- CA certificate and (if present) CA private key are copied to `/root/identity-backup` and
  archived as `/root/identity-backup/identity-ca-backup.tar.gz`.
- The playbook does NOT back up Keycloak or FreeIPA databases or persistent volumes.

Why the CA backup matters
- The CA private key and certificate are required to re-create TLS secrets in Kubernetes
  and to re-issue certificates for services (Keycloak, FreeIPA, etc.) after a cluster
  or node-level failure. Keeping the CA material available speeds recovery and prevents
  certificate mismatches.

Location
- Backup archive (if created): `/root/identity-backup/identity-ca-backup.tar.gz`
- Individual files (before archiving, may be removed by the playbook):
  - `/root/identity-backup/ca.cert.pem`
  - `/root/identity-backup/ca.key.pem`

Immediate recovery steps (quick)
1. Copy the backup archive to the recovery host (if needed). Example:
   sudo cp /root/identity-backup/identity-ca-backup.tar.gz /tmp/

2. Extract the CA files on the recovery host (as root):
   sudo mkdir -p /root/identity-backup && sudo tar -xzf /tmp/identity-ca-backup.tar.gz -C /root/identity-backup

3. Recreate the Kubernetes Secret for cert-manager (run on the controller with admin kubeconfig):
   sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl create secret generic freeipa-ca --namespace cert-manager --from-file=ca.crt=/root/identity-backup/ca.cert.pem --dry-run=client -o yaml | kubectl apply -f -

4. Re-apply the ClusterIssuer (if the playbook did not already):
   sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f /opt/vmstation-org/cluster-infra/ansible/templates/clusterissuer-freeipa.yml.j2

5. Re-deploy Keycloak / FreeIPA (apply manifests or helm charts). Reattach/restore DB backups as necessary.

Recommended additional backups (production)
- Keycloak DB: schedule regular `pg_dump` or logical backups to an object store (S3/MinIO).
- FreeIPA: schedule `ipa-backup` and copy backup to off-node object store.
- PV snapshots: use Longhorn or CSI snapshots and copy snapshots to durable storage.
- etcd snapshots: schedule and copy etcd snapshots off-node.
- Store CA private keys in an encrypted secret manager (Vault) or HSM. Do not keep long-term unencrypted keys on disk.

Hardening the playbook and automation suggestions
- Replace shell-based `kubectl` calls with `kubernetes.core.k8s` Ansible module for idempotence.
- Add tasks to upload CA backup to an encrypted offsite location (MinIO/S3) immediately after generation.
- Add database backup tasks and integrate Velero for resource+PV backups.
- Add a small recovery playbook that executes the quick recovery steps automatically.

Security notes
- Backups stored under `/root` are convenient, but they are sensitive. Limit access to root and consider encrypting the archive.
- Rotate CA keys only when you have a tested re-issue plan for all workloads.

