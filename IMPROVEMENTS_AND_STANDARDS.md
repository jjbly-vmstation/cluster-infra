# Improvements and Standards

This document outlines the industry best practices for infrastructure provisioning code, tracking both implemented improvements and recommendations for future work.

## Table of Contents

- [Implemented Improvements](#implemented-improvements)
- [Recommended Improvements](#recommended-improvements)
- [Ansible Best Practices](#ansible-best-practices)
- [Terraform Best Practices](#terraform-best-practices)
- [Security Guidelines](#security-guidelines)
- [CI/CD Integration](#cicd-integration)

---

## Implemented Improvements

### During Migration from VMStation Monorepo

1. **Fully Qualified Collection Names (FQCN)**
   - ✅ Updated all playbooks to use FQCN for modules
   - Examples: `ansible.builtin.shell`, `ansible.builtin.debug`, `ansible.posix.sysctl`
   - Ensures compatibility with future Ansible versions

2. **Configurable Manifests Path**
   - ✅ Added `manifests_path` variable to `deploy-cluster.yaml`
   - Allows separation of infrastructure code from application manifests
   - Usage: `-e "manifests_path=/path/to/manifests"`

3. **Proper Directory Structure**
   - ✅ Organized files following Ansible best practices
   - Separated inventory, playbooks, and roles
   - Created proper group_vars structure

4. **Comprehensive Documentation**
   - ✅ Updated README.md with usage examples
   - ✅ Created this IMPROVEMENTS_AND_STANDARDS.md document
   - ✅ Maintained playbook-specific README

5. **Git Hygiene**
   - ✅ Created comprehensive .gitignore
   - ✅ Excluded cache directories, secrets, and build artifacts

---

## Recommended Improvements

### High Priority

#### 1. Add Error Handling with block/rescue/always

**Current State:** Some tasks silently ignore failures with `failed_when: false`

**Recommended:**
```yaml
- name: "Deploy monitoring stack"
  block:
    - name: "Deploy Prometheus"
      ansible.builtin.shell: kubectl apply -f {{ manifests_path }}/prometheus.yaml
      
    - name: "Wait for Prometheus"
      ansible.builtin.shell: kubectl rollout status deployment/prometheus
      
  rescue:
    - name: "Collect diagnostic information"
      ansible.builtin.shell: kubectl describe pods -n monitoring
      register: pod_info
      
    - name: "Display diagnostic info"
      ansible.builtin.debug:
        var: pod_info.stdout_lines
        
    - name: "Fail with context"
      ansible.builtin.fail:
        msg: "Monitoring deployment failed. See diagnostics above."
        
  always:
    - name: "Record deployment status"
      ansible.builtin.template:
        src: deployment-status.j2
        dest: /var/log/deployment-status.log
```

#### 2. Add changed_when and failed_when Conditions

**Current State:** Many shell tasks don't properly report change status

**Recommended:**
```yaml
- name: "Check cluster status"
  ansible.builtin.shell: kubectl get nodes -o json | jq '.items | length'
  register: node_count
  changed_when: false  # This is a read-only command
  failed_when: node_count.rc != 0 or node_count.stdout | int < 1
```

#### 3. Implement Role-based Decomposition

**Current State:** Large monolithic playbooks

**Recommended Structure:**
```
ansible/roles/
├── kubernetes-common/
│   ├── tasks/main.yml
│   └── handlers/main.yml
├── kubernetes-control-plane/
│   ├── tasks/main.yml
│   └── templates/
├── kubernetes-worker/
│   └── tasks/main.yml
└── monitoring-stack/
    ├── tasks/main.yml
    └── defaults/main.yml
```

### Medium Priority

#### 4. Add Variable Validation

```yaml
- name: "Validate required variables"
  ansible.builtin.assert:
    that:
      - kubernetes_version is defined
      - kubernetes_version is version('1.25', '>=')
      - pod_network_cidr is match('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$')
    fail_msg: "Required variables are missing or invalid"
```

#### 5. Implement Idempotent Manifest Application

**Instead of:**
```yaml
- name: "Deploy Prometheus"
  ansible.builtin.shell: kubectl apply -f {{ manifests_path }}/prometheus.yaml
```

**Use:**
```yaml
- name: "Deploy Prometheus"
  kubernetes.core.k8s:
    state: present
    src: "{{ manifests_path }}/prometheus.yaml"
    wait: true
    wait_timeout: 300
```

#### 6. Add Pre-flight Validation Playbook

Create a dedicated validation playbook that can be run before deployment:

```yaml
# playbooks/validate-environment.yaml
---
- name: "Pre-deployment Validation"
  hosts: all
  gather_facts: true
  tasks:
    - name: "Check minimum RAM"
      ansible.builtin.assert:
        that: ansible_memtotal_mb >= 2048
        
    - name: "Check disk space"
      ansible.builtin.assert:
        that: ansible_mounts | selectattr('mount', 'equalto', '/') | map(attribute='size_available') | first | int > 10737418240  # 10GB
```

### Low Priority

#### 7. Add Molecule Testing

Create Molecule tests for roles:

```
ansible/roles/preflight-rhel10/molecule/
├── default/
│   ├── molecule.yml
│   ├── converge.yml
│   └── verify.yml
└── docker/
    └── molecule.yml
```

#### 8. Implement Ansible Tags Strategy

```yaml
- name: "Install Kubernetes binaries"
  ansible.builtin.apt:
    name:
      - kubelet
      - kubeadm
      - kubectl
    state: present
  tags:
    - kubernetes
    - install
    - packages
```

---

## Ansible Best Practices

### Module Usage

| Instead of | Use |
|------------|-----|
| `shell` for file operations | `ansible.builtin.file`, `ansible.builtin.copy` |
| `shell` for package install | `ansible.builtin.apt`, `ansible.builtin.dnf` |
| `shell` for service management | `ansible.builtin.systemd` |
| `shell` for kubectl | `kubernetes.core.k8s` module |

### Variable Naming

- Use `snake_case` for all variables
- Prefix role-specific variables: `preflight_rhel10_packages`
- Use descriptive names: `kubernetes_version` not `k8s_ver`

### Task Naming

- Start with a verb: "Install", "Configure", "Deploy"
- Be specific: "Install Kubernetes APT key" not "Setup APT"
- Include phase/context when applicable

### Handler Patterns

```yaml
# handlers/main.yml
- name: "Restart containerd"
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    daemon_reload: true
  listen: "container runtime changed"

# In tasks
- name: "Update containerd config"
  ansible.builtin.template:
    src: config.toml.j2
    dest: /etc/containerd/config.toml
  notify: "container runtime changed"
```

---

## Terraform Best Practices

### For terraform/malware-lab/ (Future Implementation)

1. **Module Structure**
   ```
   terraform/malware-lab/
   ├── main.tf
   ├── variables.tf
   ├── outputs.tf
   ├── versions.tf
   ├── modules/
   │   ├── network/
   │   ├── vms/
   │   └── security/
   └── environments/
       ├── dev/
       └── prod/
   ```

2. **Remote State Backend**
   ```hcl
   terraform {
     backend "s3" {
       bucket = "vmstation-terraform-state"
       key    = "malware-lab/terraform.tfstate"
       region = "us-east-1"
       encrypt = true
     }
   }
   ```

3. **Variable Validation**
   ```hcl
   variable "vm_count" {
     type        = number
     description = "Number of VMs to create"
     
     validation {
       condition     = var.vm_count >= 1 && var.vm_count <= 10
       error_message = "VM count must be between 1 and 10."
     }
   }
   ```

---

## Security Guidelines

### Secrets Management

1. **Use Ansible Vault**
   ```bash
   ansible-vault create inventory/group_vars/secrets.yml
   ansible-vault edit inventory/group_vars/secrets.yml
   ```

2. **Never commit secrets**
   - Add `secrets.yml` to `.gitignore`
   - Use example files: `secrets.yml.example`

3. **Use no_log for sensitive tasks**
   ```yaml
   - name: "Create secret"
     kubernetes.core.k8s:
       definition:
         apiVersion: v1
         kind: Secret
         # ...
     no_log: true
   ```

### SSH Key Management

- Use dedicated deployment keys
- Rotate keys regularly
- Store in vault when possible

---

## CI/CD Integration

### Recommended GitHub Actions Workflow

```yaml
# .github/workflows/validate.yml
name: Validate Infrastructure Code

on: [push, pull_request]

jobs:
  ansible-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Run ansible-lint
        uses: ansible/ansible-lint-action@main
        with:
          targets: ansible/playbooks/
          
  syntax-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Ansible
        run: pip install ansible
        
      - name: Syntax check playbooks
        run: |
          cd ansible
          for playbook in playbooks/*.yaml playbooks/*.yml; do
            ansible-playbook --syntax-check "$playbook"
          done

  terraform-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - uses: hashicorp/setup-terraform@v3
      
      - name: Terraform fmt
        run: terraform fmt -check -recursive terraform/
        
      - name: Terraform validate
        run: |
          cd terraform/malware-lab
          terraform init -backend=false
          terraform validate
```

### Pre-commit Hooks

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/ansible/ansible-lint
    rev: v6.22.1
    hooks:
      - id: ansible-lint
        
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.83.5
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
```

---

## Migration Checklist

### Already Completed

- [x] Directory structure created
- [x] Ansible playbooks migrated
- [x] FQCN applied to modules
- [x] Configurable manifests path added
- [x] Documentation updated
- [x] .gitignore created
- [x] Scripts migrated
- [x] preflight-rhel10 role migrated
- [x] Inventory files migrated

### To Be Implemented (Future Work)

- [ ] Add GitHub Actions CI workflow
- [ ] Implement ansible-lint
- [ ] Add Molecule tests
- [ ] Convert shell tasks to proper modules
- [ ] Add block/rescue error handling
- [ ] Create reusable roles from large playbooks
- [ ] Add pre-commit hooks
- [ ] Implement variable validation
- [ ] Add integration tests

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024-11 | Initial migration from vmstation monorepo |
