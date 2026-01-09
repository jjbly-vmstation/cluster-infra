# FreeIPA Resource Optimization - Reality Check

## Actual Status (2026-01-09)

**FreeIPA is running successfully on masternode!**

```
identity       freeipa-0                                  1/1     Running     0          9m31s   masternode
identity       keycloak-0                                 1/1     Running     0          13m     masternode
identity       keycloak-postgresql-0                      1/1     Running     0          13m     masternode
```

**Masternode Resources:**
- Total Memory: 7853 MiB (~7.7Gi)
- Available: 4437 MiB (~4.3Gi)
- Used: 3416 MiB (~3.3Gi)
- Conclusion: **Plenty of headroom**

## Revised Strategy

### What Changed
1. ~~Initial panic: "Not enough memory, move to worker nodes"~~
2. **Reality: Masternode can handle identity stack comfortably**
3. Reduced resource limits to 50-75% for efficiency:
   - Request: 1.5Gi (down from 2Gi)
   - Limit: 3Gi (down from 4Gi)
4. Keep everything on masternode for 24/7 availability

### Why This Makes Sense
- **Masternode**: Low TDP, already running 24/7 for control-plane
- **Identity stack footprint**: ~2-3Gi actual usage
- **Remaining headroom**: ~4Gi available
- **No need for worker nodes**: Saves power management complexity

## Resource Breakdown

### Current Usage (Running)
```
Control Plane:     ~1.5Gi
Calico/Networking: ~500Mi
CoreDNS:           ~50Mi
Cert-Manager:      ~150Mi
FreeIPA:           ~800Mi-1.5Gi (during install: up to 2.5Gi)
Keycloak:          ~500Mi-1Gi
PostgreSQL:        ~200Mi-500Mi
oauth2-proxy:      ~50Mi
----------------------------
Total:             ~3.5-5Gi peak, ~3.3Gi steady-state
```

### Available Headroom
- Total: 7.8Gi
- Used: 3.3Gi
- **Free: 4.5Gi** ← More than enough

## Lessons Learned

1. **Don't panic on "Pending" state** - It's often temporary during PV binding
2. **Check actual memory usage** - Resource requests != actual usage
3. **50-75% of original limits** - Good starting point for optimization
4. **Keep it simple** - No need for complex scheduling if single node works

## Updated Resource Limits

### FreeIPA
```yaml
resources:
  requests:
    memory: "1536Mi"  # 1.5Gi
    cpu: "500m"
  limits:
    memory: "3Gi"     # Down from 4Gi
    cpu: "2000m"
```

**Rationale**: 
- FreeIPA typically uses 800Mi-1.2Gi steady-state
- 1.5Gi request ensures scheduling
- 3Gi limit allows install bursts
- Leaves 4Gi+ for other workloads

### Keycloak & PostgreSQL
- Keep existing limits (already reasonable)
- Keycloak: ~512Mi-1Gi
- PostgreSQL: ~256Mi-512Mi

## When to Use Worker Nodes

**Only if**:
1. Running Prometheus with long retention (4Gi+)
2. Running Grafana with heavy dashboard load
3. Running Loki with high log volume
4. Multiple FreeIPA replicas (HA setup)

**Not needed for**:
- Basic identity stack (current setup)
- Single FreeIPA instance
- Light monitoring

## Actual Issue Found

**oauth2-proxy is in CrashLoopBackOff** - This needs investigation:
```
identity       oauth2-proxy-647455f588-bq6bh   0/1   CrashLoopBackOff   7
```

Check logs: `kubectl -n identity logs oauth2-proxy-647455f588-bq6bh --tail=50`

Likely causes:
1. Invalid cookie secret (check Secret: oauth2-proxy-cookie-secret)
2. Missing/invalid Keycloak client credentials
3. Configuration error in oauth2-proxy Deployment

## Conclusion

**Keep identity stack on masternode**. The initial "Pending" was just normal startup delay. Current configuration with reduced limits (1.5Gi request, 3Gi limit) is optimal for:
- 24/7 availability
- Low power consumption
- Simple operations
- Sufficient headroom (4Gi+ free)

**Delete SCHEDULING_STRATEGY.md** and **setup-worker-node.sh** - Not needed for this use case.
