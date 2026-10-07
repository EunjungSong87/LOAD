-- =====================================================================
--  ASIS vs TOBE 비교 스크립트 (TOBE에서 실행)
--  결과가 0건이면 동일 / 행이 나오면 차이
--  [ASIS>TOBE] = ASIS에만 있음(TOBE 누락) / [TOBE>ASIS] = TOBE에만 있음
-- =====================================================================
--  사전 준비 (TOBE에서 1회)
--    CREATE DATABASE LINK ASIS CONNECT TO system IDENTIFIED BY "****" USING 'ASIS_TNS';
--    SELECT * FROM dual@ASIS;
--  비교 끝나면: DROP DATABASE LINK ASIS;
-- =====================================================================

-- ▼ 대상만 여기서 수정
DEFINE USERS = "'SCOTT','HR'"
DEFINE ROLES = "'APP_ROLE','READ_ROLE'"

SET DEFINE ON VERIFY OFF FEEDBACK ON PAGESIZE 200 LINESIZE 250 TRIMSPOOL ON
COLUMN owner        FORMAT A20
COLUMN grantee      FORMAT A25
COLUMN username     FORMAT A20
COLUMN profile      FORMAT A25
COLUMN role         FORMAT A30
COLUMN privilege    FORMAT A40
COLUMN granted_role FORMAT A30
COLUMN object_name  FORMAT A40
COLUMN object_type  FORMAT A25
COLUMN table_name   FORMAT A35
COLUMN resource_name FORMAT A30
COLUMN limit        FORMAT A30
COLUMN tablespace_name FORMAT A25
COLUMN default_tablespace FORMAT A20
COLUMN temporary_tablespace FORMAT A20
COLUMN account_status FORMAT A20

SPOOL compare_asis_tobe.log

PROMPT
PROMPT ===== 1-1. 프로파일 설정 [ASIS>TOBE] =====
SELECT profile, resource_name, limit FROM dba_profiles@ASIS
 WHERE profile IN (SELECT profile FROM dba_users@ASIS WHERE username IN (&USERS))
MINUS
SELECT profile, resource_name, limit FROM dba_profiles
 WHERE profile IN (SELECT profile FROM dba_users@ASIS WHERE username IN (&USERS))
ORDER BY 1, 2;

PROMPT ===== 1-2. 프로파일 설정 [TOBE>ASIS] =====
SELECT profile, resource_name, limit FROM dba_profiles
 WHERE profile IN (SELECT profile FROM dba_users@ASIS WHERE username IN (&USERS))
MINUS
SELECT profile, resource_name, limit FROM dba_profiles@ASIS
 WHERE profile IN (SELECT profile FROM dba_users@ASIS WHERE username IN (&USERS))
ORDER BY 1, 2;

PROMPT ===== 1-3. 비밀번호 검증 함수 존재 여부 (TOBE에 없으면 출력) =====
SELECT DISTINCT limit AS verify_function FROM dba_profiles@ASIS
 WHERE resource_name = 'PASSWORD_VERIFY_FUNCTION'
   AND limit NOT IN ('NULL','DEFAULT','UNLIMITED')
   AND profile IN (SELECT profile FROM dba_users@ASIS WHERE username IN (&USERS))
MINUS
SELECT object_name FROM dba_objects WHERE owner = 'SYS' AND object_type = 'FUNCTION';

PROMPT
PROMPT ===== 2-1. 롤 존재 [ASIS>TOBE] =====
SELECT role FROM dba_roles@ASIS WHERE role IN (&ROLES)
MINUS
SELECT role FROM dba_roles WHERE role IN (&ROLES);

PROMPT ===== 2-2. 롤 시스템 권한 [ASIS>TOBE] =====
SELECT grantee, privilege, admin_option FROM dba_sys_privs@ASIS WHERE grantee IN (&ROLES)
MINUS
SELECT grantee, privilege, admin_option FROM dba_sys_privs WHERE grantee IN (&ROLES)
ORDER BY 1, 2;

PROMPT ===== 2-3. 롤 시스템 권한 [TOBE>ASIS] =====
SELECT grantee, privilege, admin_option FROM dba_sys_privs WHERE grantee IN (&ROLES)
MINUS
SELECT grantee, privilege, admin_option FROM dba_sys_privs@ASIS WHERE grantee IN (&ROLES)
ORDER BY 1, 2;

PROMPT ===== 2-4. 롤에 부여된 롤 [ASIS>TOBE] =====
SELECT grantee, granted_role, admin_option FROM dba_role_privs@ASIS WHERE grantee IN (&ROLES)
MINUS
SELECT grantee, granted_role, admin_option FROM dba_role_privs WHERE grantee IN (&ROLES)
ORDER BY 1, 2;

PROMPT ===== 2-5. 롤에 부여된 롤 [TOBE>ASIS] =====
SELECT grantee, granted_role, admin_option FROM dba_role_privs WHERE grantee IN (&ROLES)
MINUS
SELECT grantee, granted_role, admin_option FROM dba_role_privs@ASIS WHERE grantee IN (&ROLES)
ORDER BY 1, 2;

