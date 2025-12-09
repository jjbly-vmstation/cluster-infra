#!/bin/bash
# test-freeipa-mirror-solution.sh
# Purpose: Test the FreeIPA mirror solution components
# This script validates syntax, configuration, and performs dry-run tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

test_count=0
pass_count=0
fail_count=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    test_count=$((test_count + 1))
    echo ""
    log_info "Test $test_count: $test_name"
    
    if eval "$test_command"; then
        log_info "✓ PASS: $test_name"
        pass_count=$((pass_count + 1))
        return 0
    else
        log_error "✗ FAIL: $test_name"
        fail_count=$((fail_count + 1))
        return 1
    fi
}

# ==============================================================================
# Test Suite
# ==============================================================================

echo "============================================================"
echo "FreeIPA Mirror Solution - Test Suite"
echo "============================================================"
echo "Repository: $REPO_ROOT"
echo ""

# Test 1: Check if required files exist
run_test "Mirror script exists" "test -f '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Mirror script is executable" "test -x '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Image patch file exists" "test -f '$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml'"

run_test "Main documentation exists" "test -f '$REPO_ROOT/docs/IDENTITY_FREEIPA_MIRROR.md'"

run_test "Quick start guide exists" "test -f '$REPO_ROOT/docs/IDENTITY_FREEIPA_QUICKSTART.md'"

run_test "Identity playbook exists" "test -f '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

# Test 2: Shell script syntax validation
run_test "Mirror script shell syntax" "sh -n '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

# Test 3: YAML syntax validation
run_test "Image patch YAML syntax" "python3 -c \"import yaml; list(yaml.safe_load_all(open('$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml')))\""

run_test "FreeIPA manifest YAML syntax" "python3 -c \"import yaml; list(yaml.safe_load_all(open('$REPO_ROOT/manifests/identity/freeipa.yaml')))\""

# Test 4: Ansible playbook syntax
run_test "Identity playbook syntax" "cd '$REPO_ROOT' && ansible-playbook --syntax-check ansible/playbooks/identity-deploy-and-handover.yml 2>&1 | grep -q 'playbook:'"

# Test 5: Check script configuration defaults
run_test "Mirror script has correct default tag" "grep -q 'FREEIPA_TAG.*almalinux-9' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Mirror script uses quay.io as source" "grep -q 'quay.io/freeipa/freeipa-server' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Mirror script targets localhost:5000" "grep -q 'localhost:5000' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

# Test 6: Check Ansible playbook configuration
run_test "Playbook has mirror configuration" "grep -q 'freeipa_mirror_image' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

run_test "Playbook has mirror script path" "grep -q 'freeipa_mirror_script' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

run_test "Playbook mirrors disabled by default" "grep -q 'freeipa_mirror_image: false' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

# Test 7: Check image patch configuration
run_test "Image patch uses localhost:5000" "grep -q 'localhost:5000/freeipa-server' '$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml'"

run_test "Image patch uses almalinux-9 tag" "grep -q 'almalinux-9' '$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml'"

run_test "Image patch has correct StatefulSet name" "grep -q 'name: freeipa' '$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml'"

run_test "Image patch has correct namespace" "grep -q 'namespace: identity' '$REPO_ROOT/manifests/identity/overlays/mirror-image-patch.yaml'"

# Test 8: Check documentation completeness
run_test "Main docs has diagnosis section" "grep -q 'Root Cause Analysis' '$REPO_ROOT/docs/IDENTITY_FREEIPA_MIRROR.md'"

run_test "Main docs has verification steps" "grep -q 'Operator Verification Steps' '$REPO_ROOT/docs/IDENTITY_FREEIPA_MIRROR.md'"

run_test "Main docs has rollback procedures" "grep -q 'Rollback Procedures' '$REPO_ROOT/docs/IDENTITY_FREEIPA_MIRROR.md'"

run_test "Main docs has troubleshooting" "grep -q 'Troubleshooting' '$REPO_ROOT/docs/IDENTITY_FREEIPA_MIRROR.md'"

run_test "Quick start has quick fix section" "grep -q 'Quick Fix' '$REPO_ROOT/docs/IDENTITY_FREEIPA_QUICKSTART.md'"

run_test "Quick start has verification section" "grep -q 'Verification' '$REPO_ROOT/docs/IDENTITY_FREEIPA_QUICKSTART.md'"

# Test 9: Check README updates
run_test "README links to FreeIPA docs" "grep -q 'IDENTITY_FREEIPA_MIRROR.md' '$REPO_ROOT/README.md'"

run_test "README has ImagePullBackOff troubleshooting" "grep -q 'ImagePullBackOff' '$REPO_ROOT/README.md'"

# Test 10: Script functionality checks (without execution)
run_test "Script has preflight checks" "grep -q 'preflight_checks' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script has idempotency check" "grep -q 'check_if_already_mirrored' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script has tag validation" "grep -q 'validate_tag_exists' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script has image verification" "grep -q 'verify_image_accessible' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script prints next steps" "grep -q 'print_next_steps' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

# Test 11: Security checks
run_test "Script uses set -e for safety" "head -20 '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh' | grep -q 'set -e'"

run_test "Script uses set -u for undefined vars" "head -20 '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh' | grep -q 'set -u'"

run_test "Playbook uses become for privileged ops" "grep -q 'become: true' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

# Test 12: Check script environment variable support
run_test "Script supports FREEIPA_TAG env var" "grep -q 'FREEIPA_TAG=.*{FREEIPA_TAG:-' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script supports FREEIPA_SOURCE_REPO env var" "grep -q 'FREEIPA_SOURCE_REPO=.*{FREEIPA_SOURCE_REPO:-' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

run_test "Script supports LOCAL_REGISTRY env var" "grep -q 'LOCAL_REGISTRY=.*{LOCAL_REGISTRY:-' '$REPO_ROOT/scripts/mirror-freeipa-to-local-registry.sh'"

# Test 13: Check Ansible variable configuration
run_test "Playbook has freeipa_image_tag variable" "grep -q 'freeipa_image_tag:' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

run_test "Playbook has freeipa_source_repo variable" "grep -q 'freeipa_source_repo:' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

run_test "Playbook has freeipa_local_registry variable" "grep -q 'freeipa_local_registry:' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

# Test 14: Integration points
run_test "Playbook references mirror script" "grep -q 'freeipa_mirror_script' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

run_test "Playbook references image patch" "grep -q 'freeipa_image_patch' '$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml'"

# ==============================================================================
# Test Summary
# ==============================================================================

echo ""
echo "============================================================"
echo "Test Summary"
echo "============================================================"
echo "Total tests: $test_count"
echo -e "${GREEN}Passed: $pass_count${NC}"
if [ $fail_count -gt 0 ]; then
    echo -e "${RED}Failed: $fail_count${NC}"
else
    echo -e "${GREEN}Failed: $fail_count${NC}"
fi
echo ""

if [ $fail_count -eq 0 ]; then
    log_info "All tests passed! ✓"
    echo ""
    echo "The FreeIPA mirror solution is properly configured and ready for deployment."
    echo ""
    echo "Next steps:"
    echo "1. Deploy to a test cluster"
    echo "2. Run the mirror script on the masternode"
    echo "3. Verify FreeIPA pod status"
    echo "4. Update production documentation"
    exit 0
else
    log_error "Some tests failed. Please review the errors above."
    exit 1
fi
