#!/bin/sh
# mirror-freeipa-to-local-registry.sh
# Purpose: Mirror FreeIPA container image from quay.io to local registry
# Usage: sudo ./mirror-freeipa-to-local-registry.sh [TAG]
# Environment Variables:
#   FREEIPA_TAG          - Tag to mirror (default: almalinux-9)
#   FREEIPA_SOURCE_REPO  - Source repository (default: quay.io/freeipa/freeipa-server)
#   LOCAL_REGISTRY       - Local registry address (default: localhost:5000)
#   SKIP_VERIFICATION    - Skip image verification (default: false)

set -e  # Exit on error
set -u  # Exit on undefined variable

# ==============================================================================
# Configuration
# ==============================================================================

# Source repository configuration
FREEIPA_SOURCE_REPO="${FREEIPA_SOURCE_REPO:-quay.io/freeipa/freeipa-server}"
FREEIPA_TAG="${FREEIPA_TAG:-${1:-almalinux-9}}"

# Local registry configuration
LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
LOCAL_REPO_NAME="freeipa-server"

# Runtime configuration
SKIP_VERIFICATION="${SKIP_VERIFICATION:-false}"
RUNTIME_CMD=""

# Logging
LOG_PREFIX="[mirror-freeipa]"

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() {
    echo "${LOG_PREFIX} [INFO] $*"
}

log_success() {
    echo "${LOG_PREFIX} [SUCCESS] $*"
}

log_error() {
    echo "${LOG_PREFIX} [ERROR] $*" >&2
}

log_warn() {
    echo "${LOG_PREFIX} [WARN] $*" >&2
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' not found. Please install $2"
        return 1
    fi
    return 0
}

# ==============================================================================
# Pre-flight Checks
# ==============================================================================

preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check for required commands
    if ! check_command skopeo "skopeo (container image utility)"; then
        log_error "Install skopeo: https://github.com/containers/skopeo"
        exit 1
    fi
    
    # Detect container runtime (nerdctl, ctr, or crictl)
    if command -v nerdctl >/dev/null 2>&1; then
        RUNTIME_CMD="nerdctl --namespace k8s.io"
        log_info "Detected runtime: nerdctl"
    elif command -v ctr >/dev/null 2>&1; then
        RUNTIME_CMD="ctr -n k8s.io"
        log_info "Detected runtime: ctr"
    elif command -v crictl >/dev/null 2>&1; then
        RUNTIME_CMD="crictl"
        log_info "Detected runtime: crictl"
    else
        log_error "No container runtime found (nerdctl, ctr, or crictl)"
        exit 1
    fi
    
    # Check if running as root or with sufficient privileges
    if [ "$(id -u)" -ne 0 ] && ! groups | grep -q docker 2>/dev/null; then
        log_warn "Not running as root. Some operations may require sudo."
    fi
    
    log_success "Pre-flight checks passed"
}

# ==============================================================================
# Tag Selection and Validation
# ==============================================================================

list_available_tags() {
    log_info "Querying available tags from ${FREEIPA_SOURCE_REPO}..."
    
    # Use skopeo to list tags (best-effort, may fail if registry doesn't support it)
    if skopeo list-tags "docker://${FREEIPA_SOURCE_REPO}" 2>/dev/null | head -20; then
        return 0
    else
        log_warn "Could not list tags (registry may not support list-tags API)"
        log_info "Proceeding with specified tag: ${FREEIPA_TAG}"
        return 0
    fi
}

validate_tag_exists() {
    log_info "Validating tag '${FREEIPA_TAG}' exists at ${FREEIPA_SOURCE_REPO}..."
    
    if skopeo inspect "docker://${FREEIPA_SOURCE_REPO}:${FREEIPA_TAG}" >/dev/null 2>&1; then
        log_success "Tag '${FREEIPA_TAG}' validated successfully"
        return 0
    else
        log_error "Tag '${FREEIPA_TAG}' not found at ${FREEIPA_SOURCE_REPO}"
        log_error "Run with FREEIPA_TAG environment variable to specify a different tag"
        return 1
    fi
}

# ==============================================================================
# Image Mirroring
# ==============================================================================

