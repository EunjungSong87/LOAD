#!/bin/ksh
###############################################################################
# Oracle Data Pump - Selective Migration All-In-One
#
# 01 PROFILE
# 02 ROLE
# 03 USER
# 04 TABLE META
# 05 TABLE DATA
# 06 INDEX + CONSTRAINT + REF_CONSTRAINT
# 07 SEQUENCE + TYPE
# 08 VIEW + FUNCTION + PROCEDURE + PACKAGE
# 09 TRIGGER
# 10 SYNONYM
# 11 GRANT
# 12 INVALID COMPILE / CHECK
###############################################################################

DB_USER="system"
DB_PASS="password"
CONNECT_STRING="ORCL"

DIRECTORY="DUMP_DIR"
META_DUMP="meta_full.dmp"

# 특정 PROFILE. 여러 개면 "'P1','P2'"
PROFILE_LIST="'APP_PROFILE'"

# 특정 ROLE. 여러 개면 "'R1','R2'"
ROLE_LIST="'APP_ROLE'"

# 이관할 SOURCE SCHEMA. 여러 개면 "SRC1,SRC2"
SRC_SCHEMAS="SRC"

# 특정 USER 필터. 여러 개면 "'SRC1','SRC2'"
USER_LIST="'SRC'"

# SOURCE -> TARGET remap. 여러 개면 공백으로 반복
# 동일 스키마명 이관이면 REMAP_ARGS=""
REMAP_ARGS="remap_schema=SRC:TGT"

# 대상 TABLE 목록은 SOURCE schema 기준
TABLE_LIST="SRC.TAB_A,SRC.TAB_B,SRC.TAB_C"

PARALLEL_DEGREE=4
IMPDP="impdp ${DB_USER}/${DB_PASS}@${CONNECT_STRING}"

###############################################################################
# 01. PROFILE
###############################################################################
if [ -n "${PROFILE_LIST}" ]; then
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=01_profile.log \
  full=Y \
  content=METADATA_ONLY \
  "include=PROFILE:\"IN (${PROFILE_LIST})\""
fi

###############################################################################
# 02. ROLE
###############################################################################
if [ -n "${ROLE_LIST}" ]; then
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=02_role.log \
  full=Y \
  content=METADATA_ONLY \
  "include=ROLE:\"IN (${ROLE_LIST})\""
fi

###############################################################################
# 03. USER
# 대상 DB에 DEFAULT/TEMP TABLESPACE가 먼저 존재해야 함
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=03_user.log \
  full=Y \
  content=METADATA_ONLY \
  "include=USER:\"IN (${USER_LIST})\"" \
  ${REMAP_ARGS}

###############################################################################
# 04. TABLE META
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=04_table_meta.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  tables=${TABLE_LIST} \
  include=TABLE \
  ${REMAP_ARGS}

###############################################################################
# 05. TABLE DATA
# 실제 테이블별 dump 파일명으로 수정
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=TAB_A.dmp \
  logfile=05_TAB_A_data.log \
  schemas=${SRC_SCHEMAS} \
  content=DATA_ONLY \
  table_exists_action=APPEND \
  parallel=${PARALLEL_DEGREE} \
  ${REMAP_ARGS}

${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=TAB_B.dmp \
  logfile=05_TAB_B_data.log \
  schemas=${SRC_SCHEMAS} \
  content=DATA_ONLY \
  table_exists_action=APPEND \
  parallel=${PARALLEL_DEGREE} \
  ${REMAP_ARGS}

${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=TAB_C.dmp \
  logfile=05_TAB_C_data.log \
  schemas=${SRC_SCHEMAS} \
  content=DATA_ONLY \
  table_exists_action=APPEND \
  parallel=${PARALLEL_DEGREE} \
  ${REMAP_ARGS}

###############################################################################
# 06. INDEX + CONSTRAINT + REF_CONSTRAINT
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=06_index_constraint.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  tables=${TABLE_LIST} \
  include=INDEX \
  include=CONSTRAINT \
  include=REF_CONSTRAINT \
  parallel=${PARALLEL_DEGREE} \
  ${REMAP_ARGS}

###############################################################################
# 07. SEQUENCE + TYPE
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=07_sequence_type.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  include=SEQUENCE \
  include=TYPE \
  ${REMAP_ARGS}

###############################################################################
# 08. VIEW + FUNCTION + PROCEDURE + PACKAGE
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=08_program_objects.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  include=VIEW \
  include=FUNCTION \
  include=PROCEDURE \
  include=PACKAGE \
  ${REMAP_ARGS}

###############################################################################
# 09. TRIGGER
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=09_trigger.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  tables=${TABLE_LIST} \
  include=TRIGGER \
  ${REMAP_ARGS}

###############################################################################
# 10. SYNONYM
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=10_synonym.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  include=SYNONYM \
  ${REMAP_ARGS}

###############################################################################
# 11. GRANT
# 운영 반영 전 아래 SQL로 실제 object path 확인 권장:
#
# select object_path
# from database_export_objects
# where object_path like '%GRANT%'
# order by object_path;
#
# select object_path
# from schema_export_objects
# where object_path like '%GRANT%'
# order by object_path;
###############################################################################
${IMPDP} \
  directory=${DIRECTORY} \
  dumpfile=${META_DUMP} \
  logfile=11_grant.log \
  schemas=${SRC_SCHEMAS} \
  content=METADATA_ONLY \
  include=SYSTEM_GRANT \
  include=ROLE_GRANT \
  include=OBJECT_GRANT \
  include=DEFAULT_ROLE \
  ${REMAP_ARGS}

###############################################################################
# 12. INVALID COMPILE / CHECK
#
# BEGIN
#   DBMS_UTILITY.COMPILE_SCHEMA(
#     schema      => 'TGT',
#     compile_all => FALSE
#   );
# END;
# /
#
# SELECT owner, object_type, object_name, status
# FROM dba_objects
# WHERE owner IN ('TGT')
#   AND status = 'INVALID'
# ORDER BY owner, object_type, object_name;
###############################################################################

echo "============================================================"
echo "Selective Data Pump migration finished."
echo "Check all logfile results."
echo "============================================================"
