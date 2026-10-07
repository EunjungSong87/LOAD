-- =====================================================================
--  CMP_PKG : ASIS(DB 링크) vs TOBE(로컬) 스키마 오브젝트 비교
--            + ASIS 기준으로 TOBE를 맞추는 DDL 스크립트 생성
--  Oracle 19c / TOBE에서 생성 및 실행
--
--  [ASIS 안전성]
--    - ASIS에는 DBA_ 뷰 SELECT 와 DBMS_METADATA(network_link) 메타데이터 읽기만 수행.
--      INSERT/UPDATE/DELETE/DDL/프로시저 실행 등 ASIS 를 바꾸는 동작은 없음.
--    - 모든 동적 SQL 은 실행 전에 SELECT/WITH 로 시작하는지 검사(assert_readonly).
--    - 생성되는 보정 DDL 은 "텍스트로 출력만" 하며, 패키지가 직접 실행하지 않음.
--    - DB 링크 조회 후 세션에 분산 트랜잭션이 열려 있으니 끝나면 ROLLBACK 또는
--      ALTER SESSION CLOSE DATABASE LINK <링크명>; 로 정리.
--
--  [설치]  DBA 권한 계정(예: SYSTEM)으로 이 파일 실행
--          SQL> @cmp_pkg.sql
--
--  [사용]
--   1) 차이 리포트
--      SET SERVEROUTPUT ON SIZE UNLIMITED LINESIZE 300
--      EXEC cmp_pkg.report('ASIS', 'SCOTT,HR');
--
--   2) ASIS 기준 보정 DDL 스크립트 생성 (검토 후 TOBE 에서 실행)
--      SET SERVEROUTPUT ON SIZE UNLIMITED LINESIZE 32767 TRIMSPOOL ON FEEDBACK OFF
--      SPOOL fix_tobe.sql
--      EXEC cmp_pkg.fix_script('ASIS', 'SCOTT,HR');
--      SPOOL OFF
--
--   3) 결과를 행으로 조회 (DBeaver 등 어느 툴이든, FIX_DDL 컬럼에 보정 DDL)
--      SELECT * FROM TABLE(cmp_pkg.compare_objects('ASIS', 'SCOTT,HR'))
--       ORDER BY fix_order, owner, obj_name;
--
--   4) 특정 항목만 / DDL 없이 빠르게
--      SELECT * FROM TABLE(cmp_pkg.compare_objects('ASIS', 'SCOTT', 'MISSING,EXTRA', 'N'));
--
--  [비교 항목 p_checks]  기본 'ALL'  (쉼표로 여러 개)
--    COUNT      : 오브젝트 타입별 건수                      (보정 DDL 없음, 요약용)
--    MISSING    : ASIS에만 있는 오브젝트                    -> ASIS DDL (CREATE)
--    EXTRA      : TOBE에만 있는 오브젝트                    -> DROP (주석 처리)
--    INVALID    : TOBE에서만 INVALID                        -> ALTER ... COMPILE
--    COLUMN     : 양쪽에 다 있는 테이블의 컬럼 정의          -> ADD / MODIFY / DROP(주석)
--    CONSTRAINT : 이름 있는 제약조건 누락/추가, SYS_C 건수   -> ASIS DDL / DROP(주석)
--    INDEX      : 테이블별 인덱스 건수                      (보정 DDL 없음, MISSING 참고)
--    VIEW       : 양쪽에 다 있는 뷰의 텍스트 길이            -> ASIS DDL (CREATE OR REPLACE)
--    SOURCE     : 양쪽에 다 있는 PL/SQL 코드 라인/글자 수   -> ASIS DDL (CREATE OR REPLACE)
--    GRANT      : 오브젝트 권한                              -> GRANT / REVOKE(주석)
--
--  결과 0건이면 동일. 휴지통(BIN$)과 SYS_ 로 시작하는 시스템 생성 이름은 이름 비교에서 제외.
--  AUTHID CURRENT_USER + 동적 SQL 이라 DBA 롤만 있으면 동작.
--  DB 링크 접속 계정도 ASIS 에서 DBA_ 뷰 조회 및 다른 스키마 메타데이터 조회 권한
--  (SELECT_CATALOG_ROLE 또는 DBA)이 필요.
-- =====================================================================

CREATE OR REPLACE PACKAGE cmp_pkg AUTHID CURRENT_USER AS

  TYPE t_row IS RECORD (
    check_name VARCHAR2(30),
    owner      VARCHAR2(128),
    obj_type   VARCHAR2(200),
    obj_name   VARCHAR2(1000),
    asis_val   VARCHAR2(4000),
    tobe_val   VARCHAR2(4000),
    fix_order  NUMBER,
    fix_ddl    CLOB
  );
  TYPE t_tab IS TABLE OF t_row;

  -- 차이 나는 행만 반환 (p_with_ddl = 'Y' 면 FIX_DDL 에 ASIS 기준 보정 DDL 포함)
  FUNCTION compare_objects (
    p_dblink   IN VARCHAR2,
    p_owners   IN VARCHAR2,                 -- 'SCOTT,HR'
    p_checks   IN VARCHAR2 DEFAULT 'ALL',
    p_with_ddl IN VARCHAR2 DEFAULT 'Y'
  ) RETURN t_tab PIPELINED;

  -- 차이 리포트 (DBMS_OUTPUT)
  PROCEDURE report (
    p_dblink IN VARCHAR2,
    p_owners IN VARCHAR2,
    p_checks IN VARCHAR2 DEFAULT 'ALL'
  );

  -- ASIS 기준 보정 DDL 스크립트 (DBMS_OUTPUT, 실행 순서대로 정렬)
  PROCEDURE fix_script (
    p_dblink IN VARCHAR2,
    p_owners IN VARCHAR2,
    p_checks IN VARCHAR2 DEFAULT 'ALL'
  );

