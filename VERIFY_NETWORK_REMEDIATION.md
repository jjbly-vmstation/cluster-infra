# Network Remediation Fix Verification Guide

This document provides step-by-step verification instructions for the network-remediation role fixes.

## Summary of Changes

The following issues were identified and fixed:

### 1. Critical Fix: Multiline Jinja Expression in set_fact

**File:** `ansible/roles/network-remediation/tasks/remediate-node-network.yml`

**Problem:** The original code used a multiline `{% set %}` Jinja block with YAML folding (`>-`), which caused runtime errors due to escape sequence handling:

```yaml
# BEFORE (broken)
- name: Extract mode from config (with fallback)
  set_fact:
    detected_kubeproxy_mode: >-
      {% set mode_match = kubeproxy_config.stdout | default('') | regex_search('mode:\s*"?([A-Za-z0-9_-]+)"?', '\1') %}
      {{ mode_match[0] if mode_match else 'iptables' }}
```

**Error:** `The filter plugin 'ansible.builtin.regex_search' failed: Unknown argument`

**Solution:** Replaced with a single-line expression using proper escaping:

```yaml
# AFTER (fixed)
- name: Extract mode from config (with fallback)
  set_fact:
    detected_kubeproxy_mode: "{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}"
```

### 2. Minor Fix: Trailing Whitespace

Removed trailing whitespace from all YAML files in the network-remediation tasks directory.

## Verification Steps

### Step 1: Check Ansible Version

```bash
ansible --version
```

Expected: Ansible core 2.14+ installed.

### Step 2: Run YAML Syntax Check

```bash
cd /path/to/cluster-infra
yamllint ansible/roles/network-remediation/tasks/*.yml
```

Expected: No errors (warnings about line length are acceptable).

### Step 3: Run Ansible Syntax Check

```bash
cd /path/to/cluster-infra/ansible
ansible-playbook --syntax-check playbooks/identity-deploy-and-handover.yml
```

Expected output:
```
playbook: playbooks/identity-deploy-and-handover.yml
```

### Step 4: Run Validation Script

```bash
cd /path/to/cluster-infra
bash tools/check-network-remediation.sh
```

Expected output:
```
========================================
Network Remediation Role Validation
========================================

[INFO] Check 1: Verifying no 'loop:' on block statements...
[PASS] No 'loop:' on block statements found
[INFO] Check 2: Verifying included task files exist...
[PASS] All included task files exist
[INFO] Check 3: Verifying no multiline {% set %} in set_fact...
[PASS] No problematic multiline {% set %} in set_fact found
[INFO] Check 4: Validating YAML syntax...
[PASS] All YAML files have valid syntax
[INFO] Check 5: Running Ansible syntax check...
[PASS] Ansible syntax check passed
[INFO] Check 6: Verifying delegate_to is not on include_tasks...
[PASS] No delegate_to on include_tasks found

========================================
Summary
========================================
Passed:   6
Failed:   0
Warnings: 0

VALIDATION PASSED
```

### Step 5: Run Deterministic Jinja Expression Tests

Create a test playbook to verify the fixed expression handles all cases:

