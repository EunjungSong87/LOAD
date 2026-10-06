SET LONG 1000000 LONGCHUNKSIZE 1000000 PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON FEEDBACK OFF HEADING OFF

BEGIN
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
END;
/

SPOOL user_role_ddl.sql

PROMPT -- 1. ROLE 생성
SELECT DBMS_METADATA.GET_DDL('ROLE', role)
  FROM dba_roles WHERE oracle_maintained = 'N';

PROMPT -- 2. USER 생성
SELECT DBMS_METADATA.GET_DDL('USER', username)
  FROM dba_users WHERE oracle_maintained = 'N';

PROMPT -- 3. TABLESPACE QUOTA
SELECT DBMS_METADATA.GET_GRANTED_DDL('TABLESPACE_QUOTA', username)
  FROM (SELECT DISTINCT username FROM dba_ts_quotas
         WHERE username IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'));

PROMPT -- 4. ROLE 부여 (유저/롤 대상)
SELECT DBMS_METADATA.GET_GRANTED_DDL('ROLE_GRANT', grantee)
  FROM (SELECT DISTINCT grantee FROM dba_role_privs
         WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                           UNION SELECT role FROM dba_roles WHERE oracle_maintained = 'N'));

PROMPT -- 5. 시스템 권한
SELECT DBMS_METADATA.GET_GRANTED_DDL('SYSTEM_GRANT', grantee)
  FROM (SELECT DISTINCT grantee FROM dba_sys_privs
         WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                           UNION SELECT role FROM dba_roles WHERE oracle_maintained = 'N'));

PROMPT -- 6. DEFAULT ROLE
SELECT DBMS_METADATA.GET_GRANTED_DDL('DEFAULT_ROLE', grantee)
  FROM (SELECT DISTINCT grantee FROM dba_role_privs
         WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'));

PROMPT -- 7. 오브젝트 권한 (오브젝트 생성 후 실행)
SELECT DBMS_METADATA.GET_GRANTED_DDL('OBJECT_GRANT', grantee)
  FROM (SELECT DISTINCT grantee FROM dba_tab_privs
         WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                           UNION SELECT role FROM dba_roles WHERE oracle_maintained = 'N'));

SPOOL OFF