# Integrating Applications with Keycloak SSO

## Overview

This guide explains how to integrate new applications with the Keycloak SSO system deployed in the VMStation cluster.

## Prerequisites

- Keycloak deployed and accessible at `http://192.168.4.63:30080/auth`
- `cluster-services` realm created and configured
- FreeIPA LDAP user federation configured
- Admin access to Keycloak console

## Integration Methods

Keycloak supports multiple authentication protocols:
- **OIDC (OpenID Connect)**: Recommended for modern web applications
- **SAML 2.0**: For enterprise applications requiring SAML
- **OAuth 2.0**: For API authentication and authorization

## OIDC Integration (Recommended)

### Step 1: Create OIDC Client in Keycloak

1. Access Keycloak admin console: `http://192.168.4.63:30080/auth/admin/`
2. Select the `cluster-services` realm
3. Navigate to **Clients** → **Create**
4. Configure client:
   - **Client ID**: `your-app-name` (e.g., `grafana`)
   - **Client Protocol**: `openid-connect`
   - **Root URL**: `http://your-app.vmstation.local`
5. Click **Save**

### Step 2: Configure Client Settings

In the client configuration:

**Settings Tab**:
- **Access Type**: `confidential` (for web apps) or `public` (for SPAs)
- **Standard Flow Enabled**: ON
- **Direct Access Grants Enabled**: ON (optional, for API access)
- **Valid Redirect URIs**: Add all valid callback URLs
  ```
  http://your-app.vmstation.local/*
  http://192.168.4.63:30XXX/*
  ```
- **Web Origins**: `+` (allows all origins from redirect URIs)

**Credentials Tab**:
- Note the **Client Secret** (for confidential clients)

**Mappers Tab** (optional):
- Add custom claims to tokens
- Map LDAP attributes to token claims

### Step 3: Create Kubernetes Secret for Client Credentials

```bash
kubectl create secret generic your-app-oidc-secret \
  -n your-namespace \
  --from-literal=client-id=your-app-name \
  --from-literal=client-secret=<secret-from-keycloak> \
  --from-literal=issuer-url=http://192.168.4.63:30080/auth/realms/cluster-services
```

### Step 4: Configure Application

Each application configures OIDC differently. Common configuration parameters:

```yaml
oidc:
  client_id: your-app-name
  client_secret: <from-kubernetes-secret>
  issuer_url: http://192.168.4.63:30080/auth/realms/cluster-services
  redirect_uri: http://your-app.vmstation.local/callback
  scopes:
    - openid
    - profile
    - email
```

## Application-Specific Examples

### Grafana

**1. Create Keycloak Client**:
- Client ID: `grafana`
- Valid Redirect URIs: `http://192.168.4.63:30300/*`

**2. Configure Grafana** (`grafana.ini` or Helm values):
```ini
[auth.generic_oauth]
enabled = true
name = Keycloak
allow_sign_up = true
client_id = grafana
client_secret = <secret>
scopes = openid email profile
auth_url = http://192.168.4.63:30080/auth/realms/cluster-services/protocol/openid-connect/auth
token_url = http://192.168.4.63:30080/auth/realms/cluster-services/protocol/openid-connect/token
api_url = http://192.168.4.63:30080/auth/realms/cluster-services/protocol/openid-connect/userinfo
```

**3. Helm Chart Values**:
```yaml
grafana:
  env:
    GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
    GF_AUTH_GENERIC_OAUTH_NAME: "Keycloak"
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID: "grafana"
  envFromSecret: grafana-oidc-secret
```

### Prometheus

Prometheus doesn't natively support OIDC, but you can use OAuth2 Proxy:

**1. Deploy OAuth2 Proxy**:
```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm install oauth2-proxy oauth2-proxy/oauth2-proxy \
  -n monitoring \
  --set config.clientID=prometheus \
  --set config.clientSecret=<secret> \
  --set config.oidcIssuerUrl=http://192.168.4.63:30080/auth/realms/cluster-services
```

**2. Configure Ingress**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.monitoring.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "http://oauth2-proxy.vmstation.local/oauth2/start"
spec:
  rules:
  - host: prometheus.vmstation.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus
            port:
              number: 9090
```

### ArgoCD

**1. Create Keycloak Client**:
- Client ID: `argocd`
- Valid Redirect URIs: `https://argocd.vmstation.local/auth/callback`

**2. Configure ArgoCD**:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  oidc.config: |
    name: Keycloak
    issuer: http://192.168.4.63:30080/auth/realms/cluster-services
    clientID: argocd
    clientSecret: <secret>
    requestedScopes: ["openid", "profile", "email", "groups"]
```

### GitLab

**1. Create Keycloak Client**:
- Client ID: `gitlab`
- Valid Redirect URIs: `https://gitlab.vmstation.local/users/auth/openid_connect/callback`

**2. Configure GitLab** (`gitlab.rb`):
```ruby
gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: 'Keycloak',
    args: {
      name: 'openid_connect',
      scope: ['openid', 'profile', 'email'],
      response_type: 'code',
      issuer: 'http://192.168.4.63:30080/auth/realms/cluster-services',
      client_auth_method: 'query',
      discovery: true,
      uid_field: 'preferred_username',
      client_options: {
        identifier: 'gitlab',
        secret: '<secret>',
        redirect_uri: 'https://gitlab.vmstation.local/users/auth/openid_connect/callback'
      }
    }
  }
]
```

## Role-Based Access Control (RBAC)

### Define Roles in Keycloak

