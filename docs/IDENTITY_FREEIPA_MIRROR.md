# FreeIPA Image Mirror - Diagnosis and Resolution

## Problem Diagnosis Summary

### Observed Symptoms
- **Pod Status**: FreeIPA pod `freeipa-0` in namespace `identity` shows `ImagePullBackOff` status
- **Error Details**: 
  - `kubectl describe pod freeipa-0 -n identity` reveals manifest fetch returning `401/WWW-Authenticate`
  - `ctr images pull` returns "not found" error
  - Current image reference: `freeipa/freeipa-server:latest`

### Root Cause Analysis

**Primary Issue: Docker Hub Authentication and Rate Limiting** (Confidence: 95%)

1. **Docker Hub Registry Changes**: Docker Hub (docker.io) now requires authentication for most image pulls and enforces rate limiting for anonymous users
2. **Image Path Resolution**: The reference `freeipa/freeipa-server:latest` resolves to `docker.io/freeipa/freeipa-server:latest`, which requires authentication
3. **Rate Limiting**: Even with authentication, Docker Hub enforces pull rate limits that can cause failures in production

**Secondary Issues**:

1. **Using 'latest' tag**: The `latest` tag is mutable and not recommended for production as it can change unexpectedly
2. **No Registry Credentials**: The cluster lacks `imagePullSecrets` configured for Docker Hub authentication
3. **External Dependency**: Relying on external registries creates availability and security risks

### Confidence Assessment

- **Docker Hub Auth Issue**: 95% confidence - Error code 401 and WWW-Authenticate header confirm authentication requirement
- **Not Runtime Incompatibility**: 99% confidence - The error occurs during image pull, not container startup
- **Not Missing Tag**: 90% confidence - The tag exists on Docker Hub but requires authentication

### Why Not Other Causes

- **Not a missing tag**: The `latest` tag exists for freeipa-server but is behind authentication
- **Not runtime incompatibility**: Error occurs at image pull stage, before container runtime evaluation
- **Not network issues**: HTTP 401 indicates successful connection but failed authentication

## Recommended Solution: Local Registry Mirror

### Why Mirroring is Chosen

1. **Eliminates External Dependencies**: Local registry removes reliance on Docker Hub availability and rate limits
2. **Better Performance**: Image pulls from localhost:5000 are significantly faster than external registry
3. **Explicit Version Control**: Using specific tags (e.g., `almalinux-9`) instead of `latest` ensures reproducibility
4. **Security**: Images are pulled once, inspected, and served locally reducing supply chain risks
5. **Cost**: Avoids Docker Hub Pro subscription for higher rate limits
6. **Compliance**: Keeps production clusters isolated from external registries

### Alternative Approaches (Not Chosen)

1. **Add Docker Hub credentials**: Requires subscription, still has rate limits, external dependency
2. **Use Quay.io directly**: Still external dependency, less control over availability
3. **Build custom image**: Maintenance overhead, loses upstream updates

## Implementation Overview

The solution consists of:

1. **Mirror Script** (`scripts/mirror-freeipa-to-local-registry.sh`): Automated image mirroring using Skopeo
2. **Manifest Overlay** (`manifests/identity/overlays/mirror-image-patch.yaml`): Kubernetes patch for using mirrored image
3. **Ansible Integration**: Optional automated deployment in the identity playbook
4. **Operator Runbook**: Step-by-step instructions below

## Operator Verification Steps

### Prerequisites

Ensure the following tools are available on the masternode:
```bash
# Required tools
which skopeo     # For image mirroring
which nerdctl    # For image verification (or use 'ctr')
which kubectl    # For Kubernetes operations
```

### Step 1: Mirror the Image

Run the mirror script on the masternode:

```bash
# Default: mirrors almalinux-9 tagged image
sudo /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh

# Or specify a different tag
sudo FREEIPA_TAG=fedora-39 /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh
```

**Expected Output**:
```
[INFO] Inspecting available tags for freeipa/freeipa-server at quay.io...
[INFO] Selected tag: almalinux-9
[INFO] Mirroring quay.io/freeipa/freeipa-server:almalinux-9 to localhost:5000/freeipa-server:almalinux-9...
[SUCCESS] Image mirrored successfully
[INFO] Verifying mirrored image...
[SUCCESS] Image verification complete
[INFO] Image ready at: localhost:5000/freeipa-server:almalinux-9
```

### Step 2: Verify the Mirrored Image

```bash
# Verify image exists in local registry
sudo nerdctl --namespace k8s.io images | grep freeipa-server

# Or using ctr
sudo ctr -n k8s.io images ls | grep freeipa-server

# Expected: localhost:5000/freeipa-server almalinux-9 or similar
```

### Step 3: Apply the Image Patch

```bash
# Apply the overlay patch to update StatefulSet
kubectl apply -f /opt/vmstation-org/cluster-infra/manifests/identity/overlays/mirror-image-patch.yaml

# Or patch directly
kubectl patch statefulset freeipa -n identity --type='strategic' -p '
spec:
  template:
    spec:
      containers:
      - name: freeipa-server
        image: localhost:5000/freeipa-server:almalinux-9
'
```

### Step 4: Verify Pod Status

```bash
# Check if pod is now pulling/running
kubectl get pods -n identity -w

# Check pod events
kubectl describe pod freeipa-0 -n identity

# Check pod logs once running
kubectl logs -n identity freeipa-0 -f
```

