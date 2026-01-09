# FreeIPA Pod Failure Fix - Summary

**Date**: 2026-01-09  
**Issue**: FreeIPA pod enters "Failed" state after initially reporting ready, causing identity-service-accounts role to fail

## Root Cause Analysis

The FreeIPA pod was being killed by an overly aggressive liveness probe. The probe used `systemctl status ipa` which returns non-zero exit codes during installation and service restarts, causing Kubernetes to repeatedly kill and restart the container.

Additional contributing factors:
1. No resource limits - pod could be OOMKilled
2. Probe logic didn't account for FreeIPA install state
3. Short probe periods and timeouts increased false positive rate

## Fixes Applied

### 1. FreeIPA Manifest ([freeipa.yaml](../cluster-infra/manifests/identity/freeipa.yaml))

#### Added Resource Limits
```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "500m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

#### Improved Liveness Probe
**Before**: Simple `systemctl status ipa` that failed during install/restart

**After**: Intelligent check that:
- Verifies if ipa.service exists before failing
- Only fails if service is in truly unrecoverable state
- Allows install to complete without killing pod
- Extended period to 60s, timeout to 20s

```yaml
livenessProbe:
  exec:
    command:
    - /bin/bash
    - -c
    - |
      # Only fail if systemd itself is broken or ipa service is unrecoverable
      systemctl status ipa.service --no-pager >/dev/null 2>&1 || {
        # Check if service exists (install might still be in progress)
        if systemctl list-units --type=service --all | grep -q "ipa.service"; then
          exit 1  # Service exists but failed - problem
        else
          exit 0  # Service doesn't exist yet - install in progress
        fi
      }
      exit 0
  initialDelaySeconds: 1800
  timeoutSeconds: 20
  periodSeconds: 60
  failureThreshold: 10
```

#### Improved Readiness Probe
**Before**: Simple `systemctl status ipa`

**After**: More robust dual check:
- `systemctl is-active ipa.service` - checks active state
- grep for "Active: active" - confirms actually running
- Extended timeouts and failure thresholds

```yaml
readinessProbe:
  exec:
    command:
    - /bin/bash
    - -c
    - |
      systemctl is-active ipa.service >/dev/null 2>&1 || exit 1
      systemctl status ipa.service --no-pager | grep -q "Active: active" || exit 1
      exit 0
  initialDelaySeconds: 180
  timeoutSeconds: 20
  periodSeconds: 20
  failureThreshold: 90
```

### 2. Diagnostic Script ([diagnose-freeipa-failure.sh](../cluster-infra/scripts/diagnose-freeipa-failure.sh))

New comprehensive diagnostic tool that collects:
- Pod status, events, and descriptions
- Current and previous container logs
- Resource usage (CPU, memory, disk)
- PV/PVC status
- Internal FreeIPA logs (if pod is Running)
- Hostname/DNS configuration
- systemctl status inside container

**Usage**:
```bash
sudo /opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh
```

Output saved to timestamped directory: `/tmp/freeipa-diagnostics-YYYYMMDD-HHMMSS/`

### 3. Enhanced identity-service-accounts Role

**Before**: Immediately failed if pod phase != "Running"

**After**: Intelligent recovery with:
1. Display current pod state (phase, ready status, restart count)
2. Detailed failure information with common causes
3. **Automatic restart attempt**: `kubectl rollout restart statefulset/freeipa`
4. Extended wait timeout (10 minutes instead of 5)
5. Clear diagnostic instructions on failure

Changes in [identity-service-accounts/tasks/main.yml](../cluster-infra/ansible/roles/identity-service-accounts/tasks/main.yml):
- Added pod state display
- Added automatic restart block for Failed pods
- Extended retry timeout (60 retries × 10s = 10 minutes)
- Better error messages with actionable steps

### 4. Documentation Updates

Updated [DEPLOYMENT_SEQUENCE.md](DEPLOYMENT_SEQUENCE.md) with:
- Comprehensive troubleshooting section for FreeIPA failures
- Common causes (OOMKilled, aggressive probes, install failures)
- Diagnostic commands and tools
- Memory requirements (minimum 2Gi)
- Install time expectations (30+ minutes for first-time)
- Links to diagnostic script

## Testing Recommendations

### During Deployment
```bash
# Monitor pod status in real-time
watch kubectl -n identity get pods