PROMPT
PROMPT ===== 3-1. 계정 존재 [ASIS>TOBE] =====
SELECT username FROM dba_users@ASIS WHERE username IN (&USERS)
MINUS
SELECT username FROM dba_users WHERE username IN (&USERS);

PROMPT ===== 3-2. 계정 속성 비교 (다른 항목만, ASIS / TOBE 나란히) =====
SELECT a.username,
       a.account_status       AS asis_status,  t.account_status       AS tobe_status,
       a.default_tablespace   AS asis_def_ts,  t.default_tablespace   AS tobe_def_ts,
       a.temporary_tablespace AS asis_temp_ts, t.temporary_tablespace AS tobe_temp_ts,
       a.profile              AS asis_profile, t.profile              AS tobe_profile
  FROM dba_users@ASIS a
  JOIN dba_users t ON t.username = a.username
 WHERE a.username IN (&USERS)
   AND (   a.account_status       <> t.account_status
        OR a.default_tablespace   <> t.default_tablespace
        OR a.temporary_tablespace <> t.temporary_tablespace
        OR a.profile              <> t.profile)
 ORDER BY 1;

PROMPT ===== 3-3. 계정 비밀번호 해시 동일 여부 (다른 계정만 출력) =====
SELECT a.name AS username
  FROM sys.user$@ASIS a
  JOIN sys.user$ t ON t.name = a.name
 WHERE a.name IN (&USERS)
   AND (NVL(a.spare4,'x') <> NVL(t.spare4,'x') OR NVL(a.password,'x') <> NVL(t.password,'x'));

PROMPT
PROMPT ===== 4-1. 계정 시스템 권한 [ASIS>TOBE] =====
SELECT grantee, privilege, admin_option FROM dba_sys_privs@ASIS WHERE grantee IN (&USERS)
MINUS
SELECT grantee, privilege, admin_option FROM dba_sys_privs WHERE grantee IN (&USERS)
ORDER BY 1, 2;

PROMPT ===== 4-2. 계정 시스템 권한 [TOBE>ASIS] =====
SELECT grantee, privilege, admin_option FROM dba_sys_privs WHERE grantee IN (&USERS)
MINUS
SELECT grantee, privilege, admin_option FROM dba_sys_privs@ASIS WHERE grantee IN (&USERS)
ORDER BY 1, 2;

PROMPT ===== 4-3. 계정 부여 롤 + 기본 롤 [ASIS>TOBE] =====
SELECT grantee, granted_role, admin_option, default_role FROM dba_role_privs@ASIS WHERE grantee IN (&USERS)
MINUS
SELECT grantee, granted_role, admin_option, default_role FROM dba_role_privs WHERE grantee IN (&USERS)
ORDER BY 1, 2;

PROMPT ===== 4-4. 계정 부여 롤 + 기본 롤 [TOBE>ASIS] =====
SELECT grantee, granted_role, admin_option, default_role FROM dba_role_privs WHERE grantee IN (&USERS)
MINUS
SELECT grantee, granted_role, admin_option, default_role FROM dba_role_privs@ASIS WHERE grantee IN (&USERS)
ORDER BY 1, 2;

PROMPT ===== 4-5. 테이블스페이스 쿼터 [ASIS>TOBE] =====
SELECT username, tablespace_name, max_bytes FROM dba_ts_quotas@ASIS WHERE username IN (&USERS)
MINUS
SELECT username, tablespace_name, max_bytes FROM dba_ts_quotas WHERE username IN (&USERS)
ORDER BY 1, 2;

PROMPT ===== 4-6. 테이블스페이스 쿼터 [TOBE>ASIS] =====
SELECT username, tablespace_name, max_bytes FROM dba_ts_quotas WHERE username IN (&USERS)
MINUS
SELECT username, tablespace_name, max_bytes FROM dba_ts_quotas@ASIS WHERE username IN (&USERS)
ORDER BY 1, 2;

PROMPT
PROMPT ===== 5-1. 오브젝트 타입별 건수 (다른 것만) =====
SELECT NVL(a.owner, t.owner) owner, NVL(a.object_type, t.object_type) object_type,
       NVL(a.cnt,0) asis_cnt, NVL(t.cnt,0) tobe_cnt
  FROM (SELECT owner, object_type, COUNT(*) cnt FROM dba_objects@ASIS
         WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%'
         GROUP BY owner, object_type) a
  FULL OUTER JOIN
       (SELECT owner, object_type, COUNT(*) cnt FROM dba_objects
         WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%'
         GROUP BY owner, object_type) t
    ON a.owner = t.owner AND a.object_type = t.object_type
 WHERE NVL(a.cnt,0) <> NVL(t.cnt,0)
 ORDER BY 1, 2;

PROMPT ===== 5-2. 누락 오브젝트 [ASIS>TOBE] (SYS_ 시스템명 제외) =====
SELECT owner, object_type, object_name FROM dba_objects@ASIS
 WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%' AND object_name NOT LIKE 'SYS\_%' ESCAPE '\'
MINUS
SELECT owner, object_type, object_name FROM dba_objects
 WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%' AND object_name NOT LIKE 'SYS\_%' ESCAPE '\'
