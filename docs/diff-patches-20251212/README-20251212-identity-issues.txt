This directory contains patches and notes for the Keycloak startup and DB environment persistence fix.

0002-persist-keycloak-startup.patch
  - Adds an Ansible task to ensure the keycloak-startup ConfigMap contains the desired startup script (removes stop-embedded-server
    so Keycloak does not immediately stop the embedded server during initialization) and restarts the Keycloak pod to pick up changes.
  - Also persists the previously-added StatefulSet env patch so Keycloak uses PostgreSQL.

Applied on: 2025-12-12T18:49:33.692Z
