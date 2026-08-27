EXEC DBMS_SQLTUNE.CREATE_SQLSET(
  sqlset_name => 'STS_MIGRATION',
  description => 'AS-IS workload capture'
);


[AS-IS] 2. 워크로드 적재 (AWR 스냅샷 구간 기준)

sql
DECLARE
  cur SYS_REFCURSOR;
BEGIN
  OPEN cur FOR
    SELECT VALUE(P) FROM TABLE(
      DBMS_SQLTUNE.SELECT_WORKLOAD_REPOSITORY(
        begin_snap     => 1000,
        end_snap       => 1010,
        basic_filter   => 'parsing_schema_name = ''APP_SCHEMA''',
        attribute_list => 'ALL'
      )
    ) P;
  DBMS_SQLTUNE.LOAD_SQLSET(sqlset_name => 'STS_MIGRATION', populate_cursor => cur);
END;
/


[AS-IS] 3. 스테이징 테이블 생성 + PACK

STS는 SYSAUX에 있어서 직접 옮길 수 없기 때문에, 일반 테이블 형태로 감싸서 이동합니다.

sql
EXEC DBMS_SQLTUNE.CREATE_STGTAB_SQLSET(
  table_name    => 'STS_STAGE_TAB',
  schema_name   => 'SCHEMA_NAME'
);

EXEC DBMS_SQLTUNE.PACK_STGTAB_SQLSET(
  sqlset_name           => 'STS_MIGRATION',
  staging_table_name    => 'STS_STAGE_TAB',
  staging_schema_owner  => 'SCHEMA_NAME'
);

[전송] 4. 스테이징 테이블만 dmp로 반출/반입

앞서 얘기한 일반 dmp 방식으로 이 테이블 하나만 export/import하면 됩니다.

sql
expdp schema/pwd DIRECTORY=dpump_dir DUMPFILE=sts_stage.dmp \
  TABLES=SCHEMA_NAME.STS_STAGE_TAB

impdp schema/pwd DIRECTORY=dpump_dir DUMPFILE=sts_stage.dmp \
  TABLES=SCHEMA_NAME.STS_STAGE_TAB

[TO-BE] 5. UNPACK으로 STS 복원

sql
EXEC DBMS_SQLTUNE.UNPACK_STGTAB_SQLSET(
  sqlset_name           => 'STS_MIGRATION',
  replace               => TRUE,
  staging_table_name    => 'STS_STAGE_TAB',
  staging_schema_owner  => 'SCHEMA_NAME'
);

[TO-BE] 6. SPA(SQL Performance Analyzer) Task 생성 및 실행

sql
EXEC DBMS_SQLPA.CREATE_ANALYSIS_TASK(
  sqlset_name => 'STS_MIGRATION',
  task_name   => 'SPA_MIGRATION_TASK'
);

EXEC DBMS_SQLPA.EXECUTE_ANALYSIS_TASK(
  task_name       => 'SPA_MIGRATION_TASK',
  execution_type  => 'test execute',
  execution_name  => 'tobe_baseline'
);

[TO-BE] 7. 결과 리포트 확인

sql
SELECT DBMS_SQLPA.REPORT_ANALYSIS_TASK(
  task_name  => 'SPA_MIGRATION_TASK',
  type       => 'text',
  level      => 'typical',
  section    => 'summary'
) AS REPORT
FROM DUAL;

AS-IS 쪽에서도 동일한 STS로 미리 test execute를 한 번 떠서 execution_name을 다르게(예: asis_baseline) 남겨뒀다면, TO-BE에서 두 실행 결과를 compare performance로 비교해서 실행계획/성능 변화를 바로 확인할 수 있습니다.

sql
EXEC DBMS_SQLPA.EXECUTE_ANALYSIS_TASK(
  task_name       => 'SPA_MIGRATION_TASK',
  execution_type  => 'compare performance',
  execution_params => DBMS_ADVISOR.ARGLIST(
    'execution_name1', 'asis_baseline',
    'execution_name2', 'tobe_baseline'
  )
);

참고

STS 대신 바로 SQL Plan Baseline을 심고 싶은 거라면 UNPACK 이후 DBMS_SPM.LOAD_PLANS_FROM_SQLSET을 쓰는 방법도 있습니다. 목적이 "실행계획 고정"이면 이쪽, "성능/계획 변화 검증"이면 SPA 쪽입니다.
지금 하려는 게 마이그레이션 후 성능 회귀 체크 목적이 맞으신가요, 아니면 SQL Plan Baseline을 새 환경에 미리 심어두려는 목적인가요?