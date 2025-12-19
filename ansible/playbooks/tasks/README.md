# Ansible Tasks Directory

This directory contains reusable task files that are included in the main playbooks.

## Task Files

### ensure-freeipa-hostnetwork.yml

**Purpose**: Patches the FreeIPA StatefulSet to enable `hostNetwork: true` and verifies connectivity.

**When to use**: This task is automatically run after FreeIPA deployment in `identity-deploy-and-handover.yml` to ensure FreeIPA is accessible from cluster nodes during enrollment.

**What it does**:
- Backs up the current FreeIPA StatefulSet to `/tmp/freeipa-backups/`
- Patches the StatefulSet to add `hostNetwork: true` (idempotent)
- Restarts the StatefulSet to apply changes
- Waits for pod readiness (configurable timeout via `freeipa_ready_timeout`)
- Tests connectivity from the Ansible controller to the node IP on all required FreeIPA ports
- Sets the `freeipa_reachable` fact based on connectivity test results

**Variables**:
- `freeipa_ready_timeout` (default: `600s`): Timeout for waiting for FreeIPA pod readiness

**Outputs**:
- `freeipa_reachable` (boolean fact): `true` if FreeIPA is reachable on node IP, `false` otherwise
- `freeipa_host_ip` (fact): The node IP where FreeIPA is running
- `freeipa_pod_ip` (fact): The pod IP of the FreeIPA pod

### ensure-freeipa-firewall.yml

**Purpose**: Opens firewall ports on the local host (infra node) for FreeIPA if connectivity check fails.

**When to use**: This task is conditionally run after `ensure-freeipa-hostnetwork.yml` if:
1. FreeIPA is not reachable after hostNetwork configuration (`freeipa_reachable == false`)
2. Firewall automation is enabled (`identity_open_firewall == true`)

**What it does**:
- Detects the OS family (RHEL/Alma/CentOS vs Debian/Ubuntu)
- Opens required FreeIPA ports using the appropriate firewall tool:
  - `firewalld` (RHEL, AlmaLinux, CentOS, Rocky)
  - `ufw` (Debian, Ubuntu)
  - `iptables` (fallback for systems without firewalld or ufw)
- Re-tests connectivity after firewall changes
- Updates the `freeipa_reachable` fact

**Variables**:
- `identity_open_firewall` (default: `false`): Enable automatic firewall rule creation

**Ports opened**:
- TCP: 80, 443, 389, 636, 88, 464
- UDP: 88, 464

**Idempotency**: All firewall operations are idempotent and safe to run multiple times.

## Usage Example

These tasks are automatically included in the main `identity-deploy-and-handover.yml` playbook:

```yaml
# After FreeIPA deployment
- name: Ensure FreeIPA hostNetwork configuration
  include_tasks: tasks/ensure-freeipa-hostnetwork.yml
  tags: [freeipa, freeipa-network]

# Conditionally open firewall if needed
- name: Ensure FreeIPA firewall configuration (if needed)
  include_tasks: tasks/ensure-freeipa-firewall.yml
  when:
    - not (freeipa_reachable | default(true) | bool)
    - identity_open_firewall | default(false) | bool
  tags: [freeipa, freeipa-firewall]
```

To enable firewall automation when running the playbook:

```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e identity_open_firewall=true
```

## Testing

To test the tasks independently (for development purposes):

```bash
# Syntax check
ansible-playbook --syntax-check ansible/playbooks/identity-deploy-and-handover.yml

# Dry-run with tags
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  --tags freeipa-network \
  --check
```

## Documentation

For more information about FreeIPA network configuration, see:
- [docs/NOTE_FREEIPA_NETWORKING.md](../../docs/NOTE_FREEIPA_NETWORKING.md)

## Troubleshooting

If connectivity tests fail:

1. Check FreeIPA pod status: `kubectl get pod freeipa-0 -n identity`
2. Verify hostNetwork: `kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.hostNetwork}'`
3. Test manually: `nc -vz <node-ip> 389`
4. Check firewall: `sudo firewall-cmd --list-ports` (RHEL) or `sudo ufw status` (Debian)

See the documentation for detailed troubleshooting steps.