get_image_digest() {
    local image_ref="$1"
    skopeo inspect "docker://${image_ref}" 2>/dev/null | grep -o '"Digest": *"[^"]*"' | cut -d'"' -f4 || echo ""
}

mirror_image() {
    local source_image="${FREEIPA_SOURCE_REPO}:${FREEIPA_TAG}"
    local dest_image="${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    
    log_info "Starting image mirror operation..."
    log_info "  Source: ${source_image}"
    log_info "  Destination: ${dest_image}"
    
    # Get source digest before mirroring
    log_info "Retrieving source image digest..."
    SOURCE_DIGEST=$(get_image_digest "${source_image}")
    if [ -n "${SOURCE_DIGEST}" ]; then
        log_info "  Source digest: ${SOURCE_DIGEST}"
    else
        log_warn "Could not retrieve source digest (proceeding anyway)"
    fi
    
    # Perform the mirror operation using skopeo copy
    log_info "Copying image (this may take several minutes)..."
    if skopeo copy \
        --dest-tls-verify=false \
        "docker://${source_image}" \
        "docker://${dest_image}" 2>&1; then
        log_success "Image copied successfully to local registry"
    else
        log_error "Failed to copy image to local registry"
        log_error "Ensure local registry is running at ${LOCAL_REGISTRY}"
        return 1
    fi
    
    # Verify digest after mirroring (if source digest was available)
    if [ -n "${SOURCE_DIGEST}" ] && [ "${SKIP_VERIFICATION}" != "true" ]; then
        log_info "Verifying image integrity..."
        DEST_DIGEST=$(get_image_digest "${dest_image}")
        if [ -n "${DEST_DIGEST}" ]; then
            log_info "  Destination digest: ${DEST_DIGEST}"
            if [ "${SOURCE_DIGEST}" = "${DEST_DIGEST}" ]; then
                log_success "Image integrity verified (digests match)"
            else
                log_error "Digest mismatch! Image may be corrupted."
                log_error "  Expected: ${SOURCE_DIGEST}"
                log_error "  Got: ${DEST_DIGEST}"
                return 1
            fi
        else
            log_warn "Could not retrieve destination digest for verification"
        fi
    fi
    
    return 0
}

# ==============================================================================
# Image Verification
# ==============================================================================

verify_image_accessible() {
    local image_ref="${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    
    log_info "Verifying image accessibility via container runtime..."
    
    # Try to pull/inspect the image using the detected runtime
    case "${RUNTIME_CMD}" in
        nerdctl*)
            if ${RUNTIME_CMD} inspect "${image_ref}" >/dev/null 2>&1; then
                log_success "Image verified with nerdctl"
                return 0
            fi
            # Try pulling if inspection failed
            log_info "Image not in runtime cache, attempting pull from local registry..."
            if ${RUNTIME_CMD} pull --quiet "${image_ref}" 2>/dev/null; then
                log_success "Image pulled and verified with nerdctl"
                return 0
            fi
            ;;
        ctr*)
            if ${RUNTIME_CMD} images ls -q | grep -q "${image_ref}"; then
                log_success "Image verified with ctr"
                return 0
            fi
            # Try pulling if not found
            log_info "Image not in runtime cache, attempting pull from local registry..."
            if ${RUNTIME_CMD} images pull "${image_ref}" 2>/dev/null; then
                log_success "Image pulled and verified with ctr"
                return 0
            fi
            ;;
        crictl*)
            # crictl doesn't support direct image inspection the same way
            # Check if image exists in the list
            if ${RUNTIME_CMD} images | grep -q "localhost:5000/freeipa-server"; then
                log_success "Image found via crictl"
                return 0
            fi
            ;;
    esac
    
    log_warn "Could not verify image via runtime (this may be normal)"
    log_info "Kubernetes will pull the image when needed"
    return 0
}

# ==============================================================================
# Idempotency Check
# ==============================================================================

