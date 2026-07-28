1. 계정/그룹 (설치 전 필수, 현재 누락)
	oinstall 그룹 생성 (Oracle Inventory, 모든 설치 계정의 primary group)
	dba 그룹 생성 (OSDBA, 필수)
	asmadmin 그룹 생성 (OSASM, ASM 관리 SYSASM 권한)
	asmdba 그룹 생성 (OSDBA for ASM, 필수 — DB가 ASM 접근하려면 필요)
	oracle 계정 생성 후 위 그룹들 소속 설정
	oracle 계정 shell startup 파일에 umask 022 설정
2. ASM 디스크 준비 (현재 오류/누락)
	Filesystem 시트의 ASM(DATA)(500GB×50EA), ASM(RECO)(200GB×10EA) 행이 File System Type=JFS2로 잘못 기재됨 → raw 상태여야 함 (수정 필요)
	후보 디스크가 어떤 VG에도 속하지 않은 raw 상태인지 확인 (lspv | grep -i none)
	PVID 제거: chdev -l hdiskN -a pv=clear
	소유권/권한 설정: chown -R oracle:asmadmin /dev/rhdiskN, chmod 660 /dev/rhdiskN
	MPIO reserve_policy=no_reserve 설정 확인 (SAN 4-path 구성이라 특히 중요, 단 이건 Oracle 공식 문서엔 없고 스토리지/MPIO 일반 권고사항이라 별도 확인 필요)
3. 네트워크/DNS
	DNS 또는 /etc/hosts에 hostname 등록 여부 체크 항목 추가
	ping <hostname> 으로 실제 resolve 확인하는 절차 추가
	npaydb11 ↔ npaydb12 상호 /etc/hosts 등록 (동기화망 있는 걸 보면 서로 인식해야 하는 구성으로 추정)
4. 파라미터 오류/재검토 (엑셀에 값은 있지만 확인 필요)
	udp_sendspace = 26214 → 262144의 오타로 의심됨 (다른 버퍼 값들과 자릿수 불일치, 재확인)
	aio_maxservers = 30 → Oracle 공식식(디스크수×10÷CPU수, 최대 80) 기준 75~80 근처가 맞아 보임, 재산정 필요 (엑셀 자체 설명에도 "확인 필요"라고 이미 표시돼 있음)
	maxuproc = 16384 → 공식 최소치와 정확히 일치, 여유 없음. 실제 DB init.ora의 PROCESSES + PARALLEL_MAX_SERVERS 합계와 대조해서 필요시 상향 검토
5. 참고 (문제는 아니지만 확인 권장)
	SWAP 64G — 공식 AIX 권장식(RAM 절반+4GB, 상한 32GB)보다 큼, 의도된 값인지만 확인
	NTP/시간 동기화 설정 — 두 문서엔 없지만 Oracle 설치 전 일반적인 사전 점검 항목