**Expected Results**:
- Pod transitions from `ImagePullBackOff` → `ContainerCreating` → `Running`
- No authentication errors in events
- FreeIPA initialization logs appear

### Step 5: Validate FreeIPA Service

```bash
# Wait for FreeIPA to be ready (may take 5-10 minutes for first-time setup)
kubectl wait --for=condition=ready pod/freeipa-0 -n identity --timeout=600s

# Test FreeIPA web interface (from within cluster or via port-forward)
kubectl port-forward -n identity svc/freeipa 8443:443

# Access https://localhost:8443 in browser
# Default credentials: admin / CHANGEME_IPA_ADMIN_PASSWORD (from manifest)
```

## Rollback Procedures

### Rollback to Original Image (Not Recommended)

If you need to revert to the original Docker Hub image (requires adding credentials first):

```bash
# Create Docker Hub credentials secret (replace with your credentials)
kubectl create secret docker-registry dockerhub-creds \
  --docker-server=docker.io \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n identity

# Update StatefulSet to use original image and add imagePullSecrets
kubectl patch statefulset freeipa -n identity --type='strategic' -p '
spec:
  template:
    spec:
      imagePullSecrets:
      - name: dockerhub-creds
      containers:
      - name: freeipa-server
        image: freeipa/freeipa-server:latest
'
```

### Rollback to Different Mirror Tag

If the almalinux-9 tag has issues, try a different tag:

```bash
# Mirror a different tag
sudo FREEIPA_TAG=fedora-39 /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh

# Update StatefulSet
kubectl patch statefulset freeipa -n identity --type='strategic' -p '
spec:
  template:
    spec:
      containers:
      - name: freeipa-server
        image: localhost:5000/freeipa-server:fedora-39
'
```

## Troubleshooting

### Issue: Mirror Script Fails - Registry Not Available

**Symptoms**: Script reports "connection refused" to localhost:5000

**Solution**:
```bash
# Check if local registry is running
sudo systemctl status registry

# If not, the cluster may use containerd's built-in registry
# Verify containerd configuration
sudo cat /etc/containerd/config.toml | grep registry

# You may need to configure an insecure registry
# Add to /etc/containerd/config.toml under [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
  endpoint = ["http://localhost:5000"]

# Restart containerd
sudo systemctl restart containerd
```

### Issue: Image Pull Still Fails After Mirroring

**Symptoms**: Pod still shows ImagePullBackOff after patching

**Diagnosis**:
```bash
# Check exact error
kubectl describe pod freeipa-0 -n identity | grep -A 10 Events

# Verify image name matches exactly
kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.containers[0].image}'

# Check if image is accessible
sudo crictl images | grep freeipa
```

**Solution**: Ensure image name matches exactly, including tag

### Issue: FreeIPA Container Starts But Fails

**Symptoms**: Pod status is Running but readiness probe fails

**Diagnosis**:
```bash
# Check container logs
kubectl logs -n identity freeipa-0 --tail=100

# Check if it's initialization (first time) or startup issue
kubectl exec -n identity freeipa-0 -- systemctl status ipa
```

**Solution**: This is likely a FreeIPA configuration issue (not image pull issue). Check FreeIPA logs and configuration.

### Issue: "localhost:5000" Not Resolving

**Symptoms**: Error mentions cannot resolve localhost

**Solution**: Use `127.0.0.1:5000` instead or ensure `/etc/hosts` has localhost entry

## Security Considerations

1. **Image Verification**: The mirror script verifies image SHA256 digest before and after mirroring
2. **Registry Security**: Ensure the local registry at localhost:5000 is properly secured and not exposed externally
3. **Regular Updates**: Schedule periodic re-mirroring to get security updates from upstream
4. **Audit Trail**: Mirror script logs all operations for audit purposes

## Automation via Ansible

The solution includes optional Ansible automation. Enable it by setting a variable:

```bash
# Run playbook with mirror automation enabled
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e freeipa_mirror_image=true \
  -e freeipa_image_tag=almalinux-9

# For destructive reset and clean deployment
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e identity_force_replace=true \
  -e freeipa_mirror_image=true \
  -e freeipa_image_tag=almalinux-9
```

## Maintenance

### Updating the Mirrored Image

```bash
# Re-run mirror script to pull latest version of tag
sudo /opt/vmstation-org/cluster-infra/scripts/mirror-freeipa-to-local-registry.sh

# Restart FreeIPA pod to use updated image
kubectl rollout restart statefulset/freeipa -n identity

# Monitor rollout
kubectl rollout status statefulset/freeipa -n identity
```

### Monitoring Mirror Health

```bash
# Check image age
sudo nerdctl --namespace k8s.io images | grep freeipa-server

# Check if upstream has updates
skopeo inspect docker://quay.io/freeipa/freeipa-server:almalinux-9

# Compare digests
LOCAL_DIGEST=$(sudo nerdctl --namespace k8s.io images | grep localhost:5000/freeipa-server | awk '{print $3}')
REMOTE_DIGEST=$(skopeo inspect docker://quay.io/freeipa/freeipa-server:almalinux-9 | jq -r .Digest)
echo "Local: $LOCAL_DIGEST"
echo "Remote: $REMOTE_DIGEST"
```

## References

- FreeIPA Container Documentation: https://github.com/freeipa/freeipa-container
- Available Tags: https://quay.io/repository/freeipa/freeipa-server?tab=tags
- Kubernetes ImagePullSecrets: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Skopeo Documentation: https://github.com/containers/skopeo
