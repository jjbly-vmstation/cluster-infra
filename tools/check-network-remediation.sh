#!/bin/bash
# check-network-remediation.sh
# Validates the network-remediation role for common Ansible/YAML mistakes
# Exit codes: 0 = pass, 1 = fail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ROLE_DIR="$REPO_ROOT/ansible/roles/network-remediation/tasks"

# Test counters
PASSED=0
FAILED=0
WARNINGS=0

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    PASSED=$((PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    FAILED=$((FAILED + 1))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    WARNINGS=$((WARNINGS + 1))
}

log_info() {
    echo -e "[INFO] $*"
}

# Check 1: No 'loop:' directly on a block (invalid Ansible syntax)
check_loop_on_block() {
    log_info "Check 1: Verifying no 'loop:' on block statements..."

    local found=0
    for file in "$ROLE_DIR"/*.yml; do
        [[ -f "$file" ]] || continue
        # Use awk to find block followed by loop at same indentation
        if ! awk '
            /^[[:space:]]*- block:/ { block_indent=index($0, "-"); in_block=1; next }
            in_block && /^[[:space:]]*loop:/ {
                loop_indent=index($0, "l");
                if (loop_indent <= block_indent + 2) { found=1; exit 1 }
            }
            in_block && /^[[:space:]]*- / && !/rescue:/ && !/always:/ { in_block=0 }
        ' "$file"; then
            log_fail "Found 'loop:' on block in: $file"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_pass "No 'loop:' on block statements found"
    fi
}

# Check 2: Verify included task files exist
check_include_files() {
    log_info "Check 2: Verifying included task files exist..."

    local missing=0
    for file in "$ROLE_DIR"/*.yml; do
        [[ -f "$file" ]] || continue
        # Extract include_tasks references
        while IFS= read -r include; do
            # Remove quotes if present
            include="${include%\"}"
            include="${include#\"}"
            include="${include%\'}"
            include="${include#\'}"

            # Skip Jinja variables and empty
            [[ -z "$include" ]] && continue
            [[ "$include" == *"{{"* ]] && continue

            # Check if file exists
            local include_path="$ROLE_DIR/$include"
            if [[ ! -f "$include_path" ]]; then
                log_fail "Missing included file: $include (referenced in $(basename "$file"))"
                missing=1
            fi
        done < <(grep -oP 'include_tasks:\s*\K[^\s]+' "$file" 2>/dev/null || true)
    done

    if [[ $missing -eq 0 ]]; then
        log_pass "All included task files exist"
    fi
}

# Check 3: Verify no multiline {% set %} in set_fact (problematic pattern)
check_multiline_set_fact() {
    log_info "Check 3: Verifying no multiline {% set %} in set_fact..."

    local found=0
    for file in "$ROLE_DIR"/*.yml; do
        [[ -f "$file" ]] || continue

        # Look for {% set in lines following set_fact with YAML block scalar
        if grep -Pzo 'set_fact:\s*\n\s+\w+:\s*[>|]-?\s*\n[^\n]*\{%\s*set' "$file" >/dev/null 2>&1; then
            log_fail "Found multiline {% set %} in set_fact: $(basename "$file")"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_pass "No problematic multiline {% set %} in set_fact found"
    fi
}

# Check 4: YAML syntax validation
check_yaml_syntax() {
    log_info "Check 4: Validating YAML syntax..."

    local errors=0
    for file in "$ROLE_DIR"/*.yml; do
        [[ -f "$file" ]] || continue
        if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            log_fail "YAML syntax error in: $(basename "$file")"
            errors=1
        fi
    done

    if [[ $errors -eq 0 ]]; then
        log_pass "All YAML files have valid syntax"
    fi
}

# Check 5: Ansible syntax check
check_ansible_syntax() {
    log_info "Check 5: Running Ansible syntax check..."

    local playbook="$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml"

    if [[ ! -f "$playbook" ]]; then
        log_fail "Main playbook not found: $playbook"
        return
    fi

    if command -v ansible-playbook &>/dev/null; then
        pushd "$REPO_ROOT/ansible" >/dev/null
        # Use exit code for reliable error detection (not grep on output)
        if ansible-playbook --syntax-check "playbooks/identity-deploy-and-handover.yml" >/dev/null 2>&1; then
            log_pass "Ansible syntax check passed"
        else
            log_fail "Ansible syntax check failed"
        fi
        popd >/dev/null
    else
        log_warn "ansible-playbook not found, skipping syntax check"
    fi
}

# Check 6: Verify delegate_to is inside included files, not on include_tasks
check_delegate_on_include() {
    log_info "Check 6: Verifying delegate_to is not on include_tasks..."

    local found=0
    for file in "$ROLE_DIR"/*.yml; do
        [[ -f "$file" ]] || continue
        # Look for include_tasks with delegate_to at same level
        if ! awk '
            /include_tasks:/ { in_include=1; include_indent=index($0,"-"); next }
            in_include && /delegate_to:/ {
                dt_indent=index($0,"d");
                if (dt_indent == include_indent + 2) { found=1; exit 1 }
            }
            in_include && /^[[:space:]]*- / { in_include=0 }
        ' "$file"; then
            log_fail "Found delegate_to on include_tasks in: $(basename "$file")"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        log_pass "No delegate_to on include_tasks found"
    fi
}

# Main
main() {
    echo "========================================"
    echo "Network Remediation Role Validation"
    echo "========================================"
    echo ""

    if [[ ! -d "$ROLE_DIR" ]]; then
        log_fail "Role directory not found: $ROLE_DIR"
        exit 1
    fi

    check_loop_on_block
    check_include_files
    check_multiline_set_fact
    check_yaml_syntax
    check_ansible_syntax
    check_delegate_on_include

    echo ""
    echo "========================================"
    echo "Summary"
    echo "========================================"
    echo -e "${GREEN}Passed:${NC}   $PASSED"
    echo -e "${RED}Failed:${NC}   $FAILED"
    echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
    echo ""

    if [[ $FAILED -gt 0 ]]; then
        echo -e "${RED}VALIDATION FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}VALIDATION PASSED${NC}"
        exit 0
    fi
}

main "$@"
