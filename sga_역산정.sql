-- 인스턴스별 현재 buffer cache 크기와 hit ratio
SELECT inst_id, name, value 
FROM gv$sga 
WHERE name = 'Database Buffers';

-- 실제 워킹셋 추정: DB_CACHE_ADVICE 활용 (인스턴스별로 각각 조회)
SELECT inst_id, size_for_estimate, size_factor, 
       estd_physical_read_factor, estd_physical_reads
FROM gv$db_cache_advice
WHERE block_size = (SELECT value FROM v$parameter WHERE name='db_block_size')
ORDER BY inst_id, size_for_estimate;


핵심: estd_physical_read_factor가 1.0에서 크게 벗어나기 시작하는 지점(무릎점, knee point)이 그 인스턴스의 최소 필요 버퍼캐시입니다. 이 지점 이하로 줄이면 physical read가 급증합니다.

2단계: 인스턴스 간 워킹셋 중복도 파악 (RAC 통합의 핵심)

RAC는 서비스가 인스턴스별로 분리되어 있어도, 공유 오브젝트(공통 코드테이블, 공통 인덱스 등)는 여러 인스턴스 버퍼캐시에 중복 캐싱되어 있을 가능성이 높습니다. 싱글로 합치면 이 중복이 사라지므로 단순 합산보다 필요량이 줄어들 수 있습니다.


핵심: estd_physical_read_factor가 1.0에서 크게 벗어나기 시작하는 지점(무릎점, knee point)이 그 인스턴스의 최소 필요 버퍼캐시입니다. 이 지점 이하로 줄이면 physical read가 급증합니다.

2단계: 인스턴스 간 워킹셋 중복도 파악 (RAC 통합의 핵심)

RAC는 서비스가 인스턴스별로 분리되어 있어도, 공유 오브젝트(공통 코드테이블, 공통 인덱스 등)는 여러 인스턴스 버퍼캐시에 중복 캐싱



각 인스턴스 상위 리스트를 뽑아서 겹치는 오브젝트의 블록 크기를 확인
겹치는 만큼은 "중복 제거 가능한 버퍼"로 보고 합산치에서 빼야 정확함
3단계: AWR 히스토리로 피크 시점 검증 (평상시 말고 최악 시나리오 기준)


각 인스턴스 상위 리스트를 뽑아서 겹치는 오브젝트의 블록 크기를 확인
겹치는 만큼은 "중복 제거 가능한 버퍼"로 보고 합산치에서 빼야 정확함
3단계: AWR 히스토리로 피크 시점 검증 (평상시 말고 최악 시나리오 기준)


4단계: 통합 시뮬레이션 (가장 정확한 방법)

가장 신뢰도 높은 방법은 **테스트 환경에서 실제로 160GB SGA로 세팅하고 기존 워크로드를 재생(replay)**하는 것입니다.


-- Database Replay 활용 (RAC 프로덕션 워크로드 캡처 → 싱글 테스트 환경에서 재생)
-- 1) 프로덕션에서 피크 구간 워크로드 캡처
BEGIN
  DBMS_WORKLOAD_CAPTURE.START_CAPTURE(
    name => 'peak_capture', 
    dir  => 'CAPTURE_DIR',
    duration => 3600  -- 피크 1시간
  );
END;
/

-- 2) 테스트 싱글 인스턴스(160GB SGA)에서 재생
BEGIN
  DBMS_WORKLOAD_REPLAY.INITIALIZE_REPLAY(
    replay_name => 'single_160gb_test',
    replay_dir  => 'REPLAY_DIR'
  );
  DBMS_WORKLOAD_REPLAY.START_REPLAY();
END;
/


재생 후 DBA_WORKLOAD_REPLAYS, AWR 리포트로 physical reads, DB Time을 실측 비교
계산/추정치가 아닌 실측값이라 가장 정확하지만, 별도 테스트 장비와 시간이 필요함 (Database Replay는 라이선스 확인 필요 — Diagnostic/Tuning Pack 또는 Real Application Testing 옵션)
5단계: 최종 산출 공식


최소 필요 SGA = (버퍼캐시 knee point 합산치 - 중복 오브젝트 캐시분) 
              + Shared Pool 필요치(SQL 다양성 기준) 
              + Large Pool(병렬처리/RMAN 등 사용시) 
              + Redo Log Buffer 
              + 안전 마진(10~15%)


Shared Pool은 V$SHARED_POOL_ADVICE로 별도 시뮬레이션하시면 됩니다:


SELECT shared_pool_size_for_estimate, shared_pool_size_factor,
       estd_lc_load_time, estd_lc_time_saved_factor
FROM v$shared_pool_advice
ORDER BY shared_pool_size_for_estimate;