```bash
cat > /tmp/test-kubeproxy-mode-detection.yml << 'EOF'
---
- name: Test kube-proxy mode detection expression
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    # Test case 1: mode: "ipvs" with quotes
    - name: "Test 1: mode with quotes (ipvs)"
      block:
        - set_fact:
            kubeproxy_config:
              stdout: |
                apiVersion: kubeproxy.config.k8s.io/v1alpha1
                kind: KubeProxyConfiguration
                mode: "ipvs"
              rc: 0
        - set_fact:
            detected_kubeproxy_mode: "{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}"
          when: kubeproxy_config.rc == 0
        - assert:
            that: detected_kubeproxy_mode == 'ipvs'
            fail_msg: "Expected 'ipvs', got '{{ detected_kubeproxy_mode }}'"
        - debug:
            msg: "✓ Test 1 PASSED: '{{ detected_kubeproxy_mode }}'"

    # Test case 2: mode: iptables without quotes
    - name: "Test 2: mode without quotes (iptables)"
      block:
        - set_fact:
            kubeproxy_config:
              stdout: |
                mode: iptables
              rc: 0
        - set_fact:
            detected_kubeproxy_mode: "{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}"
          when: kubeproxy_config.rc == 0
        - assert:
            that: detected_kubeproxy_mode == 'iptables'
        - debug:
            msg: "✓ Test 2 PASSED: '{{ detected_kubeproxy_mode }}'"

    # Test case 3: No mode line (fallback)
    - name: "Test 3: No mode line (fallback to iptables)"
      block:
        - set_fact:
            kubeproxy_config:
              stdout: |
                apiVersion: kubeproxy.config.k8s.io/v1alpha1
              rc: 0
        - set_fact:
            detected_kubeproxy_mode: "{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}"
          when: kubeproxy_config.rc == 0
        - assert:
            that: detected_kubeproxy_mode == 'iptables'
        - debug:
            msg: "✓ Test 3 PASSED: '{{ detected_kubeproxy_mode }}'"

    # Test case 4: Empty stdout
    - name: "Test 4: Empty stdout (fallback to iptables)"
      block:
        - set_fact:
            kubeproxy_config:
              stdout: ""
              rc: 0
        - set_fact:
            detected_kubeproxy_mode: "{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}"
          when: kubeproxy_config.rc == 0
        - assert:
            that: detected_kubeproxy_mode == 'iptables'
        - debug:
            msg: "✓ Test 4 PASSED: '{{ detected_kubeproxy_mode }}'"

    - name: All tests passed
      debug:
        msg: "✓ All kube-proxy mode detection tests passed!"
EOF

ansible-playbook /tmp/test-kubeproxy-mode-detection.yml
```

Expected: All 4 test cases pass.

## Deterministic Proof Outputs

### Input/Output Matrix for kube-proxy Mode Detection

| Test Case | Input (kubeproxy_config.stdout) | Expected Output | Actual Output |
|-----------|--------------------------------|-----------------|---------------|
| 1 | `mode: "ipvs"` | `ipvs` | `ipvs` ✓ |
| 2 | `mode: iptables` | `iptables` | `iptables` ✓ |
| 3 | (no mode line) | `iptables` | `iptables` ✓ |
| 4 | (empty string) | `iptables` | `iptables` ✓ |

### Expression Analysis

**Original Expression (broken):**
```jinja
{% set mode_match = kubeproxy_config.stdout | default('') | regex_search('mode:\s*"?([A-Za-z0-9_-]+)"?', '\1') %}
{{ mode_match[0] if mode_match else 'iptables' }}
```

**Fixed Expression:**
```jinja
{{ (kubeproxy_config.stdout | default('') | regex_search('mode:\\s*\"?([A-Za-z0-9_-]+)\"?', '\\1') | default(['iptables'], true))[0] }}
```

**Key differences:**
1. Removed `{% set %}` block - not needed, expression fits on one line
2. Double backslashes (`\\s`, `\\1`) for proper YAML escaping
3. Used `| default(['iptables'], true)` to provide fallback array when regex returns None
4. Access first element with `[0]` directly

## Operator Runbook

### Pre-deployment Checks

```bash
# 1. Verify Ansible is installed
ansible --version

# 2. Verify syntax
cd /path/to/cluster-infra/ansible
ansible-playbook --syntax-check playbooks/identity-deploy-and-handover.yml

# 3. Run validation script
bash ../tools/check-network-remediation.sh

# 4. Run lint (optional)
yamllint roles/network-remediation/tasks/*.yml
```

### Dry-run (Check Mode)

```bash
# Run with --check to see what would change without making changes
ansible-playbook playbooks/identity-deploy-and-handover.yml --check -v
```

### Production Deployment

```bash
# Full deployment (after backup verification)
ansible-playbook playbooks/identity-deploy-and-handover.yml -v
```

### Rollback

If issues occur, revert the changes:

```bash
git checkout HEAD~1 -- ansible/roles/network-remediation/tasks/remediate-node-network.yml
```

## Acceptance Criteria Checklist

- [x] `ansible-playbook --syntax-check playbooks/identity-deploy-and-handover.yml` returns success
- [x] `yamllint` returns no errors for modified files (warnings acceptable)
- [x] `tools/check-network-remediation.sh` exits 0
- [x] Deterministic proofs render expected values for all sample inputs
- [x] Patch applies cleanly to repository root

## Files Modified

1. `ansible/roles/network-remediation/tasks/remediate-node-network.yml` - Fixed Jinja expression
2. `ansible/roles/network-remediation/tasks/*.yml` - Removed trailing whitespace
3. `tools/check-network-remediation.sh` - New validation script (created)
4. `VERIFY_NETWORK_REMEDIATION.md` - This verification document (created)
