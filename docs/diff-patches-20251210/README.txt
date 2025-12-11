This directory contains backups and logs related to forcing Keycloak to bootstrap an admin user.
Actions performed (timestamped):
- Scaled StatefulSet keycloak to 0 replicas to stop Keycloak before wiping DB.
- Backed up the keycloak database to keycloak-<ts>.dump (custom format) in this directory.
- Dropped and recreated the public schema in the keycloak database to make it empty.
- Scaled StatefulSet keycloak back to 1 replica to allow Keycloak to initialize with KEYCLOAK_ADMIN secret.

If KEYCLOAK_ADMIN and KEYCLOAK_ADMIN_PASSWORD are set in a secret named 'keycloak-admin' and consumed by the StatefulSet, Keycloak should bootstrap the master admin user on first initialization.

Files:
- keycloak-<ts>.dump  : DB backup
- keycloak-post-bootstrap.log : Keycloak logs after restart
- post-bootstrap-users.txt : SQL query showing master realm users after bootstrap
- commands.sh : exact commands run (for auditing)

If this fails, restore the DB from the dump with 'pg_restore -U keycloak -d keycloak <dumpfile>' or kubectl cp it back into the pod and run pg_restore inside the pod.
