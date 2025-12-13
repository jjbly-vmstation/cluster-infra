# SSO Next Steps - Keycloak Configuration

This document describes the next steps for completing SSO (Single Sign-On) setup with Keycloak after the identity stack has been deployed.

## Overview

After running the identity deployment playbook, Keycloak is installed and running, but additional manual configuration is required to:
1. Import the cluster realm configuration
2. Configure LDAP/FreeIPA user federation
3. Create OIDC clients for Grafana and Prometheus
4. Export client secrets to Kubernetes

## Prerequisites

- Keycloak is deployed and accessible via NodePort at `http://<control-plane-ip>:30180`
- Admin credentials are stored at `/root/identity-backup/keycloak-admin-credentials.txt` on the control plane node
- The cluster realm template has been prepared at `/tmp/cluster-realm.json` by Ansible

## Step 1: Access Keycloak Admin Console

1. Access the Keycloak admin console:
   ```bash
   # From your desktop/workstation
   http://<control-plane-ip>:30180/auth/admin
   ```

2. Login with admin credentials:
   ```bash
   # On control plane node, retrieve credentials:
   ssh root@<control-plane-ip>
   cat /root/identity-backup/keycloak-admin-credentials.txt
   ```

## Step 2: Import Cluster Realm

The Ansible playbook has prepared a realm configuration file at `/tmp/cluster-realm.json` with basic settings for the cluster services realm.

### Option A: Import via Admin Console (Manual)

1. In Keycloak admin console, hover over the realm dropdown (top-left, shows "Master")
2. Click "Add realm"
3. Click "Select file" and choose `/tmp/cluster-realm.json` (you'll need to copy it to your local machine first)
4. Click "Create"

### Option B: Import via Helper Script (Semi-Automated)

Use the provided helper script to import the realm via Keycloak's REST API:

```bash
# On control plane node
cd /path/to/cluster-infra

# Set admin credentials as environment variables
export KEYCLOAK_ADMIN_USER=admin
export KEYCLOAK_ADMIN_PASSWORD=<password-from-credentials-file>
export KEYCLOAK_BASE_URL=http://localhost:30180

# Run the import script
./scripts/keycloak-import-realm.sh /tmp/cluster-realm.json
```

## Step 3: Configure LDAP User Federation

After importing the realm, configure FreeIPA LDAP integration:

1. Navigate to your new realm (e.g., "cluster-services")
2. Go to "User Federation" in the left menu
3. Click "Add provider" → "ldap"
4. Configure the following settings:

   **Connection Settings:**
   - Edit Mode: `READ_ONLY` or `WRITABLE` (depending on your needs)
   - Vendor: `Red Hat Directory Server`
   - Connection URL: `ldap://freeipa.identity.svc.cluster.local:389`
   - Users DN: `cn=users,cn=accounts,dc=vmstation,dc=local`
   - Authentication Type: `simple`
   - Bind DN: `uid=admin,cn=users,cn=accounts,dc=vmstation,dc=local`
   - Bind Credential: `<FreeIPA admin password>`

   **LDAP Searching and Updating:**
   - User Object Classes: `inetOrgPerson, organizationalPerson`
   - Username LDAP attribute: `uid`
   - RDN LDAP attribute: `uid`
   - UUID LDAP attribute: `nsuniqueid`

5. Click "Save"
6. Click "Synchronize all users" to import users from FreeIPA

## Step 4: Create OIDC Clients

Create OIDC clients for your monitoring services:

### Grafana Client

1. In your realm, go to "Clients" → "Create"
2. Configure:
   - Client ID: `grafana`
   - Client Protocol: `openid-connect`
   - Root URL: `https://grafana.yourdomain.local` (adjust as needed)
3. Click "Save"
4. Configure the client settings:
   - Access Type: `confidential`
   - Valid Redirect URIs: `https://grafana.yourdomain.local/*`
   - Web Origins: `https://grafana.yourdomain.local`
5. Click "Save"
6. Go to "Credentials" tab and copy the "Secret"

### Prometheus Client (if needed)

1. Similar steps as Grafana, adjust URLs accordingly

## Step 5: Export Client Secrets to Kubernetes

Create Kubernetes secrets with the OIDC client credentials:

```bash
# Create secret for Grafana OIDC client
kubectl create secret generic grafana-oidc \
  -n monitoring \
  --from-literal=client-id=grafana \
  --from-literal=client-secret=<secret-from-keycloak> \
  --dry-run=client -o yaml | kubectl apply -f -

# Create secret for Prometheus OIDC client (if applicable)
kubectl create secret generic prometheus-oidc \
  -n monitoring \
  --from-literal=client-id=prometheus \
  --from-literal=client-secret=<secret-from-keycloak> \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Step 6: Configure Applications to Use OIDC

Update your application configurations (Grafana, Prometheus, etc.) to use the OIDC authentication:

### Example: Grafana Configuration

Add to Grafana's configuration or Helm values:

```yaml
auth.generic_oauth:
  enabled: true
  name: Keycloak
  allow_sign_up: true
  client_id: grafana
  client_secret: <secret-from-kubernetes-secret>
  scopes: openid email profile
  auth_url: http://<control-plane-ip>:30180/auth/realms/cluster-services/protocol/openid-connect/auth
  token_url: http://keycloak.identity.svc.cluster.local/auth/realms/cluster-services/protocol/openid-connect/token
  api_url: http://keycloak.identity.svc.cluster.local/auth/realms/cluster-services/protocol/openid-connect/userinfo
```

## Automation Considerations

For production environments, consider:

1. **Using the Keycloak Admin CLI**: The `kcadm.sh` tool provides full API access
2. **Infrastructure as Code**: Export realm configuration and manage via Git
3. **Secret Management**: Use Vault or Sealed Secrets for OIDC credentials
4. **Backup**: Regular backups of Keycloak PostgreSQL database and realm exports

## Troubleshooting

### Realm Import Fails

- Verify `/tmp/cluster-realm.json` exists and is valid JSON
- Check Keycloak logs: `kubectl logs -n identity keycloak-0`
- Ensure admin credentials are correct

### LDAP Connection Issues

- Verify FreeIPA is running: `kubectl get pods -n identity`
- Test DNS resolution: `kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup freeipa.identity.svc.cluster.local`
- Check FreeIPA logs: `kubectl logs -n identity <freeipa-pod>`

### OIDC Client Authentication Fails

- Verify redirect URIs match exactly (including trailing slashes)
- Check client secret is correctly configured in application
- Review Keycloak events: Realm Settings → Events → Login Events

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Keycloak Admin CLI](https://www.keycloak.org/docs/latest/server_admin/#the-admin-cli)
- [FreeIPA Integration](https://www.keycloak.org/docs/latest/server_admin/#ldap-and-active-directory)
- [Grafana OAuth Configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)

## Support

For issues or questions about the identity stack:
1. Check cluster documentation in `docs/`
2. Review Ansible playbook logs
3. Consult Keycloak and FreeIPA documentation
