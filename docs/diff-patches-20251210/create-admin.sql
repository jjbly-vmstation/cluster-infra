BEGIN;
-- create admin user in master realm
INSERT INTO user_entity (id, email, email_constraint, email_verified, enabled, first_name, last_name, realm_id, username, created_timestamp)
VALUES ('82ff1682-6b1d-4fe0-8d14-726ef7f38f7b', 'admin@local', lower('admin@local'), true, true, 'Admin', 'User', 'master', 'admin', 1765395876158);

-- create credential with pbkdf2-sha256
INSERT INTO credential (id, salt, type, user_id, created_date, user_label, secret_data, credential_data, priority)
VALUES ('59dfd16a-8060-49bf-87ec-d4c5261a8848', decode('KSB+KDAextEA39/YNiTBvQ==','base64'), 'password', '82ff1682-6b1d-4fe0-8d14-726ef7f38f7b', 1765395876158, NULL, NULL, $${"algorithm":"pbkdf2-sha256","hashIterations":27500,"salt":"KSB+KDAextEA39/YNiTBvQ==","value":"c6ELHaowLD227ehvLXWZKpezz6VTm2KfRWAFMstv3Is="}$$, 0);

-- map realm admin role to user
INSERT INTO user_role_mapping (role_id, user_id)
SELECT id, '82ff1682-6b1d-4fe0-8d14-726ef7f38f7b' FROM keycloak_role WHERE name='admin' AND realm_id=(SELECT id FROM realm WHERE name='master') LIMIT 1;

COMMIT;
-- show created user
SELECT id, username, enabled FROM user_entity WHERE id='82ff1682-6b1d-4fe0-8d14-726ef7f38f7b';
SELECT role_id FROM user_role_mapping WHERE user_id='82ff1682-6b1d-4fe0-8d14-726ef7f38f7b';