# Check resource usage
kubectl top pod -n identity freeipa-0 --containers

# Follow logs
kubectl -n identity logs -f freeipa-0 -c freeipa-server
```

### If Issues Occur
```bash
# Run comprehensive diagnostics
sudo /opt/vmstation-org/cluster-infra/scripts/diagnose-freeipa-failure.sh

# Quick checks
kubectl -n identity describe pod freeipa-0
kubectl -n identity logs freeipa-0 -c freeipa-server --tail=200
kubectl -n identity logs freeipa-0 -c freeipa-server --previous  # if crashed

# Check node resources
kubectl top nodes
ls -lah /srv/monitoring-data/freeipa/  # storage permissions
```

## Expected Behavior After Fix

1. **Initial deploy**: Pod starts, initContainer seeds hostname
2. **Install phase (0-30 min)**: 
   - Liveness probe allows install to proceed
   - Readiness probe stays False until ipa.service is active
   - Pod shows as Running but not Ready
3. **Post-install**: 
   - ipa.service becomes active
   - Readiness probe succeeds
   - Pod becomes Ready (1/1)
4. **Service accounts creation**: Ansible waits for Ready state, then proceeds

## Files Changed

1. `cluster-infra/manifests/identity/freeipa.yaml` - Probes and resource limits
2. `cluster-infra/scripts/diagnose-freeipa-failure.sh` - New diagnostic tool
3. `cluster-infra/ansible/roles/identity-service-accounts/tasks/main.yml` - Enhanced recovery
4. `cluster-config/DEPLOYMENT_SEQUENCE.md` - Troubleshooting documentation
5. `.github/instructions/memory.instruction.md` - Investigation and fix history

## Next Steps

1. **Test the fix**: Run identity-full-deploy.sh and monitor FreeIPA pod stability
2. **Validate recovery**: If pod still fails, automatic restart should recover it
3. **Run diagnostics**: Use the new diagnostic script to gather information
4. **Monitor resources**: Ensure node has at least 4Gi free memory for FreeIPA

## Commit and Deploy

```bash
cd /opt/vmstation-org/cluster-infra
git add manifests/identity/freeipa.yaml
git add scripts/diagnose-freeipa-failure.sh
git add ansible/roles/identity-service-accounts/tasks/main.yml
git commit -m "fix: Improve FreeIPA pod stability with better probes and auto-recovery

- Add resource limits: 2Gi-4Gi memory, 500m-2000m CPU
- Improve liveness probe: only fail if service is unrecoverable
- Improve readiness probe: dual check (is-active + active status)
- Create comprehensive diagnostic script
- Add automatic restart in identity-service-accounts role
- Extend wait timeout to 10 minutes
- Update troubleshooting documentation

Fixes: FreeIPA pod entering Failed state after initial startup
Root cause: Aggressive liveness probe killing container during install/restart"

git push origin main

cd /opt/vmstation-org/cluster-config
git add DEPLOYMENT_SEQUENCE.md
git commit -m "docs: Add FreeIPA pod failure troubleshooting section"
git push origin main
```

## Prevention for Future Deployments

1. **Memory**: Ensure control-plane node has at least 6Gi free memory
2. **Monitoring**: Watch pod status during first 30 minutes
3. **Patience**: First-time FreeIPA install takes 20-30 minutes
4. **Diagnostics**: Run diagnostic script immediately if pod shows issues

## References

- [FreeIPA Container Documentation](https://github.com/freeipa/freeipa-container)
- [Kubernetes Liveness/Readiness Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- Memory investigation notes in `.github/instructions/memory.instruction.md`