check_if_already_mirrored() {
    local dest_image="${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    
    log_info "Checking if image is already mirrored..."
    
    # Check via skopeo (most reliable)
    if skopeo inspect --tls-verify=false "docker://${dest_image}" >/dev/null 2>&1; then
        log_info "Image already exists in local registry"
        
        # Get both digests to compare
        SOURCE_DIGEST=$(get_image_digest "${FREEIPA_SOURCE_REPO}:${FREEIPA_TAG}")
        DEST_DIGEST=$(get_image_digest "${dest_image}")
        
        if [ -n "${SOURCE_DIGEST}" ] && [ -n "${DEST_DIGEST}" ]; then
            if [ "${SOURCE_DIGEST}" = "${DEST_DIGEST}" ]; then
                log_success "Image is up-to-date (digests match)"
                return 0  # Image is current, skip mirroring
            else
                log_info "Image exists but digest differs from source"
                log_info "  Local: ${DEST_DIGEST}"
                log_info "  Remote: ${SOURCE_DIGEST}"
                log_info "Will re-mirror to update..."
                return 1  # Image exists but needs update
            fi
        else
            log_info "Could not compare digests, will re-mirror to ensure latest"
            return 1
        fi
    fi
    
    return 1  # Image not found, needs mirroring
}

# ==============================================================================
# Operator Instructions
# ==============================================================================

print_next_steps() {
    local dest_image="${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    
    cat <<EOF

${LOG_PREFIX} ============================================================
${LOG_PREFIX} Mirror Complete - Next Steps for Operator
${LOG_PREFIX} ============================================================

The FreeIPA image has been successfully mirrored to your local registry.

Image Reference: ${dest_image}

STEP 1: Update FreeIPA StatefulSet
-----------------------------------
Apply the image patch to update the StatefulSet:

    kubectl apply -f /opt/vmstation-org/cluster-infra/manifests/identity/overlays/mirror-image-patch.yaml

OR manually patch the StatefulSet:

    kubectl patch statefulset freeipa -n identity --type='strategic' -p '
    spec:
      template:
        spec:
          containers:
          - name: freeipa-server
            image: ${dest_image}
    '

STEP 2: Monitor Pod Status
---------------------------
Watch the pod restart with the new image:

    kubectl get pods -n identity -w

Check for successful image pull:

    kubectl describe pod freeipa-0 -n identity

STEP 3: Verify FreeIPA Functionality
-------------------------------------
Wait for readiness (may take 5-10 minutes for initialization):

    kubectl wait --for=condition=ready pod/freeipa-0 -n identity --timeout=600s

Check FreeIPA logs:

    kubectl logs -n identity freeipa-0 -f

ROLLBACK (if needed):
---------------------
To revert to a different tag, re-run this script with FREEIPA_TAG:

    sudo FREEIPA_TAG=fedora-39 $0

For more details, see: /opt/vmstation-org/cluster-infra/docs/IDENTITY_FREEIPA_MIRROR.md

${LOG_PREFIX} ============================================================

EOF
}

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
    log_info "FreeIPA Image Mirror Script"
    log_info "============================"
    log_info ""
    log_info "Configuration:"
    log_info "  Source Repository: ${FREEIPA_SOURCE_REPO}"
    log_info "  Tag: ${FREEIPA_TAG}"
    log_info "  Local Registry: ${LOCAL_REGISTRY}"
    log_info "  Destination: ${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    log_info ""
    
    # Run preflight checks
    preflight_checks
    log_info ""
    
    # Validate tag exists
    if ! validate_tag_exists; then
        log_info "Available tags can be viewed at:"
        log_info "  https://quay.io/repository/freeipa/freeipa-server?tab=tags"
        list_available_tags || true
        exit 1
    fi
    log_info ""
    
    # Check if already mirrored (idempotency)
    if check_if_already_mirrored; then
        log_info "Skipping mirror operation (image is current)"
        log_info ""
        verify_image_accessible || true
        log_info ""
        log_success "No action needed - image is already mirrored and up-to-date"
        print_next_steps
        exit 0
    fi
    log_info ""
    
    # Perform mirror operation
    if ! mirror_image; then
        log_error "Mirror operation failed"
        exit 1
    fi
    log_info ""
    
    # Verify image is accessible
    if [ "${SKIP_VERIFICATION}" != "true" ]; then
        verify_image_accessible || true
        log_info ""
    fi
    
    # Success
    log_success "FreeIPA image mirrored successfully"
    log_success "Image is ready at: ${LOCAL_REGISTRY}/${LOCAL_REPO_NAME}:${FREEIPA_TAG}"
    
    # Print operator instructions
    print_next_steps
}

# Run main function
main "$@"
