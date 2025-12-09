# FreeIPA ImagePullBackOff - Quick Fix Guide

This is a quick reference guide for operators who need to fix the FreeIPA ImagePullBackOff issue immediately.

For detailed documentation, see [IDENTITY_FREEIPA_MIRROR.md](./IDENTITY_FREEIPA_MIRROR.md)

## Problem

FreeIPA pod stuck in `ImagePullBackOff` status with error:
- `401 Unauthorized` when pulling from Docker Hub
- Image: `freeipa/freeipa-server:latest`

## Quick Fix (5 minutes)

### Option 1: Automated Fix via Ansible (Recommended)

```bash
# SSH to masternode
ssh masternode

# Run playbook with mirror enabled
cd /opt/vmstation-org/cluster-infra
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e freeipa_mirror_image=true \
  -e freeipa_image_tag=almalinux-9

# If you need a clean deployment (with backup)
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e identity_force_replace=true \
  -e freeipa_mirror_image=true \
  -e freeipa_image_tag=almalinux-9
```

### Option 2: Manual Fix (3 commands)

```bash
# SSH to masternode
ssh masternode

# Step 1: Mirror the image to local registry
sudo /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh

# Step 2: Apply the image patch
kubectl apply -f /opt/vmstation-org/cluster-infra/manifests/identity/overlays/mirror-image-patch.yaml

# Step 3: Verify the fix
kubectl get pods -n identity -w
```

## Verification

After applying the fix, verify the pod status:

```bash
# Check pod status (should show Running after a few minutes)
kubectl get pods -n identity

# Check events (should not show ImagePullBackOff)
kubectl describe pod freeipa-0 -n identity | grep -A 10 Events

# Check logs (should show FreeIPA initialization)
kubectl logs -n identity freeipa-0 --tail=50
```

**Expected Results:**
- Pod status: `ContainerCreating` → `Running`
- No `ImagePullBackOff` or authentication errors
- FreeIPA initialization logs visible

## What This Fix Does

1. **Mirrors image** from `quay.io/freeipa/freeipa-server:almalinux-9` to `localhost:5000/freeipa-server:almalinux-9`
2. **Updates StatefulSet** to use the mirrored image
3. **Eliminates Docker Hub dependency** - no authentication needed

## Rollback

If the fix causes issues, revert to previous state:

```bash
# Option 1: Use a different tag
sudo FREEIPA_TAG=fedora-39 /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh
kubectl patch statefulset freeipa -n identity --type='strategic' -p '
spec:
  template:
    spec:
      containers:
      - name: freeipa-server
        image: localhost:5000/freeipa-server:fedora-39
'

# Option 2: Revert to original (requires Docker Hub credentials - not recommended)
kubectl patch statefulset freeipa -n identity --type='strategic' -p '
spec:
  template:
    spec:
      containers:
      - name: freeipa-server
        image: freeipa/freeipa-server:latest
'
```

## Troubleshooting

### Issue: Mirror script fails with "connection refused"

**Cause:** Local registry not running or not configured

**Fix:**
```bash
# Check containerd configuration
sudo cat /etc/containerd/config.toml | grep -A 5 registry

# The script may need registry configuration
# Verify with cluster administrator
```

### Issue: Pod still in ImagePullBackOff after applying fix

**Cause:** Image name mismatch or cache issue

**Fix:**
```bash
# Delete the pod to force recreation
kubectl delete pod freeipa-0 -n identity

# Verify the StatefulSet has the correct image
kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.containers[0].image}'

# Should output: localhost:5000/freeipa-server:almalinux-9
```

### Issue: FreeIPA starts but initialization fails

**Cause:** Configuration issue (not image pull issue)

**Note:** This is a separate issue. Check FreeIPA logs and configuration.

## Available Tags

Common FreeIPA tags (choose based on your OS preference):
- `almalinux-9` - AlmaLinux 9 (RHEL 9 compatible) - **Recommended**
- `fedora-39` - Fedora 39
- `rocky-9` - Rocky Linux 9
- `centos-stream-9` - CentOS Stream 9

View all tags at: https://quay.io/repository/freeipa/freeipa-server?tab=tags

## Additional Help

- Full documentation: [IDENTITY_FREEIPA_MIRROR.md](./IDENTITY_FREEIPA_MIRROR.md)
- Script source: `scripts/mirror-freeipa-to-local-registry.sh`
- Playbook: `ansible/playbooks/identity-deploy-and-handover.yml`

## Contact

For cluster-specific issues, contact your cluster administrator.
