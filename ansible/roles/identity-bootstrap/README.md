# identity-bootstrap role

This role is a scaffold to: 

- Import pre-generated certificates produced by `cluster-setup/scripts/generate_certs.sh`.
- Install and configure FreeIPA (FreeIPA acts as a CA and identity provider).
- Install and configure Keycloak for SAML/SSO fronting (optional, depending on architecture).
- Configure `cert-manager` to use the FreeIPA CA as an issuer so certificate handling can be delegated to the identity stack.

Current status: stub. The tasks in `tasks/main.yml` are placeholders and need concrete implementation.

Recommended implementation steps:

1. Implement `roles/freeipa` and `roles/keycloak` (or reuse upstream roles) to install those services.
2. After FreeIPA is installed, import the pre-generated CA (`ca.cert.pem`) into FreeIPA's CA store if desired, or create an Issuer that points directly at FreeIPA's CA signing API.
3. Configure `cert-manager` with a ClusterIssuer that uses FreeIPA as a CA (cert-manager supports external CA through the `issuer` API or via a Vault issuer).
4. Migrate certificate management to `cert-manager` and retire manual distribution steps.
