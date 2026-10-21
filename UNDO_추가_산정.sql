1. 작업 기간(시간) 추정
16TB를 몇 시간에 받을 수 있는지가 먼저입니다. 대표 테이블 하나(수백 GB)를 같은 PARALLEL로 테스트 export해서 GB/시간을 재세요.
총 시간 = 16TB ÷ 처리속도 + (묶음 수 × 덤프 이동·삭제 시간)
예: 시간당 400GB, 6묶음, 이동 3시간씩 → 약 40 + 18 = 58시간 → 72시간으로 잡기
2. 그 기간 동안 생성될 UNDO 양

AWR에서 과거 N시간 동안 실제로 생성된 UNDO 최대치를 바로 계산하는 쿼리입니다. (:hours에 1번에서 구한 시간 입력)

sql
WITH bs AS (SELECT TO_NUMBER(value) blk FROM v$parameter WHERE name = 'db_block_size'),
w AS (
  SELECT instance_number, begin_time,
         SUM(undoblks) OVER (PARTITION BY instance_number
                             ORDER BY begin_time
                             RANGE BETWEEN :hours/24 PRECEDING AND CURRENT ROW) blks
  FROM dba_hist_undostat
)
SELECT w.instance_number,
       ROUND(MAX(w.blks) * bs.blk / POWER(1024,3)) AS max_undo_gb_in_window
FROM w, bs
GROUP BY w.instance_number, bs.blk
ORDER BY 1;

결과 GB × 1.3~1.5 = 인스턴스별 UNDO 목표 크기입니다.
RAC면 인스턴스별로 나오는 값만큼 각 인스턴스의 UNDO 테이블스페이스를 각각 늘려야 합니다.
AWR 보관 기간(dba_hist_wr_control, 기본 8일) 안에 월말·배치 많은 날이 포함됐는지 확인하세요. 작업 기간에 그런 날이 겹치면 그날 기준 값을 써야 합니다.

3. 마지막 체크
위 값은 현재 UNDO에 이미 쓰고 있는 양(ACTIVE/UNEXPIRED)과 별개로 추가 확보돼야 합니다.
첫 묶음이 돌기 시작하면 v$undostat으로 실제 시간당 UNDO 생성량을 다시 보고, 예상과 크게 다르면 그때 데이터파일을 더 추가하세요.