1. In `cluster-services` realm, go to **Roles**
2. Create realm roles:
   - `cluster-admin`: Full administrative access
   - `cluster-operator`: Operational access
   - `cluster-viewer`: Read-only access
   - `cluster-user`: Basic user access

### Assign Roles to Users

1. Go to **Users** → Select user → **Role Mappings**
2. Assign appropriate realm roles
3. Roles are automatically included in OIDC tokens

### Map Roles to Application Permissions

Each application interprets roles differently:

**Grafana**:
```ini
[auth.generic_oauth]
role_attribute_path = contains(realm_access.roles[*], 'cluster-admin') && 'Admin' || contains(realm_access.roles[*], 'cluster-operator') && 'Editor' || 'Viewer'
```

**ArgoCD**:
```yaml
policy.csv: |
  p, role:cluster-admin, applications, *, */*, allow
  p, role:cluster-operator, applications, get, */*, allow
  p, role:cluster-viewer, applications, get, */*, allow
  g, cluster-admin, role:cluster-admin
  g, cluster-operator, role:cluster-operator
```

## Group-Based Access Control

### Create Groups in FreeIPA

```bash
# Access FreeIPA pod
kubectl exec -it -n identity freeipa-0 -- bash

# Create groups
ipa group-add cluster-admins --desc="Cluster Administrators"
ipa group-add cluster-operators --desc="Cluster Operators"
ipa group-add cluster-users --desc="Cluster Users"

# Add users to groups
ipa group-add-member cluster-admins --users=admin,john
ipa group-add-member cluster-operators --users=jane
```

### Map Groups to Keycloak Roles

1. In Keycloak, go to **User Federation** → **ldap** → **Mappers**
2. Create mapper:
   - **Mapper Type**: `group-ldap-mapper`
   - **LDAP Groups DN**: `cn=groups,cn=accounts,dc=vmstation,dc=local`
   - **Group Object Classes**: `groupOfNames`
   - **Membership Attribute**: `member`

3. Synchronize groups: **User Federation** → **ldap** → **Synchronize all users**

### Group-to-Role Mapping

1. Go to **Groups** → Select group (e.g., `cluster-admins`)
2. Go to **Role Mappings**
3. Assign roles (e.g., `cluster-admin` role to `cluster-admins` group)

Users in the group automatically get the assigned roles.

## Testing SSO Integration

### Test with curl

```bash
# Get access token
TOKEN=$(curl -X POST \
  'http://192.168.4.63:30080/auth/realms/cluster-services/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=your-app' \
  -d 'client_secret=<secret>' \
  -d 'username=testuser' \
  -d 'password=testpass' \
  -d 'grant_type=password' | jq -r '.access_token')

# Decode token to see claims
echo $TOKEN | cut -d'.' -f2 | base64 -d | jq

# Use token to access protected resource
curl -H "Authorization: Bearer $TOKEN" http://your-app.vmstation.local/api/user
```

### Test with Browser

1. Access application: `http://your-app.vmstation.local`
2. Click "Login" or "Sign in with SSO"
3. Redirected to Keycloak login page
4. Enter FreeIPA username and password
5. Redirected back to application with active session

## Troubleshooting

### Redirect URI Mismatch

**Error**: `Invalid parameter: redirect_uri`

**Solution**: Add the exact redirect URI to client's Valid Redirect URIs list in Keycloak.

### Invalid Client Secret

**Error**: `Unauthorized` or `Invalid client credentials`

**Solution**:
1. Verify client secret in Keycloak **Clients** → **Credentials** tab
2. Update Kubernetes secret with correct secret
3. Restart application pods

### User Not Found

**Error**: User exists in FreeIPA but cannot login

**Solution**:
1. Verify LDAP user federation is configured
2. Synchronize users: **User Federation** → **ldap** → **Synchronize all users**
3. Check user exists: **Users** → **View all users**
4. Verify user is enabled in Keycloak

### Token Validation Fails

**Error**: Application rejects token

**Solution**:
1. Verify issuer URL matches Keycloak realm URL exactly
2. Check token expiration (default 5 minutes)
3. Verify application is using correct public key from Keycloak
4. Check network connectivity from application to Keycloak

## Security Best Practices

1. **Use HTTPS in Production**:
   - Configure Ingress with TLS
   - Update all URLs to use `https://`
   - Enable HSTS headers

2. **Rotate Client Secrets**:
   - Rotate secrets every 90 days
   - Update Kubernetes secrets after rotation
   - Restart application pods

3. **Configure Token Lifetimes**:
   - Access token: 5-15 minutes
   - Refresh token: 30 minutes
   - SSO session: 10 hours (adjust as needed)

4. **Enable Brute Force Protection**:
   - Keycloak → Realm Settings → Security Defenses
   - Enable brute force detection
   - Configure lockout durations

5. **Audit Logging**:
   - Enable Keycloak event logging
   - Monitor login attempts
   - Alert on suspicious activity

## Additional Resources

- [Keycloak OIDC Documentation](https://www.keycloak.org/docs/latest/securing_apps/#_oidc)
- [OAuth 2.0 Proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
- [Grafana OAuth Documentation](https://grafana.com/docs/grafana/latest/auth/generic-oauth/)
- [OIDC Debugger](https://oidcdebugger.com/) - Test OIDC flows

## Next Steps

1. Add more OIDC clients for additional applications
2. Configure MFA for sensitive applications
3. Set up automated token refresh
4. Implement custom claims and mappers
5. Configure fine-grained authorization policies
