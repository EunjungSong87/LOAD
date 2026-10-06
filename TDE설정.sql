1. ASM에 wallet 디렉터리 생성
bash
# grid 유저로
asmcmd mkdir +DATA/ORCL/WALLET
asmcmd mkdir +DATA/ORCL/WALLET/tde
2. WALLET_ROOT 지정 후 재기동
sql
ALTER SYSTEM SET WALLET_ROOT='+DATA/ORCL/WALLET' SCOPE=SPFILE;

Oracle Restart 환경이면 srvctl로 재기동하는 게 좋습니다.

bash
srvctl stop database -d ORCL
srvctl start database -d ORCL
sql
ALTER SYSTEM SET TDE_CONFIGURATION='KEYSTORE_CONFIGURATION=FILE' SCOPE=BOTH;
3. 키스토어 생성 → 오픈 → 마스터키
sql
ADMINISTER KEY MANAGEMENT CREATE KEYSTORE IDENTIFIED BY "Wallet_Pwd#1";

ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "Wallet_Pwd#1" CONTAINER=ALL;

ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY "Wallet_Pwd#1" WITH BACKUP CONTAINER=ALL;

Non-CDB면 CONTAINER=ALL은 빼세요.

4. Auto-login
sql
ADMINISTER KEY MANAGEMENT CREATE AUTO_LOGIN KEYSTORE
  FROM KEYSTORE IDENTIFIED BY "Wallet_Pwd#1";

단일 서버라 LOCAL AUTO_LOGIN도 쓸 수 있지만, 나중에 서버 이전이나 Data Guard 구성 시 다시 만들어야 하므로 일반 auto-login이 무난합니다.

재기동 후 자동 오픈 확인:

bash
srvctl stop database -d ORCL
srvctl start database -d ORCL
sql
SELECT con_id, wrl_parameter, status, wallet_type
  FROM v$encryption_wallet;

STATUS = OPEN, WALLET_TYPE = AUTOLOGIN이면 정상입니다.

5. 테이블스페이스 암호화

ASM + OMF(db_create_file_dest='+DATA')면 파일명 신경 쓸 필요가 없어서 파일시스템보다 간단합니다.

sql
-- 신규
CREATE TABLESPACE SECURE_DATA
  DATAFILE '+DATA' SIZE 10G AUTOEXTEND ON NEXT 1G MAXSIZE 32767M
  ENCRYPTION USING 'AES256' ENCRYPT;

-- 기존: 온라인 (디스크그룹에 테이블스페이스 크기만큼 여유 공간 필요)
ALTER TABLESPACE APP_DATA ENCRYPTION ONLINE USING 'AES256' ENCRYPT;

-- 기존: 오프라인 (추가 공간 불필요, AES128 고정)
ALTER TABLESPACE APP_DATA OFFLINE NORMAL;
ALTER TABLESPACE APP_DATA ENCRYPTION OFFLINE ENCRYPT;
ALTER TABLESPACE APP_DATA ONLINE;

-- 이후 신규 테이블스페이스 자동 암호화
ALTER SYSTEM SET ENCRYPT_NEW_TABLESPACES=ALWAYS SCOPE=BOTH;

온라인 암호화 전에 디스크그룹 여유 공간을 확인하세요.

sql
SELECT name, total_mb, free_mb, usable_file_mb FROM v$asm_diskgroup;

암호화 상태 확인:

sql
SELECT t.name, e.encryptionalg, e.status
  FROM v$tablespace t JOIN v$encrypted_tablespaces e
    ON t.ts# = e.ts# AND t.con_id = e.con_id;
6. Wallet 백업

ASM 안에만 두면 디스크그룹 장애 시 함께 날아가니, 파일시스템으로 꼭 복사해 두세요.

bash
# grid 유저로
asmcmd cp +DATA/ORCL/WALLET/tde/ewallet.p12 /backup/wallet/
asmcmd cp +DATA/ORCL/WALLET/tde/cwallet.sso /backup/wallet/

wallet 비밀번호도 별도로 안전하게 보관해야 합니다. ewallet.p12와 비밀번호가 있으면 언제든 복구할 수 있지만, 둘 중 하나라도 없으면 암호화된 데이터와 백업 모두 복구가 안 됩니다.