ORDER BY 1, 2, 3;

PROMPT ===== 5-3. 추가 오브젝트 [TOBE>ASIS] (SYS_ 시스템명 제외) =====
SELECT owner, object_type, object_name FROM dba_objects
 WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%' AND object_name NOT LIKE 'SYS\_%' ESCAPE '\'
MINUS
SELECT owner, object_type, object_name FROM dba_objects@ASIS
 WHERE owner IN (&USERS) AND object_name NOT LIKE 'BIN$%' AND object_name NOT LIKE 'SYS\_%' ESCAPE '\'
ORDER BY 1, 2, 3;

PROMPT ===== 5-4. 제약조건 타입별 건수 (다른 것만) =====
SELECT NVL(a.owner, t.owner) owner, NVL(a.constraint_type, t.constraint_type) constraint_type,
       NVL(a.cnt,0) asis_cnt, NVL(t.cnt,0) tobe_cnt
  FROM (SELECT owner, constraint_type, COUNT(*) cnt FROM dba_constraints@ASIS
         WHERE owner IN (&USERS) AND table_name NOT LIKE 'BIN$%'
         GROUP BY owner, constraint_type) a
  FULL OUTER JOIN
       (SELECT owner, constraint_type, COUNT(*) cnt FROM dba_constraints
         WHERE owner IN (&USERS) AND table_name NOT LIKE 'BIN$%'
         GROUP BY owner, constraint_type) t
    ON a.owner = t.owner AND a.constraint_type = t.constraint_type
 WHERE NVL(a.cnt,0) <> NVL(t.cnt,0)
 ORDER BY 1, 2;

PROMPT ===== 5-5. 테이블별 인덱스 건수 (다른 것만) =====
SELECT NVL(a.table_owner, t.table_owner) owner, NVL(a.table_name, t.table_name) table_name,
       NVL(a.cnt,0) asis_cnt, NVL(t.cnt,0) tobe_cnt
  FROM (SELECT table_owner, table_name, COUNT(*) cnt FROM dba_indexes@ASIS
         WHERE table_owner IN (&USERS) AND table_name NOT LIKE 'BIN$%'
         GROUP BY table_owner, table_name) a
  FULL OUTER JOIN
       (SELECT table_owner, table_name, COUNT(*) cnt FROM dba_indexes
         WHERE table_owner IN (&USERS) AND table_name NOT LIKE 'BIN$%'
         GROUP BY table_owner, table_name) t
    ON a.table_owner = t.table_owner AND a.table_name = t.table_name
 WHERE NVL(a.cnt,0) <> NVL(t.cnt,0)
 ORDER BY 1, 2;

PROMPT
PROMPT ===== 6. TOBE에서만 INVALID (utlrp.sql 재컴파일 후 확인) =====
SELECT owner, object_type, object_name FROM dba_objects
 WHERE owner IN (&USERS) AND status = 'INVALID'
MINUS
SELECT owner, object_type, object_name FROM dba_objects@ASIS
 WHERE owner IN (&USERS) AND status = 'INVALID'
ORDER BY 1, 2, 3;

PROMPT
PROMPT ===== 7-1. 오브젝트 권한 [ASIS>TOBE] =====
SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs@ASIS
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
MINUS
SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
ORDER BY 1, 2, 3, 4;

PROMPT ===== 7-2. 오브젝트 권한 [TOBE>ASIS] =====
SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
MINUS
SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs@ASIS
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
ORDER BY 1, 2, 3, 4;

PROMPT ===== 7-3. 컬럼 권한 [ASIS>TOBE] =====
SELECT grantee, owner, table_name, column_name, privilege FROM dba_col_privs@ASIS
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
MINUS
SELECT grantee, owner, table_name, column_name, privilege FROM dba_col_privs
 WHERE grantee IN (&USERS) OR grantee IN (&ROLES) OR owner IN (&USERS)
ORDER BY 1, 2, 3, 4;

PROMPT
PROMPT ===== 8. 시노님 (PUBLIC 포함, 대상 스키마 오브젝트를 가리키는 것) [ASIS>TOBE] =====
SELECT owner, synonym_name, table_owner, table_name FROM dba_synonyms@ASIS
 WHERE owner IN (&USERS) OR (owner = 'PUBLIC' AND table_owner IN (&USERS))
MINUS
SELECT owner, synonym_name, table_owner, table_name FROM dba_synonyms
 WHERE owner IN (&USERS) OR (owner = 'PUBLIC' AND table_owner IN (&USERS))
ORDER BY 1, 2;

PROMPT
PROMPT ===== 9. 테이블스페이스 암호화 상태 (대상 스키마 사용 TS) =====
SELECT a.tablespace_name, a.encrypted AS asis_enc, t.encrypted AS tobe_enc
  FROM dba_tablespaces@ASIS a
  LEFT JOIN dba_tablespaces t ON t.tablespace_name = a.tablespace_name
 WHERE a.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments@ASIS WHERE owner IN (&USERS))
 ORDER BY 1;

PROMPT
PROMPT ===== 완료 =====
SPOOL OFF
