-- ===============================================
-- 1) 실시간 최근 통계 (v$undostat, 10분 단위, 인스턴스별)
-- ===============================================
SELECT inst_id,
       TO_CHAR(begin_time,'MM/DD HH24:MI') begin_time,
       TO_CHAR(end_time,'MM/DD HH24:MI')   end_time,
       undoblks,
       ROUND((undoblks * 8192)/1024/1024/1024, 2) AS undo_gb,
       maxquerylen,
       ssolderrcnt,   -- snapshot too old 발생횟수 (이게 0이 아니면 이미 위험 신호)
       nospaceerrcnt  -- undo 공간부족 에러 발생횟수
FROM gv$undostat
ORDER BY inst_id, begin_time DESC;


-- ===============================================
-- 2) 최근 24시간 인스턴스별 합계 (실시간 뷰 기준)
-- ===============================================
SELECT inst_id,
       ROUND(SUM(undoblks * 8192)/1024/1024/1024, 2) AS undo_gb_24h,
       ROUND(SUM(undoblks * 8192)/1024/1024/1024 / 24, 2) AS undo_gb_per_hour,
       SUM(ssolderrcnt)  AS snapshot_too_old_cnt,
       SUM(nospaceerrcnt) AS nospace_err_cnt
FROM gv$undostat
WHERE begin_time >= SYSDATE - 1
GROUP BY inst_id
ORDER BY inst_id;


-- ===============================================
-- 3) 과거 이력 (dba_hist_undostat, AWR 기반 - 더 긴 기간 확인용)
--    원하는 기간으로 begin_interval_time 조건 조정
-- ===============================================
SELECT instance_number,
       TO_CHAR(begin_interval_time,'MM/DD HH24:MI') begin_time,
       undoblks,
       ROUND((undoblks * 8192)/1024/1024/1024, 2) AS undo_gb,
       ssolderrcnt,
       nospaceerrcnt
FROM dba_hist_undostat
WHERE begin_interval_time >= SYSDATE - 7   -- 최근 7일
ORDER BY instance_number, begin_interval_time DESC;


-- ===============================================
-- 4) 일자별/인스턴스별 undo 생성 합계 (dba_hist_undostat)
--    -> 요일/업무시간대별 패턴(피크타임) 확인용
-- ===============================================
SELECT instance_number,
       TRUNC(begin_interval_time) AS day,
       ROUND(SUM(undoblks * 8192)/1024/1024/1024, 2) AS undo_gb_day,
       SUM(ssolderrcnt)  AS snapshot_too_old_cnt,
       SUM(nospaceerrcnt) AS nospace_err_cnt
FROM dba_hist_undostat
WHERE begin_interval_time >= SYSDATE - 14  -- 최근 2주
GROUP BY instance_number, TRUNC(begin_interval_time)
ORDER BY instance_number, day DESC;


-- ===============================================
-- 5) 현재 UNDO 테이블스페이스 크기/여유공간 (인스턴스별 undo tablespace 다를 수 있음)
-- ===============================================
SELECT tablespace_name,
       ROUND(SUM(bytes)/1024/1024/1024, 2)      AS total_gb,
       ROUND(SUM(bytes - NVL(user_bytes,bytes))/1024/1024/1024, 2) AS used_meta_gb,
       autoextensible,
       ROUND(MAX(maxbytes)/1024/1024/1024, 2)   AS maxsize_gb
FROM dba_data_files
WHERE tablespace_name LIKE 'UNDO%'
GROUP BY tablespace_name, autoextensible
ORDER BY tablespace_name;


-- ===============================================
-- 6) 현재 UNDO_RETENTION / RETENTION GUARANTEE 설정 확인
-- ===============================================
SELECT name, value FROM gv$parameter WHERE name = 'undo_retention';

SELECT tablespace_name, retention FROM dba_tablespaces WHERE contents = 'UNDO';


-- ===============================================
-- 7) UNDO_RETENTION 변경
-- ===============================================

-- 7-1) 클러스터 전체(양쪽 인스턴스 동일값) 적용 - 보통 이거면 충분
ALTER SYSTEM SET undo_retention = 108000 SCOPE=BOTH;  -- 30시간, 필요 값으로 조정

-- 7-2) RAC에서 인스턴스별로 다르게 주고 싶을 때 (각 인스턴스가 자기 UNDO 테이블스페이스를 쓰므로 보통은 불필요)
-- ALTER SYSTEM SET undo_retention = 108000 SCOPE=BOTH SID='instance1';
-- ALTER SYSTEM SET undo_retention = 108000 SCOPE=BOTH SID='instance2';

-- 7-3) 변경 후 확인
SELECT inst_id, name, value FROM gv$parameter WHERE name = 'undo_retention';

-- 7-4) 혹시 GUARANTEE로 걸려있어서 바꿔야 하면 (RETENTION은 테이블스페이스 단위라 재시작 불필요, 온라인 가능)
-- ALTER TABLESPACE UNDOTBS1 RETENTION NOGUARANTEE;
-- ALTER TABLESPACE UNDOTBS2 RETENTION NOGUARANTEE;


-- ===============================================
-- 8) UNDO 데이터파일 리사이징 / AUTOEXTEND
-- ===============================================

-- 8-1) 현재 undo 데이터파일 목록/경로/사이즈 먼저 확인 (여기서 FILE_NAME 가져다 아래에 사용)
SELECT file_id, tablespace_name, file_name,
       ROUND(bytes/1024/1024/1024,2)    AS size_gb,
       ROUND(maxbytes/1024/1024/1024,2) AS maxsize_gb,
       autoextensible, increment_by*8/1024 AS increment_mb
FROM dba_data_files
WHERE tablespace_name LIKE 'UNDO%'
ORDER BY tablespace_name, file_id;

-- 8-2) 기존 파일 크기 늘리기 (즉시 반영, 온라인 가능) - FILE_NAME은 8-1 결과값으로 교체
-- ALTER DATABASE DATAFILE '/path/to/undotbs01.dbf' RESIZE 400G;

-- 8-3) AUTOEXTEND 켜고 MAXSIZE 지정 (평소엔 꺼져있어도, 이번 이관 기간엔 켜두는 걸 권장)
-- ALTER DATABASE DATAFILE '/path/to/undotbs01.dbf' AUTOEXTEND ON NEXT 1G MAXSIZE 500G;

-- 8-4) 공간이 부족한 게 아니라 "혹시 몰라서" 여유 파일을 추가하고 싶을 때 (기존 파일 건드리지 않고 추가)
-- ALTER TABLESPACE UNDOTBS1 ADD DATAFILE '/path/to/undotbs01_02.dbf' SIZE 100G AUTOEXTEND ON NEXT 1G MAXSIZE 200G;

-- 8-5) 변경 후 재확인 (8-1과 동일 쿼리로 autoextensible/maxsize 바뀐 것 확인)
