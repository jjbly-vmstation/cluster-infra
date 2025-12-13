#!/bin/bash
#
# Keycloak Realm Import Helper Script
#
# This script imports a Keycloak realm configuration via the Keycloak Admin REST API.
# It's a semi-automated helper to simplify realm import for cluster SSO setup.
#
# USAGE:
#   export KEYCLOAK_ADMIN_USER=admin
#   export KEYCLOAK_ADMIN_PASSWORD=<password>
#   export KEYCLOAK_BASE_URL=http://localhost:30180
#   export KEYCLOAK_FORCE_UPDATE=true  # Optional: force update without prompting
#   ./keycloak-import-realm.sh /path/to/realm.json
#
# PREREQUISITES:
#   - jq (JSON processor)
#   - curl (HTTP client)
#   - Keycloak is running and accessible
#
# NOTE: This is an intentionally simple stub script. For production use,
# consider using the official Keycloak Admin CLI (kcadm.sh) for more
# robust realm management.
#

set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    local missing=0
    
    if ! command -v curl &> /dev/null; then
        error "curl is not installed"
        missing=1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq is not installed"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        error "Please install missing prerequisites"
        exit 1
    fi
}

# Validate environment variables
validate_env() {
    if [ -z "${KEYCLOAK_ADMIN_USER:-}" ]; then
        error "KEYCLOAK_ADMIN_USER environment variable is not set"
        exit 1
    fi
    
    if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
        error "KEYCLOAK_ADMIN_PASSWORD environment variable is not set"
        exit 1
    fi
    
    if [ -z "${KEYCLOAK_BASE_URL:-}" ]; then
        warn "KEYCLOAK_BASE_URL not set, using default: http://localhost:30180"
        KEYCLOAK_BASE_URL="http://localhost:30180"
    fi
}

# Validate realm file
validate_realm_file() {
    local realm_file=$1
    
    if [ ! -f "$realm_file" ]; then
        error "Realm file not found: $realm_file"
        exit 1
    fi
    
    if ! jq empty "$realm_file" 2>/dev/null; then
        error "Invalid JSON in realm file: $realm_file"
        exit 1
    fi
    
    # Check if file contains realm configuration
    if ! jq -e '.realm' "$realm_file" &>/dev/null; then
        error "Realm file does not contain a 'realm' field"
        exit 1
    fi
}

# Get admin access token
get_admin_token() {
    local token_url="${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token"
    
    info "Authenticating as admin user..."
    
    local response
    if ! response=$(curl -s -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${KEYCLOAK_ADMIN_USER}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>&1); then
        error "Failed to authenticate with Keycloak"
        error "Response: $response"
        exit 1
    fi
    
    local access_token
    access_token=$(echo "$response" | jq -r '.access_token // empty')
    
    if [ -z "$access_token" ] || [ "$access_token" == "null" ]; then
        error "Failed to obtain access token"
        error "Response: $response"
        exit 1
    fi
    
    echo "$access_token"
}

# Import realm
import_realm() {
    local realm_file=$1
    local access_token=$2
    local admin_url="${KEYCLOAK_BASE_URL}/auth/admin/realms"
    
    local realm_name
    realm_name=$(jq -r '.realm' "$realm_file")
    
    info "Importing realm: $realm_name"
    
    # Check if realm already exists
    local check_response
    check_response=$(curl -s -w "\n%{http_code}" -X GET "${admin_url}/${realm_name}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json")
    
    local http_code
    http_code=$(echo "$check_response" | tail -n1)
    
    if [ "$http_code" == "200" ]; then
        warn "Realm '$realm_name' already exists"
        
        # Check if running in non-interactive mode or force flag is set
        if [ "${KEYCLOAK_FORCE_UPDATE:-false}" == "true" ]; then
            info "Force update enabled, proceeding with realm update..."
        elif [ ! -t 0 ]; then
            error "Realm already exists and running in non-interactive mode. Set KEYCLOAK_FORCE_UPDATE=true to force update."
            exit 1
        else
            read -p "Do you want to update it? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Import cancelled"
                exit 0
            fi
        fi
        
        # Update existing realm
        info "Updating existing realm..."
        local update_response
        update_response=$(curl -s -w "\n%{http_code}" -X PUT "${admin_url}/${realm_name}" \
            -H "Authorization: Bearer ${access_token}" \
            -H "Content-Type: application/json" \
            -d @"$realm_file")
        
        http_code=$(echo "$update_response" | tail -n1)
        
        if [ "$http_code" == "204" ] || [ "$http_code" == "200" ]; then
            info "Realm updated successfully"
        else
            error "Failed to update realm (HTTP $http_code)"
            error "Response: $(echo "$update_response" | head -n -1)"
            exit 1
        fi
    else
        # Create new realm
        info "Creating new realm..."
        local create_response
        create_response=$(curl -s -w "\n%{http_code}" -X POST "$admin_url" \
            -H "Authorization: Bearer ${access_token}" \
            -H "Content-Type: application/json" \
            -d @"$realm_file")
        
        http_code=$(echo "$create_response" | tail -n1)
        
        if [ "$http_code" == "201" ]; then
            info "Realm created successfully"
        else
            error "Failed to create realm (HTTP $http_code)"
            error "Response: $(echo "$create_response" | head -n -1)"
            exit 1
        fi
    fi
}

# Main function
main() {
    echo "======================================"
    echo "Keycloak Realm Import Helper"
    echo "======================================"
    echo
    
    if [ $# -ne 1 ]; then
        error "Usage: $0 <realm-json-file>"
        exit 1
    fi
    
    local realm_file=$1
    
    check_prerequisites
    validate_env
    validate_realm_file "$realm_file"
    
    local access_token
    access_token=$(get_admin_token)
    
    import_realm "$realm_file" "$access_token"
    
    echo
    info "======================================"
    info "Realm import completed successfully!"
    info "======================================"
    echo
    info "Next steps:"
    echo "  1. Access Keycloak admin console: ${KEYCLOAK_BASE_URL}/auth/admin"
    echo "  2. Configure LDAP user federation (see docs/SSO_NEXT_STEPS.md)"
    echo "  3. Create OIDC clients for your applications"
    echo "  4. Export client secrets to Kubernetes"
    echo
}

# Run main function
main "$@"