END cmp_pkg;
/

CREATE OR REPLACE PACKAGE BODY cmp_pkg AS

  c_all_checks CONSTANT VARCHAR2(200) :=
    'COUNT,MISSING,EXTRA,INVALID,COLUMN,CONSTRAINT,INDEX,VIEW,SOURCE,GRANT';

  -- 이름 비교용 필터
  c_name_filter CONSTANT VARCHAR2(500) :=
    q'[ AND object_name NOT LIKE 'BIN$%'
        AND object_name NOT LIKE 'SYS\_%' ESCAPE '\'
        AND object_type NOT LIKE '%PARTITION'
        AND object_type NOT IN ('LOB') ]';

  -- 컬럼 타입을 DDL 그대로 쓸 수 있는 형태로
  c_col_spec CONSTANT VARCHAR2(2000) := q'[
    CASE
      WHEN data_type IN ('VARCHAR2','CHAR')
        THEN data_type || '(' || DECODE(char_used, 'C', char_length || ' CHAR', data_length || ' BYTE') || ')'
      WHEN data_type IN ('NVARCHAR2','NCHAR')
        THEN data_type || '(' || char_length || ')'
      WHEN data_type IN ('RAW','UROWID')
        THEN data_type || '(' || data_length || ')'
      WHEN data_type = 'NUMBER' THEN
        CASE WHEN data_precision IS NULL AND data_scale IS NULL THEN 'NUMBER'
             WHEN data_precision IS NULL THEN 'NUMBER(*,' || data_scale || ')'
             WHEN NVL(data_scale, 0) = 0 THEN 'NUMBER(' || data_precision || ')'
             ELSE 'NUMBER(' || data_precision || ',' || data_scale || ')' END
      WHEN data_type = 'FLOAT' THEN 'FLOAT(' || data_precision || ')'
      ELSE data_type
    END ]';

  -- 양쪽에 모두 있는 테이블
  c_common_tables CONSTANT VARCHAR2(1000) := q'[
    cmn AS (
      SELECT owner, table_name FROM dba_tables@#L#
       WHERE owner IN (#O#) AND table_name NOT LIKE 'BIN$%'
      INTERSECT
      SELECT owner, table_name FROM dba_tables
       WHERE owner IN (#O#) AND table_name NOT LIKE 'BIN$%') ]';

  -- ---------------------------------------------------------------
  PROCEDURE p (s IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE put_clob (p_text IN CLOB) IS
    v_len PLS_INTEGER;
    v_pos PLS_INTEGER := 1;
    v_nl  PLS_INTEGER;
  BEGIN
    IF p_text IS NULL THEN RETURN; END IF;
    v_len := DBMS_LOB.GETLENGTH(p_text);
    WHILE v_pos <= v_len LOOP
      v_nl := DBMS_LOB.INSTR(p_text, CHR(10), v_pos);
      IF v_nl = 0 THEN v_nl := v_len + 1; END IF;
      p(RTRIM(DBMS_LOB.SUBSTR(p_text, LEAST(v_nl - v_pos, 32000), v_pos), CHR(13)));
      v_pos := v_nl + 1;
    END LOOP;
  END put_clob;

  -- ASIS 로 가는 SQL 은 SELECT/WITH 만 허용
  PROCEDURE assert_readonly (p_sql IN VARCHAR2) IS
  BEGIN
    IF NOT REGEXP_LIKE(p_sql, '^\s*(SELECT|WITH)\s', 'in') THEN
      RAISE_APPLICATION_ERROR(-20009, '읽기 전용 위반: SELECT 문만 실행할 수 있습니다.');
    END IF;
  END assert_readonly;

  -- ---------------------------------------------------------------
  FUNCTION check_link (p_dblink IN VARCHAR2) RETURN VARCHAR2 IS
    v_link VARCHAR2(200);
    v_cnt  NUMBER;
    v_dual VARCHAR2(1);
  BEGIN
    IF p_dblink IS NULL THEN
      RAISE_APPLICATION_ERROR(-20001, 'DB 링크 이름을 입력하세요.');
    END IF;

    v_link := DBMS_ASSERT.QUALIFIED_SQL_NAME(TRIM(p_dblink));

    EXECUTE IMMEDIATE
      'SELECT COUNT(*) FROM dba_db_links WHERE UPPER(db_link) = :1 OR UPPER(db_link) LIKE :2'
      INTO v_cnt USING UPPER(v_link), UPPER(v_link) || '.%';

    IF v_cnt = 0 THEN
      RAISE_APPLICATION_ERROR(-20002, 'DB 링크가 없습니다: ' || v_link);
    END IF;

    BEGIN
      EXECUTE IMMEDIATE 'SELECT dummy FROM dual@' || v_link INTO v_dual;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20003, 'DB 링크 연결 실패 (' || v_link || '): ' || SQLERRM);
    END;

    RETURN v_link;
  END check_link;

  FUNCTION owner_list (p_owners IN VARCHAR2) RETURN VARCHAR2 IS
    v_list VARCHAR2(32767);
    v_item VARCHAR2(200);
    i      PLS_INTEGER := 1;
  BEGIN
    LOOP
      v_item := TRIM(REGEXP_SUBSTR(p_owners, '[^,]+', 1, i));
      EXIT WHEN v_item IS NULL;
      v_list := v_list || CASE WHEN i > 1 THEN ',' END
                       || DBMS_ASSERT.ENQUOTE_LITERAL(UPPER(v_item));
      i := i + 1;
    END LOOP;
    IF v_list IS NULL THEN
      RAISE_APPLICATION_ERROR(-20004, '스키마 목록이 비어 있습니다.');
    END IF;
    RETURN v_list;
  END owner_list;

  FUNCTION is_on (p_checks IN VARCHAR2, p_check IN VARCHAR2) RETURN BOOLEAN IS
    v VARCHAR2(400) := UPPER(REPLACE(NVL(p_checks, 'ALL'), ' '));
  BEGIN
    RETURN v = 'ALL' OR INSTR(',' || v || ',', ',' || p_check || ',') > 0;
  END is_on;

  -- ---------------------------------------------------------------
  -- 실행 순서 (작을수록 먼저, 100 이상은 스크립트에서 제외)
  -- ---------------------------------------------------------------
  FUNCTION get_fix_order (p_check IN VARCHAR2, p_type IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    IF p_type = 'ERROR' THEN RETURN 200; END IF;
    IF p_check IN ('COUNT','INDEX') OR p_type LIKE 'SYS_C COUNT%' THEN RETURN 100; END IF;
    IF p_check = 'EXTRA' OR p_type LIKE '%(EXTRA)' THEN RETURN 99; END IF;
    IF p_check = 'INVALID' THEN RETURN 98; END IF;
    IF p_check = 'GRANT'   THEN RETURN 90; END IF;
    IF p_check = 'COLUMN'  THEN RETURN 30; END IF;
    RETURN CASE p_type
             WHEN 'DATABASE LINK'     THEN 5
             WHEN 'SEQUENCE'          THEN 10
             WHEN 'TYPE'              THEN 15
             WHEN 'TABLE'             THEN 20
             WHEN 'CONSTRAINT'        THEN 40
             WHEN 'REF_CONSTRAINT'    THEN 45
             WHEN 'INDEX'             THEN 50
             WHEN 'VIEW'              THEN 60
             WHEN 'MATERIALIZED VIEW' THEN 62
             WHEN 'FUNCTION'          THEN 70
             WHEN 'PROCEDURE'         THEN 70
             WHEN 'PACKAGE'           THEN 72
             WHEN 'PACKAGE BODY'      THEN 74
             WHEN 'TYPE BODY'         THEN 76
             WHEN 'TRIGGER'           THEN 80
             WHEN 'SYNONYM'           THEN 85
             WHEN 'JOB'               THEN 95
             ELSE 88
           END;
  END get_fix_order;

  FUNCTION needs_meta (p_check IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p_check IN ('MISSING','CONSTRAINT','VIEW','SOURCE');
  END needs_meta;

  -- ---------------------------------------------------------------
  -- ASIS 메타데이터로 DDL 추출 (DBMS_METADATA network_link, 읽기 전용)
  -- ---------------------------------------------------------------
  FUNCTION remote_ddl (p_link IN VARCHAR2, p_type IN VARCHAR2,
                       p_owner IN VARCHAR2, p_name IN VARCHAR2) RETURN CLOB IS
    v_mtype VARCHAR2(30);
    h       NUMBER;
    th      NUMBER;
    v_ddl   CLOB;
  BEGIN
    v_mtype := CASE p_type
                 WHEN 'TABLE'             THEN 'TABLE'
                 WHEN 'INDEX'             THEN 'INDEX'
                 WHEN 'VIEW'              THEN 'VIEW'
                 WHEN 'SEQUENCE'          THEN 'SEQUENCE'
                 WHEN 'SYNONYM'           THEN 'SYNONYM'
                 WHEN 'FUNCTION'          THEN 'FUNCTION'
                 WHEN 'PROCEDURE'         THEN 'PROCEDURE'
                 WHEN 'TRIGGER'           THEN 'TRIGGER'
                 WHEN 'PACKAGE'           THEN 'PACKAGE_SPEC'
                 WHEN 'PACKAGE BODY'      THEN 'PACKAGE_BODY'
                 WHEN 'TYPE'              THEN 'TYPE_SPEC'
                 WHEN 'TYPE BODY'         THEN 'TYPE_BODY'
                 WHEN 'MATERIALIZED VIEW' THEN 'MATERIALIZED_VIEW'
                 WHEN 'DATABASE LINK'     THEN 'DB_LINK'
                 WHEN 'JOB'               THEN 'PROCOBJ'
                 WHEN 'LIBRARY'           THEN 'LIBRARY'
                 WHEN 'JAVA SOURCE'       THEN 'JAVA_SOURCE'
                 WHEN 'CONSTRAINT'        THEN 'CONSTRAINT'
                 WHEN 'REF_CONSTRAINT'    THEN 'REF_CONSTRAINT'
                 ELSE NULL
               END;

    IF v_mtype IS NULL THEN
      RETURN '-- 자동 DDL 미지원 타입: ' || p_type || ' "' || p_owner || '"."' || p_name || '" (수동 확인)';
    END IF;

    h := DBMS_METADATA.OPEN(object_type => v_mtype, network_link => p_link);
    DBMS_METADATA.SET_FILTER(h, 'SCHEMA', p_owner);
    DBMS_METADATA.SET_FILTER(h, 'NAME', p_name);
    th := DBMS_METADATA.ADD_TRANSFORM(h, 'DDL');
    DBMS_METADATA.SET_TRANSFORM_PARAM(th, 'SQLTERMINATOR', TRUE);
    DBMS_METADATA.SET_TRANSFORM_PARAM(th, 'PRETTY', TRUE);
    v_ddl := DBMS_METADATA.FETCH_CLOB(h);
    DBMS_METADATA.CLOSE(h);

    RETURN NVL(v_ddl, TO_CLOB('-- ASIS DDL 추출 결과 없음: ' || p_type || ' "' || p_owner || '"."' || p_name || '"'));
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        IF h IS NOT NULL THEN DBMS_METADATA.CLOSE(h); END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      RETURN '-- ASIS DDL 추출 실패: ' || p_type || ' "' || p_owner || '"."' || p_name || '" : '
             || SUBSTR(SQLERRM, 1, 500);
  END remote_ddl;

  -- ---------------------------------------------------------------
  -- 항목별 SQL : owner, obj_type, obj_name, asis_val, tobe_val, fix_ddl
  --   #L# DB 링크 / #O# 스키마 목록 / #F# 이름 필터 / #S# 컬럼 타입식 / #C# 공통 테이블
  --   fix_ddl 이 NULL 이고 needs_meta 항목이면 ASIS 메타데이터로 채움
  -- ---------------------------------------------------------------
  FUNCTION get_sql (p_check IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    CASE p_check

    WHEN 'COUNT' THEN RETURN q'[
      SELECT NVL(a.owner, t.owner), NVL(a.object_type, t.object_type), CAST(NULL AS VARCHAR2(1)),
             TO_CHAR(NVL(a.cnt, 0)), TO_CHAR(NVL(t.cnt, 0)),
             '-- 건수 요약 (MISSING / EXTRA 항목 참고)'
        FROM (SELECT owner, object_type, COUNT(*) cnt FROM dba_objects@#L#
               WHERE owner IN (#O#) AND object_name NOT LIKE 'BIN$%'
               GROUP BY owner, object_type) a
        FULL OUTER JOIN
             (SELECT owner, object_type, COUNT(*) cnt FROM dba_objects
               WHERE owner IN (#O#) AND object_name NOT LIKE 'BIN$%'
               GROUP BY owner, object_type) t
          ON a.owner = t.owner AND a.object_type = t.object_type
       WHERE NVL(a.cnt, 0) <> NVL(t.cnt, 0)
       ORDER BY 1, 2]';

    WHEN 'MISSING' THEN RETURN q'[
      SELECT owner, object_type, object_name, 'EXISTS', 'MISSING', CAST(NULL AS VARCHAR2(1))
        FROM (SELECT owner, object_type, object_name FROM dba_objects@#L#
               WHERE owner IN (#O#) #F#
              MINUS
              SELECT owner, object_type, object_name FROM dba_objects
               WHERE owner IN (#O#) #F#)
       ORDER BY 1, 2, 3]';

    WHEN 'EXTRA' THEN RETURN q'[
      SELECT owner, object_type, object_name, 'MISSING', 'EXISTS',
             '-- DROP ' || object_type || ' "' || owner || '"."' || object_name || '";'
        FROM (SELECT owner, object_type, object_name FROM dba_objects
               WHERE owner IN (#O#) #F#
              MINUS
              SELECT owner, object_type, object_name FROM dba_objects@#L#
               WHERE owner IN (#O#) #F#)
       ORDER BY 1, 2, 3]';

    WHEN 'INVALID' THEN RETURN q'[
      SELECT t.owner, t.object_type, t.object_name, NVL(a.status, '(ASIS 없음)'), t.status,
             CASE t.object_type
               WHEN 'PACKAGE BODY' THEN 'ALTER PACKAGE "' || t.owner || '"."' || t.object_name || '" COMPILE BODY;'
               WHEN 'TYPE BODY'    THEN 'ALTER TYPE "'    || t.owner || '"."' || t.object_name || '" COMPILE BODY;'
               ELSE 'ALTER ' || t.object_type || ' "' || t.owner || '"."' || t.object_name || '" COMPILE;'
             END
        FROM (SELECT owner, object_type, object_name, status FROM dba_objects
               WHERE owner IN (#O#) AND status = 'INVALID' AND object_name NOT LIKE 'BIN$%'
                 AND subobject_name IS NULL) t
        LEFT JOIN
             (SELECT owner, object_type, object_name, status FROM dba_objects@#L#
               WHERE owner IN (#O#) AND object_name NOT LIKE 'BIN$%' AND subobject_name IS NULL) a
          ON a.owner = t.owner AND a.object_type = t.object_type AND a.object_name = t.object_name
       WHERE NVL(a.status, 'X') <> 'INVALID'
       ORDER BY 1, 2, 3]';

    WHEN 'COLUMN' THEN RETURN q'[
      WITH #C#
      SELECT NVL(a.owner, t.owner), 'COLUMN',
             NVL(a.table_name, t.table_name) || '.' || NVL(a.column_name, t.column_name),
             CASE WHEN a.column_name IS NULL THEN '(없음)'
                  ELSE a.spec || ' ' || DECODE(a.nullable, 'N', 'NOT NULL', 'NULL') END,
             CASE WHEN t.column_name IS NULL THEN '(없음)'
                  ELSE t.spec || ' ' || DECODE(t.nullable, 'N', 'NOT NULL', 'NULL') END,
             CASE
               WHEN t.column_name IS NULL THEN
                 'ALTER TABLE "' || a.owner || '"."' || a.table_name || '" ADD ("' || a.column_name || '" '
                 || a.spec || DECODE(a.nullable, 'N', ' NOT NULL') || ');'
               WHEN a.column_name IS NULL THEN
                 '-- ALTER TABLE "' || t.owner || '"."' || t.table_name || '" DROP COLUMN "' || t.column_name || '";'
               ELSE
                 'ALTER TABLE "' || a.owner || '"."' || a.table_name || '" MODIFY ("' || a.column_name || '"'
                 || CASE WHEN a.spec <> t.spec THEN ' ' || a.spec END
                 || CASE WHEN a.nullable <> t.nullable THEN DECODE(a.nullable, 'N', ' NOT NULL', ' NULL') END
                 || ');'
             END
        FROM (SELECT owner, table_name, column_name, #S# spec, nullable
                FROM dba_tab_columns@#L#
               WHERE owner IN (#O#)
                 AND (owner, table_name) IN (SELECT owner, table_name FROM cmn)) a
        FULL OUTER JOIN
             (SELECT owner, table_name, column_name, #S# spec, nullable
                FROM dba_tab_columns
               WHERE owner IN (#O#)
                 AND (owner, table_name) IN (SELECT owner, table_name FROM cmn)) t
          ON a.owner = t.owner AND a.table_name = t.table_name AND a.column_name = t.column_name
       WHERE a.column_name IS NULL OR t.column_name IS NULL
          OR a.spec <> t.spec OR a.nullable <> t.nullable
       ORDER BY 1, 3]';

    WHEN 'CONSTRAINT' THEN RETURN q'[
      WITH #C#
      SELECT a.owner, DECODE(a.constraint_type, 'R', 'REF_CONSTRAINT', 'CONSTRAINT'), a.constraint_name,
             a.table_name || ' (' || a.constraint_type || ')', 'MISSING', CAST(NULL AS VARCHAR2(1))
        FROM dba_constraints@#L# a
       WHERE a.owner IN (#O#)
         AND a.constraint_type IN ('P','U','R','C')
         AND a.constraint_name NOT LIKE 'SYS\_%' ESCAPE '\'
         AND a.constraint_name NOT LIKE 'BIN$%'
         AND (a.owner, a.table_name) IN (SELECT owner, table_name FROM cmn)
         AND (a.owner, a.constraint_name) NOT IN
             (SELECT owner, constraint_name FROM dba_constraints WHERE owner IN (#O#))
      UNION ALL
      SELECT t.owner, 'CONSTRAINT(EXTRA)', t.constraint_name,
             'MISSING', t.table_name || ' (' || t.constraint_type || ')',
             '-- ALTER TABLE "' || t.owner || '"."' || t.table_name || '" DROP CONSTRAINT "' || t.constraint_name || '";'
        FROM dba_constraints t
       WHERE t.owner IN (#O#)
         AND t.constraint_type IN ('P','U','R','C')
         AND t.constraint_name NOT LIKE 'SYS\_%' ESCAPE '\'
         AND t.constraint_name NOT LIKE 'BIN$%'
         AND (t.owner, t.table_name) IN (SELECT owner, table_name FROM cmn)
         AND (t.owner, t.constraint_name) NOT IN
             (SELECT owner, constraint_name FROM dba_constraints@#L# WHERE owner IN (#O#))
      UNION ALL
      SELECT NVL(a.owner, t.owner), 'SYS_C COUNT(' || NVL(a.constraint_type, t.constraint_type) || ')',
             NVL(a.table_name, t.table_name), TO_CHAR(NVL(a.cnt, 0)), TO_CHAR(NVL(t.cnt, 0)),
             '-- 시스템 이름 제약조건 건수 차이 (NOT NULL 은 COLUMN 항목 참고)'
        FROM (SELECT owner, table_name, constraint_type, COUNT(*) cnt FROM dba_constraints@#L#
               WHERE owner IN (#O#) AND constraint_type IN ('P','U','R','C')
                 AND constraint_name LIKE 'SYS\_%' ESCAPE '\'
               GROUP BY owner, table_name, constraint_type) a
        FULL OUTER JOIN
             (SELECT owner, table_name, constraint_type, COUNT(*) cnt FROM dba_constraints
               WHERE owner IN (#O#) AND constraint_type IN ('P','U','R','C')
                 AND constraint_name LIKE 'SYS\_%' ESCAPE '\'
               GROUP BY owner, table_name, constraint_type) t
          ON a.owner = t.owner AND a.table_name = t.table_name AND a.constraint_type = t.constraint_type
       WHERE NVL(a.cnt, 0) <> NVL(t.cnt, 0)
         AND (NVL(a.owner, t.owner), NVL(a.table_name, t.table_name)) IN (SELECT owner, table_name FROM cmn)
       ORDER BY 1, 3, 2]';

    WHEN 'INDEX' THEN RETURN q'[
      WITH #C#
      SELECT NVL(a.table_owner, t.table_owner), 'INDEX COUNT', NVL(a.table_name, t.table_name),
             TO_CHAR(NVL(a.cnt, 0)), TO_CHAR(NVL(t.cnt, 0)),
             '-- 인덱스 건수 차이 (MISSING / EXTRA 의 INDEX 항목 참고)'
        FROM (SELECT table_owner, table_name, COUNT(*) cnt FROM dba_indexes@#L#
               WHERE table_owner IN (#O#) AND index_type <> 'LOB'
                 AND (table_owner, table_name) IN (SELECT owner, table_name FROM cmn)
               GROUP BY table_owner, table_name) a
        FULL OUTER JOIN
             (SELECT table_owner, table_name, COUNT(*) cnt FROM dba_indexes
               WHERE table_owner IN (#O#) AND index_type <> 'LOB'
                 AND (table_owner, table_name) IN (SELECT owner, table_name FROM cmn)
               GROUP BY table_owner, table_name) t
          ON a.table_owner = t.table_owner AND a.table_name = t.table_name
       WHERE NVL(a.cnt, 0) <> NVL(t.cnt, 0)
       ORDER BY 1, 3]';

    WHEN 'VIEW' THEN RETURN q'[
      SELECT a.owner, 'VIEW', a.view_name,
             'text_length ' || a.text_length, 'text_length ' || t.text_length, CAST(NULL AS VARCHAR2(1))
        FROM (SELECT owner, view_name, text_length FROM dba_views@#L# WHERE owner IN (#O#)) a
        JOIN (SELECT owner, view_name, text_length FROM dba_views WHERE owner IN (#O#)) t
          ON a.owner = t.owner AND a.view_name = t.view_name
       WHERE NVL(a.text_length, -1) <> NVL(t.text_length, -1)
       ORDER BY 1, 3]';

    WHEN 'SOURCE' THEN RETURN q'[
      SELECT a.owner, a.type, a.name,
             a.lines || ' lines / ' || a.chars || ' chars',
             t.lines || ' lines / ' || t.chars || ' chars',
             CAST(NULL AS VARCHAR2(1))
        FROM (SELECT owner, type, name, COUNT(*) lines, SUM(LENGTH(text)) chars FROM dba_source@#L#
               WHERE owner IN (#O#) AND name NOT LIKE 'BIN$%'
               GROUP BY owner, type, name) a
        JOIN (SELECT owner, type, name, COUNT(*) lines, SUM(LENGTH(text)) chars FROM dba_source
               WHERE owner IN (#O#) AND name NOT LIKE 'BIN$%'
               GROUP BY owner, type, name) t
          ON a.owner = t.owner AND a.type = t.type AND a.name = t.name
       WHERE a.lines <> t.lines OR NVL(a.chars, -1) <> NVL(t.chars, -1)
       ORDER BY 1, 2, 3]';

    WHEN 'GRANT' THEN RETURN q'[
      SELECT owner, 'GRANT ' || privilege,
             table_name || ' TO ' || grantee || DECODE(grantable, 'YES', ' (WITH GRANT OPTION)'),
             'EXISTS', 'MISSING',
             'GRANT ' || privilege || ' ON "' || owner || '"."' || table_name || '" TO "' || grantee || '"'
             || DECODE(grantable, 'YES', ' WITH GRANT OPTION') || ';'
        FROM (SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs@#L#
               WHERE (owner IN (#O#) OR grantee IN (#O#)) AND table_name NOT LIKE 'BIN$%'
              MINUS
              SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs
               WHERE (owner IN (#O#) OR grantee IN (#O#)) AND table_name NOT LIKE 'BIN$%')
      UNION ALL
      SELECT owner, 'GRANT ' || privilege,
             table_name || ' TO ' || grantee || DECODE(grantable, 'YES', ' (WITH GRANT OPTION)'),
             'MISSING', 'EXISTS',
             '-- REVOKE ' || privilege || ' ON "' || owner || '"."' || table_name || '" FROM "' || grantee || '";'
        FROM (SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs
               WHERE (owner IN (#O#) OR grantee IN (#O#)) AND table_name NOT LIKE 'BIN$%'
              MINUS
              SELECT grantee, owner, table_name, privilege, grantable FROM dba_tab_privs@#L#
               WHERE (owner IN (#O#) OR grantee IN (#O#)) AND table_name NOT LIKE 'BIN$%')
       ORDER BY 1, 3, 2]';

    END CASE;
  END get_sql;

  FUNCTION build_sql (p_check IN VARCHAR2, p_link IN VARCHAR2, p_own IN VARCHAR2) RETURN VARCHAR2 IS
    v_sql VARCHAR2(32767);
  BEGIN
    v_sql := get_sql(p_check);
    v_sql := REPLACE(v_sql, '#C#', c_common_tables);
    v_sql := REPLACE(v_sql, '#S#', c_col_spec);
    v_sql := REPLACE(v_sql, '#F#', c_name_filter);
    v_sql := REPLACE(v_sql, '#L#', p_link);
    v_sql := REPLACE(v_sql, '#O#', p_own);
    assert_readonly(v_sql);
    RETURN v_sql;
  END build_sql;

  -- ---------------------------------------------------------------
  FUNCTION compare_objects (
    p_dblink   IN VARCHAR2,
    p_owners   IN VARCHAR2,
    p_checks   IN VARCHAR2 DEFAULT 'ALL',
    p_with_ddl IN VARCHAR2 DEFAULT 'Y'
  ) RETURN t_tab PIPELINED IS
    v_link VARCHAR2(200)   := check_link(p_dblink);
    v_own  VARCHAR2(32767) := owner_list(p_owners);
    v_chk  VARCHAR2(30);
    rc     SYS_REFCURSOR;
    r      t_row;
    i      PLS_INTEGER := 1;
  BEGIN
    LOOP
      v_chk := REGEXP_SUBSTR(c_all_checks, '[^,]+', 1, i);
      EXIT WHEN v_chk IS NULL;

      IF is_on(p_checks, v_chk) THEN
        BEGIN
          OPEN rc FOR build_sql(v_chk, v_link, v_own);
          LOOP
            FETCH rc INTO r.owner, r.obj_type, r.obj_name, r.asis_val, r.tobe_val, r.fix_ddl;
            EXIT WHEN rc%NOTFOUND;
            r.check_name := v_chk;
            r.fix_order  := get_fix_order(v_chk, r.obj_type);
            IF UPPER(p_with_ddl) = 'Y' AND r.fix_ddl IS NULL AND needs_meta(v_chk) THEN
              r.fix_ddl := remote_ddl(v_link, r.obj_type, r.owner, r.obj_name);
            END IF;
            PIPE ROW (r);
          END LOOP;
          CLOSE rc;
        EXCEPTION
          WHEN NO_DATA_NEEDED THEN
            IF rc%ISOPEN THEN CLOSE rc; END IF;
            RAISE;
          WHEN OTHERS THEN
            IF rc%ISOPEN THEN CLOSE rc; END IF;
            r.check_name := v_chk;
            r.owner      := NULL;
            r.obj_type   := 'ERROR';
            r.obj_name   := SUBSTR(SQLERRM, 1, 1000);
            r.asis_val   := NULL;
            r.tobe_val   := NULL;
            r.fix_order  := 200;
            r.fix_ddl    := NULL;
            PIPE ROW (r);
        END;
      END IF;

      i := i + 1;
    END LOOP;
    RETURN;
  EXCEPTION
    WHEN NO_DATA_NEEDED THEN
      RETURN;
  END compare_objects;

  -- ---------------------------------------------------------------
  PROCEDURE report (
    p_dblink IN VARCHAR2,
    p_owners IN VARCHAR2,
    p_checks IN VARCHAR2 DEFAULT 'ALL'
  ) IS
    TYPE t_cnt IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(30);
    v_cnt   t_cnt;
    rc      SYS_REFCURSOR;
    r       t_row;
    v_prev  VARCHAR2(30) := '#';
    v_chk   VARCHAR2(30);
    v_total PLS_INTEGER := 0;
    i       PLS_INTEGER := 1;
  BEGIN
    p('==========================================================================================');
    p(' ASIS vs TOBE 오브젝트 비교   ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    p(' DB 링크 : ' || p_dblink || '    스키마 : ' || UPPER(p_owners) || '    항목 : ' || UPPER(NVL(p_checks, 'ALL')));
    p('==========================================================================================');

    OPEN rc FOR
      'SELECT * FROM TABLE(' || $$PLSQL_UNIT_OWNER || '.CMP_PKG.COMPARE_OBJECTS(:1, :2, :3, ''N''))'
      USING p_dblink, p_owners, p_checks;
    LOOP
      FETCH rc INTO r;
      EXIT WHEN rc%NOTFOUND;

      IF r.check_name <> v_prev THEN
        p(CHR(10) || '----- [' || r.check_name || '] ---------------------------------------------------------');
        p(RPAD('OWNER', 15) || ' ' || RPAD('TYPE', 25) || ' ' || RPAD('NAME', 50) || ' '
          || RPAD('ASIS', 30) || ' TOBE');
        v_prev := r.check_name;
      END IF;

      p(RPAD(NVL(r.owner, ' '), 15) || ' ' || RPAD(NVL(r.obj_type, ' '), 25) || ' '
        || RPAD(NVL(r.obj_name, ' '), 50) || ' ' || RPAD(NVL(r.asis_val, ' '), 30) || ' '
        || r.tobe_val);

      v_cnt(r.check_name) := CASE WHEN v_cnt.EXISTS(r.check_name) THEN v_cnt(r.check_name) ELSE 0 END + 1;
      v_total := v_total + 1;
    END LOOP;
    CLOSE rc;

    p(CHR(10) || '==================== 요약 ====================');
    LOOP
      v_chk := REGEXP_SUBSTR(c_all_checks, '[^,]+', 1, i);
      EXIT WHEN v_chk IS NULL;
      IF is_on(p_checks, v_chk) THEN
        p(RPAD(v_chk, 12) || ' : '
          || CASE WHEN v_cnt.EXISTS(v_chk) THEN v_cnt(v_chk) || ' 건 차이' ELSE 'OK' END);
      END IF;
      i := i + 1;
    END LOOP;
    p('----------------------------------------------');
    p('총 차이 : ' || v_total || ' 건');
    IF v_total > 0 THEN
      p('보정 DDL : EXEC cmp_pkg.fix_script(''' || p_dblink || ''', ''' || p_owners || ''');');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF rc%ISOPEN THEN CLOSE rc; END IF;
      RAISE;
  END report;

  -- ---------------------------------------------------------------
  PROCEDURE fix_script (
    p_dblink IN VARCHAR2,
    p_owners IN VARCHAR2,
    p_checks IN VARCHAR2 DEFAULT 'ALL'
  ) IS
    v_link  VARCHAR2(200) := check_link(p_dblink);
    rc      SYS_REFCURSOR;
    r       t_row;
    v_n     PLS_INTEGER := 0;
    v_err   PLS_INTEGER := 0;
    v_sect  NUMBER := -1;
  BEGIN
    p('-- =====================================================================');
    p('--  ASIS 기준 TOBE 보정 스크립트');
    p('--  생성 : ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS')
      || '   DB 링크 : ' || v_link || '   스키마 : ' || UPPER(p_owners));
    p('--  반드시 검토 후 TOBE 에서 실행하세요. (ASIS 에는 아무것도 실행되지 않음)');
    p('--  "-- " 로 시작하는 DROP / REVOKE 는 TOBE 에만 있는 것이라 주석 처리됨');
    p('-- =====================================================================');
    p('SET DEFINE OFF');
    p('SET SQLBLANKLINES ON');
    p('WHENEVER SQLERROR CONTINUE');

    OPEN rc FOR
      'SELECT * FROM TABLE(' || $$PLSQL_UNIT_OWNER || '.CMP_PKG.COMPARE_OBJECTS(:1, :2, :3, ''N''))'
      || ' WHERE fix_order < 100 OR fix_order = 200 ORDER BY fix_order, owner, obj_name'
      USING p_dblink, p_owners, p_checks;
    LOOP
      FETCH rc INTO r;
      EXIT WHEN rc%NOTFOUND;

      IF r.obj_type = 'ERROR' THEN
        p('');
        p('-- [ERROR] ' || r.check_name || ' 비교 실패 : ' || r.obj_name);
        v_err := v_err + 1;
        CONTINUE;
      END IF;

      IF r.fix_order <> v_sect THEN
        p('');
        p('-- ---------------------------------------------------------------------');
        p('-- ' || CASE
                     WHEN r.fix_order = 99 THEN 'TOBE 에만 있는 것 (주석 처리, 필요 시 해제)'
                     WHEN r.fix_order = 98 THEN 'INVALID 재컴파일'
                     WHEN r.fix_order = 90 THEN '오브젝트 권한'
                     WHEN r.fix_order = 30 THEN '컬럼 보정'
                     ELSE r.obj_type
                   END);
        p('-- ---------------------------------------------------------------------');
        v_sect := r.fix_order;
      END IF;

      IF r.fix_ddl IS NULL AND needs_meta(r.check_name) THEN
        r.fix_ddl := remote_ddl(v_link, r.obj_type, r.owner, r.obj_name);
      END IF;

      p('');
      p('-- [' || r.check_name || '] ' || r.obj_type || ' ' || r.owner || '.' || r.obj_name
        || '   (ASIS: ' || r.asis_val || ' / TOBE: ' || r.tobe_val || ')');
      put_clob(r.fix_ddl);
      v_n := v_n + 1;
    END LOOP;
    CLOSE rc;

    p('');
    p('-- ---------------------------------------------------------------------');
    p('-- 마지막으로 전체 재컴파일 권장 : @?/rdbms/admin/utlrp.sql');
    p('-- 보정 항목 : ' || v_n || ' 건' || CASE WHEN v_err > 0 THEN '   /   비교 실패 : ' || v_err || ' 건' END);
    p('-- ---------------------------------------------------------------------');
  EXCEPTION
    WHEN OTHERS THEN
      IF rc%ISOPEN THEN CLOSE rc; END IF;
      RAISE;
  END fix_script;

END cmp_pkg;
/

SHOW ERRORS PACKAGE cmp_pkg
SHOW ERRORS PACKAGE BODY cmp_pkg
