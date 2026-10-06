# 1. 한 번만 export
expdp system/**** full=y content=METADATA_ONLY \
      directory=DATA_PUMP_DIR dumpfile=meta_full.dmp logfile=meta_exp.log

# 2. 테이블스페이스
impdp system/**** directory=DATA_PUMP_DIR dumpfile=meta_full.dmp \
      include=TABLESPACE sqlfile=01_tbs.sql

# 3. 계정/권한
impdp system/**** directory=DATA_PUMP_DIR dumpfile=meta_full.dmp \
      include=PROFILE,ROLE,USER,TABLESPACE_QUOTA,ROLE_GRANT,SYSTEM_GRANT,DEFAULT_ROLE \
      sqlfile=02_user_role.sql

# 4. 스키마 오브젝트 (제약조건/인덱스/통계는 데이터 적재 후로 미룰 때)
impdp system/**** directory=DATA_PUMP_DIR dumpfile=meta_full.dmp \
      schemas=SCOTT,HR exclude=INDEX,CONSTRAINT,REF_CONSTRAINT,TRIGGER,STATISTICS \
      sqlfile=03_objects.sql

# 5. 인덱스/제약조건/트리거
impdp system/**** directory=DATA_PUMP_DIR dumpfile=meta_full.dmp \
      schemas=SCOTT,HR include=INDEX,CONSTRAINT,REF_CONSTRAINT,TRIGGER \
      sqlfile=04_idx_cons.sql