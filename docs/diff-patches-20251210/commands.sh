#!/bin/sh
# Commands used to perform bootstrap
kubectl -n identity scale statefulset keycloak --replicas=0
kubectl exec -n identity keycloak-postgresql-0 -- pg_dump -U keycloak -d keycloak -F c -f /tmp/keycloak-<ts>.dump
kubectl cp identity/keycloak-postgresql-0:/tmp/keycloak-<ts>.dump ./keycloak-<ts>.dump
kubectl exec -n identity keycloak-postgresql-0 -- psql -U keycloak -d keycloak -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
kubectl -n identity scale statefulset keycloak --replicas=1
kubectl -n identity wait --for=condition=ready pod/keycloak-0 --timeout=300s
