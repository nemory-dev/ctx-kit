# 통합 검색과 근거 있는 인수인계 설계

- 작성일: 2026-11-01, Asia/Seoul. 상태: Claude 3회 문서 검토와 코드 대조를 반영한 최종 설계. 구현 미착수.
- [조사](../research/2026-11-01-context-tools-benchmark.md) · [상세 구현 계획](../plans/2026-11-01-search-handoff.md) · [검토·반영 기록](../reviews/2026-11-01-search-handoff-claude.md).
- 승인된 범위: 문서·계획 작성과 그 내용의 Claude 검토. 구현·commit·push·PR·배포는 아직 승인되지 않았다.

## 1. 목적과 경계

목표는 기존 자료에서 필요한 근거를 찾고, 다음 세션이 현재 상태·다음 행동·명시된 제약·검증/미검증 기재를 출처와 함께 이어받도록 하는 것이다. LLM 추론 없이 결정적으로 생성한다.

유지: Bash 3.2, Python 3.7 이상 표준 라이브러리, 두 파일 복사 설치, 단일 오프라인 HTML, 기존 6종 Markdown/활성·보관 JSONL 허용 목록, 20 MiB/20,000건, 원문·반복 발생 보존, 잠금·손상 시 명시 실패, 기본 생성 중 자동 외부 요청 없음.

제외: 새 기록 스키마/영구 ID, 자동 사실 판정, 새 입력 파일, 대화 수집, 지침 내용 수집, 소스 코드 분석, AI/RAG/MCP, DB·서버, 편집·자동 실행·클립보드 상시 접근, `export`의 동작 변경. `contracts/`는 읽기 계약의 정본으로 쓰거나 수정하지 않는다.

공개 인터페이스 변화는 신규 CLI `search`/`handoff`, 뷰어의 통합 검색·인수인계 탭, 새 응답 JSON 스키마다. 기존 `view`, `timeline`, `export` 인자와 타임라인 hash 상태는 유지한다. 기본 설정·규칙 템플릿·CI는 변경하지 않는다.

## 2. 공통 구조

```text
ctx.sh CLI wrappers (옵션 검사 / 환경변수 전달)
  → resolve_view_context (현재 view의 엄격한 설정 해석 재사용)
  → context_reader_python (기존 내장 Python 본문을 한 번만 보유)
    → collect_snapshot (공통 잠금, journal 검사, 같은 수집 바이트)
    → source manifest + snapshot ID
    → 검색 모델 / 인수인계 모델 / 기존 뷰어 모델
    → stdout 또는 기존 보호 절차에 따른 HTML
```

`cmd_view`의 Python heredoc을 공유 Bash 함수 `context_reader_python`으로 이동하고 action을 환경변수 enum으로 전달한다. 수집기·Git 함수·렌더러를 복제하거나 별도 필수 파일로 분리하지 않는다. helper 이름과 `CTX_VIEW_IMPLEMENTATION_START/END` 마커는 유지한다.

`collect_snapshot(..., output_path=None)`는 출력이 없으면 output exclusions를 추가하지 않는다. `search`는 Git을 조회하지 않는다. `handoff`는 기존 Git 조회를 사용하되 커밋 객체 확인은 하지 않고 `commit_refs=[]`로 호출한다. 저장된 로그의 커밋을 현재 완료 근거로 사용하지 않는다. `view`의 기존 Git 처리·출력 사전검사·교체 검사·선택적 브라우저 열기는 유지한다.

읽기 전용 CLI도 공통 잠금을 위해 work-log 디렉터리와 .ctx.lock을 만들고 컨텍스트 디렉터리를 fsync할 수 있다. ctx는 원문·설정·HTML을 직접 기록하지 않으며 archive 복구도 하지 않는다. Git 관측은 소유권 검사를 우회하지 않지만 사용자 설정의 clean/process 필터를 실행할 수 있어 외부 필터의 Git/파일 쓰기 등 부수효과를 막는 보장은 하지 않는다. search는 Git을 호출하지 않는다. 잠금 권한 부족/30초 timeout은 명시 실패하고 잠금 없이 우회하지 않는다. 입력·인자·예산·모델 오류는 stdout이 비어 있어야 한다. 출력 장치 장애는 이미 전달된 일부 bytes를 회수할 수 없어 부분 출력 가능성을 별도로 알린다.

## 3. 출처와 스냅샷

수집 중 확정된 원본 bytes에서 manifest를 만든다. 잠금 해제 후 파일을 다시 열어 hash를 계산하지 않는다. 설정과 모든 허용 입력의 존재 여부·바이트 길이·SHA-256을 포함하며 lock·출력·스크립트는 제외한다.

```json
{
  "snapshotId": "sha256:<canonical-manifest-digest>",
  "collectedAt": "2026-11-01T03:00:00+00:00",
  "source": {
    "root": "context", "path": "MASTER_PLAN.md",
    "startLine": 3, "endLine": 5, "sha256": "<whole-file-bytes-digest>"
  }
}
```

manifest 항목은 `{root, path, status, sizeBytes, sha256}`이다. root는 `project`(설정) 또는 `context`이며 path는 원래 상대 문자열을 유지하고 Unicode 정규화하지 않는다. 누락 입력은 `status="missing"`, sizeBytes/sha256=null이다. root/path 순으로 정렬한 배열을 `json.dumps(..., ensure_ascii=True, sort_keys=True, separators=(",", ":"))`로 ASCII 직렬화해 SHA-256을 계산한다. 시각과 Git 관측은 snapshotId에 포함하지 않는다.

source 범위는 LF 기준 1부터 시작하고 양 끝의 실제 행을 포함한다. 마지막 LF 뒤의 빈 split 세그먼트는 추가 행으로 세지 않는다. U+2028/U+2029를 줄바꿈으로 보지 않는다. JSONL key는 기존 출처 경로·행 번호이며 같은 내용의 두 행도 별개 발생이다. hash는 내용 일치 확인용이며 진위나 영구 ID를 보장하지 않는다. archive 이후 다른 스냅샷의 같은 key를 같은 발생으로 추정하지 않는다.

## 4. 통합 검색 계약

### CLI

```bash
# 아래는 구현 후 사용할 신규 명령이다.
bash ctx.sh search --query "timeout cache" --scope all --limit 20
bash ctx.sh search --query "한글.kt" --scope logs --json
```

- 필수 `--query`: 원시 입력 기준 최대256 Unicode code points. ASCII 공백 `[ \t\r\n\f\v]+`으로 나눠 빈 결과·NUL·잘못된 UTF-8·단독 surrogate를 거부하고, 중복어 제거 전 최대16개 검색어를 검사한다.
- `--scope all|documents|logs`, 기본 all. `--limit` 1~50, 기본 20. `--json`은 JSON object 하나. 잘못된 인자·중복 옵션·값 누락은 stderr 설명과 종료 1. help는 Python·설정 없이 0.
- 본문과 query에 NFC를 적용하고 ASCII A-Z만 소문자로 바꾼다. 한글·ASCII 영어를 대상으로 하며 그 밖의 대소문자는 구별한다. 기존 타임라인 검색의 동작은 유지한다.
- 문서 한 파일을 결과 한 건, 로그 한 발생을 결과 한 건으로 취급한다. 문서는 경로·전체 본문, 로그는 문자열 title/summary/files만 검색한다. 타입이 다른 값이나 알 수 없는 필드는 자동 문자열화하지 않는다.
- 모든 검색어 AND. 정규식·의미 검색·연산자는 지원하지 않는다. 검색어 중복만 합치며 로그는 합치지 않는다.
- 점수는 검색어×필드별 존재 여부다. 로그 title 일치4 + path/files 중 하나라도 일치2 + body/summary 일치1. 문서 표시 title은 path이며 title 점수는 주지 않아 중복 가중하지 않는다. 문자열 files 원소만 개별 비교한다. AND가 성립한 후보를 `(-score, order)`로 정렬한다.
- order는 VIEW_DOCUMENTS 순의 문서, 이어서 기존 UTC 내림차순/시각 미확인 후방/경로·행 순의 로그 위치다. JS가 별도 문자열 정렬을 하지 않는다.
- 결과 0건은 성공. 문서 본문의 검색어 첫 등장 중 가장 빠른 행을 출처로 표시하고 경로만 일치하면 source.startLine/endLine=null이다. 로그는 실제 JSONL 행을 쓴다.

snippet은 문서는 첫 일치 행, 로그는 summary → title → files 순으로 처음 일치하는 필드에서 만든다. NFC 표시 문자열의 대소문자를 유지하고 첫 일치 앞40 code points부터 본문 최대158 code points를 취한다. 앞뒤가 생략되면 각각 `…`를 추가해 전체160 이내로 한다. 다른 행은 섞지 않는다. 경로만 일치하면 path를 표시한다. 겹치는 강조 구간은 합쳐 DOM을 만들며 전체 원문과 hash는 유지한다.

JSON: `{schemaVersion:1, query, scope, snapshotId, collectedAt, total, returned, omittedByLimit, results:[{ref, kind, title, score, source, matchedFields, snippet, snippetField, snippetTruncatedStart, snippetTruncatedEnd}]}`. ref는 스냅샷 한정 `document:<key>` / `entry:<sourcePath>:<line>`인 불투명 문자열이다. 콜론으로 분해하지 않고 source를 이용한다. 큰 정수를 가진 record 객체를 검색 결과에 재직렬화하지 않는다.

### HTML

기존 타임라인 검색·필터를 유지하고 독립된 ‘통합 검색’ 탭을 추가한다. query/scope/페이지를 hash의 `sq/ss/sp`에 저장해 기존 q/type/file/date/page와 충돌하지 않게 한다. 50건 페이지, 결과 수, 빈 상태, IME·키보드 조작, textContent 기반 강조 표시를 제공한다. 일반 입력은150ms debounce, compositionend/Enter는 즉시 실행한다. 페이지/선택만 바뀌면 검색을 반복하지 않는다. 정규화 자료는 최초 검색 때 만들고20 MiB 입력의 JS heap을 별도 측정한다.

문서 결과는 일치 행을 포함하는 직전 제목으로 이동하고 제목/본문 일치가 없으면 맨 위로 간다. 정확한 행 스크롤로 표시하지 않는다. 로그 결과는 기존 상세로 이동하며 타임라인 필터를 해제한다. 결과 이동만 history.pushState를 사용해 뒤로가기로 검색·이전 필터를 복원하며 기존 입력 변경의 replaceState는 유지한다. popstate/hashchange에서 알려진 기존·신규 상태를 읽고 함께 직렬화한다. 알 수 없는 hash 필드는 기존처럼 무시한다.

Python과 JS는 같은 query/점수 계약을 별도 구현하고 공통 golden fixture로 순서·건수·snippet을 비교한다. 문서 본문·recordText를 HTML에 이중 저장하지 않는다. JS는 기존 모델에서 검색 문자열을 초기화하고 전체 결과를 DOM에 만들지 않는다.

## 5. 근거 있는 인수인계 계약

### CLI와 수집 대상

```bash
# 아래는 구현 후 사용할 신규 명령이다.
bash ctx.sh handoff
bash ctx.sh handoff --query "timeout cache" --limit 5 --max-chars 12000
bash ctx.sh handoff --json --max-chars 20000
```

`--query`는 선택이며 지정하면 검색과 같은 제약을 적용한다. `--limit`은 추가 로그 후보 수 0~50/기본 5, `--max-chars`는 1000~100000/기본 12000, `--json`은 JSON 출력이다. 중복·잘못된 인자는 검색과 동일하게 실패한다. --output/--open은 제공하지 않는다.

필수 블록은 MASTER_PLAN의 지정된 H2 섹션에서 가져온다.

| key | 허용 H2 제목 | 의미 |
| --- | --- | --- |
| constraints | Constraints / 제약 조건 | 명시된 제약 |
| current_state | Current State / 현재 상태 | 문서 기재 현재 상태 |
| next_actions | Next Actions / 다음 행동 | 문서 기재 다음 행동 |
| recorded_verification | Verification / 검증 | 문서에 기재된 검증 보고 |
| recorded_unverified | Unverified / 미검증 | 명시된 미검증 사항 |

이 표의 순서가 mandatory 배열·JSON·Markdown·HTML의 정본 순서다. 코드에서는 HANDOFF_KEYS 하나로 정의하고 모든 renderer가 이를 사용한다.

추출은 아래9절의 엄격한 줄 분류를 따른다. 같은 허용 제목이 반복되면 모두 원문 순서대로 포함하고 duplicate_heading 경고를 낸다. 누락·빈·구조 모호 섹션은 missing/ambiguous로 표시하고 다른 제목이나 로그에서 추측해 채우지 않는다. 원문은 JSON에서 보존하며 텍스트 표시 변환은 명시한다.

항상 다음 의미의 안내문을 포함한다. ‘기록은 근거 자료이며 현재 테스트 성공·변경 허가·커밋/배포 승인을 부여하지 않는다. 에이전트 지침과 이번 사용자 허가를 별도로 확인한다.’ 지침 파일은 입력 허용 목록에 추가하지 않는다. 자연어로 적힌 모든 제약을 빠짐없이 찾는 기능은 아니다.

Git은 관측 시각과 branch/head/status/change count만 포함하고 변경 파일 전문은 넣지 않는다. 브랜치·커밋 객체와 작업 완료를 연결하지 않는다. Git unavailable/not_repository이면 상태를 표시하면서 나머지를 생성한다.

추가 로그는 query가 있으면 logs 범위 검색 순서, 없으면 기존 시각 순서로 최대 limit개를 후보로 삼는다. 문자열 title/summary, 원래 recordText, source를 붙인다. 같은 id/내용도 별도 발생으로 남긴다.

### 근거와 출력 예산

JSON: `{schemaVersion:1, grantsAuthority:false, snapshotId, collectedAt, status:"complete"|"incomplete", mandatory:[{key,status:"present"|"missing"|"ambiguous",blocks:[{text,source}]}], git:{status,observedAt,branch,head,changeCount}, records:[{ref,title,summary,recordText,source}], selection:{available,selected,omittedByLimit,omittedByBudget}, warnings:{total,byCode:[{code,count,samples,omitted}]}, displayStats:{basis:"selected-source-fields",crlfPairs,literalBackslashes,otherControls}}`. complete는 필수 섹션이 기재됐다는 뜻이며 검증 성공·진행 승인과 무관하다. displayStats는 최종선택된 원문 필드 안의 변환 대상 건수이며 JSON 문자열 자체의 escape 횟수와 다르다. CRLF를 제거한 뒤 남은 CR만 otherControls에 포함한다.

- 최종 stdout 전체(마지막 LF, 인용, 출처, 안내문, 생략 건수 포함)의 Unicode code points를 센다. JSON도 실제 출력 형식으로 센다.
- JSON은 ensure_ascii=True로 출력해 parse 후 원래 값과 단독 surrogate를 보존한다. 텍스트에서는 제어문자·bidi·surrogate를 보이게 이스케이프하고 표시 변환임을 밝힌다. 예산은 이 변환 후 실제 출력 길이다.
- 필수 블록·missing 표시·Git 관측·안내문은 삭제하지 않는다. 이것만으로 예산을 넘으면 stdout을 비우고 stderr 설명과 종료 1을 반환한다.
- 추가 로그는 후보 순서의 접두 부분을 온전한 레코드 단위로 포함한다. k=0부터 실제 selected/omitted 값을 넣은 최종 형식으로 검사하고 처음 넘는 k 직전 결과를 사용한다. k=0이 넘으면 최소 필요 크기를 stderr로 설명한다. 뒤의 짧은 레코드를 끌어올리지 않는다. `available = selected + omittedByLimit + omittedByBudget`를 항상 만족한다. 레코드 조각은 한 번만 직렬화하고 재사용하며, 필수 원문 길이만으로 이미 예산을 넘으면 큰 fence를 만들기 전에 실패한다.
- 이것은 예측 가능한 접두 선정 정책이며 최대 수록량 탐색은 아니다. 경고·카운트가 변해 뒤쪽 k의 출력이 더 짧아질 수 있어도 첫 초과에서 멈춘다. k=0에 드는 최소 필요 크기는 이 정책의 기준이며 모든 k 중 최솟값을 뜻하지 않는다. JSON ASCII escape로 한글 한 글자가6자가 될 수 있어 형식별 예산 성공률을 따로 측정한다.
- 필수 문서 본문 블록과 선택한 각 로그에 source를 붙인다. missing은 출처를 만들어내지 않고 기대 파일·제목을 표시한다.
- 필수 섹션이 없거나 구조가 모호하면 status=incomplete이고 경고와 함께 성공0이다. ‘섹션 미기록은 해당 사항이 없다는 뜻이 아님’을 표시한다. 예산 초과·입력 손상과 구분한다.
- 문서뿐 아니라 title/summary/recordText/path/branch/경고 등 외부 문자열은 전부 동적 fence 또는 JSON 문자열 리터럴로 표시한다. 출력 제목·라벨은 고정 문자열만 쓴다. 원문 전체의 최대 tilde 연속 길이보다 긴 fence를 쓴다.

### HTML

‘인수인계’ 탭에 view 생성 시 같은 Python builder로 만든 기본 handoff를 textContent/readOnly textarea로 표시한다. HTML 안에서 query 기반 재생성이나 로그 수동 선택은 구현하지 않는다. 복사는 사용자 버튼 조작 때만 실행한다. clipboard 미지원·거부 시 textarea를 선택하고 수동 복사를 안내한다.

기본 예산을 넘겨도 기존 view 생성은 성공한다. handoff 영역만 budget_exceeded와 필요한 최소 크기/CLI 예산 조절 방법을 표시한다. view의 기존 Git 관측을 재사용하고 두 번째 조회를 하지 않는다. 격리는 예상한 예산 초과·명시적 미지원 구조로 한정하며 예상 밖 프로그래밍 오류를 잡아 숨기지 않는다. 그런 오류는 생성 실패와 기존 결과 보존으로 처리한다.

## 6. 성능과 실패

검색은 검색어 수 상한이 있는 전체 후보 선형 탐색과 최대 50개 DOM을 사용한다. 원본 hash는 수집 bytes에서 한 번 계산한다. handoff 후보는 최대 50개이며 거대한 레코드의 전체 직렬화를 반복하지 않는다. 선택하지 않은 recordText는 handoff JSON에 넣지 않는다.

5천/2만 건·20 MiB 문서·한 줄의 큰 문서·같은 내용의 대량 기록·경고 4만 개로 생성 시간/HTML 크기/검색/예산 계산을 측정한다. 5천 건 생성 3초/검색 200ms는 목표이며 달성했다고 기록하지 않는다.

잘못된 UTF-8/JSON, journal, symlink, 상한, 동시 편집 처리는 기존 view의 계약을 따른다. 새 CLI는 성공 안내를 stdout 데이터에 섞지 않으며 전체 결과를 확정한 뒤 출력한다.

## 7. 검증과 미실시 항목

CLI/UI 공통 golden, 정상·빈 상태·누락·중복·Unicode·공격 문자열·예산 경계·출력 실패를 자동 검증한다. 기존 Node harness는 실제 내장 JS를 실행하지만 브라우저 그리기를 대신하지 않는다.

실브라우저 file:// 자동 접근은 이미 정책으로 거부됐다. 다른 표면·서버로 우회하지 않는다. Chrome/Safari 수동 검색·복사·키보드·자동 외부 요청 0과 Markdown 대비 60초 평가를 미실시 표와 함께 남긴다. Python 3.7 실제 실행·Windows도 실환경이 없으면 미실시로 표시한다.

## 8. 설계 결정

두 기능은 같은 수집·출처 모델에 의존하는 출력 기능으로 순차 구현한다. 공유 reader와 검색, handoff, HTML과 사용자 평가 순서다. 기존 문서 전체의 구조화·영구 ID 이관·템플릿 갱신은 필요하지 않다. 새 공개 JSON은 schemaVersion=1로 시작하고 내부 viewModelVersion=1은 선택적 필드만 추가한다.

Claude 지적의 채택·조정·보류는 [검토 기록](../reviews/2026-11-01-search-handoff-claude.md)에 남기고 코드 적합성은 Codex가 확인한다.

## 9. Claude 검토로 확정한 경계 규칙

### Markdown 추출

- 지원하는 필수 제목은 **행 첫 칸에서 시작하는 ATX H2**다. 필수 블록 안의 앞1~3칸 공백 ATX 제목은 경계를 추측하지 않고 해당 블록 전체를 ambiguous로 제외한다. 다음 unindented 동급·상위 ATX에서 다시 분류한다. 4칸 들여쓰기 코드/인용/목록 속 제목은 제외한다.
- 줄 분류에만 파일 맨 앞 BOM과 행 끝 CR 하나를 무시하고 원문·hash·LF 행 번호는 유지한다. 닫는 #는 ASCII 공백 뒤의 연속 #인 경우만 제거한다.
- fence는 앞0~3칸 공백 뒤 같은 backtick/tilde 3개 이상으로 열고, 같은 문자·이상 길이·뒤 ASCII 공백뿐인 행에서 닫는다. 미종결 fence는 EOF까지 코드로 처리하고 영향을 받은 필수 블록을 ambiguous로 제외·경고한다. 닫힌 목록 펜스를 오인한 경우도 다른 섹션을 필수 본문으로 승격하지 않는다.
- 같은 행의 길이가 같은 backtick 쌍으로 둘러싼 인라인 코드에서는 주석 표식을 무시한다. fence 밖 실제 HTML comment는 `<!--`부터 `-->`까지 제목 인식에서 제외한다. 미종결 comment는 EOF까지 무시하고 영향을 받은 필수 블록은 ambiguous로 제외·경고한다. 주석 속 원문은 자동 실행/지침으로 취급하지 않는다.
- setext 후보(바로 전 비어 있지 않은 행과 unindented `===`/`---`)를 필수 블록 안에서 만나면 그 필수 블록을 ambiguous로 표시하고 본문을 인수인계에서 제외한다. 다른 명시 H2부터 다시 분류한다. setext 본문을 제약에 잘못 붙이지 않는다.
- 섹션은 제목 다음 행부터 다음 동급·상위 ATX 제목 직전까지이며 마지막 빈 행도 범위에 포함한다. ASCII 공백/하위 제목/comment만 있는 본문은 missing이다. 본문의 실질 내용 존재 여부만 검사하고 의미는 판정하지 않는다.
- 번호/접미어가 붙은 유사 제목은 자동 채택하지 않고 ambiguous_markdown 유형에 near-miss 이유와 행을 요약한다. 같은 제목 여러 개는 모두 보존하며 최신 하나를 고르지 않는다.
- 필수 제목 자체가 들여쓰여 있으면 해당 key는 missing이며 near-miss 경고에 indented_atx 이유를 붙인다. 모호한 구간을 기재되지 않았다고 조용히 처리하지 않는다.
- 기존 개요·문서 렌더러의 파서를 이번에 교체하지 않는다. 새 추출 규칙의 모호 경고를 인수인계에 표시하고, 검색은 원문 전체를 검색한다. 문서 이동은 기존 뷰어의 근처 제목 이동임을 표시한다.

### 경고·터미널·인자

- 인수인계 경고는 고정8종 `missing_section/duplicate_heading/ambiguous_markdown/unknown_timestamp/terminal_controls/bidi_controls/git_unavailable/omission`으로 집계한다. 유형당 샘플2개·샘플당160 code points, 전체 건수와 샘플 생략수를 필수 출력한다. 기존 viewer 경고 원문 배열은 그대로 보존한다.
- 텍스트 stdout/stderr는 먼저 CRLF 쌍을 LF로 표시하며 이것을 terminal_controls 경고에 포함하지 않는다. 원래 백슬래시는 두 개로 표시한 뒤 LF/TAB 외 C0/C1/DEL, bidi 제어 U+061C/U+200E~200F/U+202A~202E/U+2066~2069, 단독 surrogate를 가시적인 이스케이프로 표시한다. 따라서 리터럴 `\u202e`와 실제 제어문자의 표시가 구분된다. 모든 동적 metadata와 원문 표시에 적용한다. 선택된 원문 텍스트 필드 기준 CRLF/백슬래시/제어문자 변환 수를 displayStats에 표시하고 예산에 포함한다. JSON은 원래 CRLF·백슬래시를 ASCII escape로 보존하며 문자열을 표시 변환하지 않는다.
- 숫자는 `[0-9]+`만 허용한다. query 길이는 NFC 전 원시 code points 기준이다. query의 단독 surrogate를 strict UTF-8 encode로 거부하므로 POSIX environb 유무와 무관하게 동작한다.
- `--query=--flag`를 지원한다. `--query VALUE`에서 다음 인자가 `--`로 시작하면 값 누락이다. 단독 `--`/위치 인자는 거부하며 다른 값 옵션도 `--name=value`를 허용한다. --help/-h는 단독 인자일 때만 설정/Python 없이 성공한다.
- wrapper는 매 호출에서 CTX_READER_ACTION/QUERY/SCOPE/LIMIT/MAX_CHARS/JSON, CTX_VIEW_PROJECT/CONFIG/SCRIPT/OUTPUT/OPEN을 모두 명시적으로 설정한다. search/handoff의 OUTPUT은 빈 값, OPEN은0이다. Python도 쓰기용 값이 남아 있으면 거부한다. stdout을 Bash 명령 치환에 담지 않는다.
- 결과는 UTF-8 bytes로 모두 확정한 뒤 stdout fd에 쓴다. 부분 os.write는 남은 bytes를 쓰며 BrokenPipe는 traceback 없이 stderr 설명/종료1이다. I/O 실패의 원자적 stdout은 보장하지 않는다.
- 종료0: 정상/0건/incomplete. 종료1: 인자/입력/잠금/예산/출력 실패. search/handoff의 오류 stderr도 terminal escape를 적용한다.

인수인계 Markdown 표시에서 U+2028/U+2029/U+FEFF/U+200B~200D는 그대로 보존한다. 검색 CLI 텍스트의 title/snippet은 LF/TAB/U+2028/U+2029를 보이는 escape로 바꿔 한 줄로 표시한다. JSON 값은 보존한다. LF 기준 행 번호나 ASCII 공백 분리를 바꾸지 않으며 숨김문자 전체를 제거하는 기능으로 표시하지 않는다. 이 문자들의 보존을 golden에 포함한다. 텍스트 표시에서 원래 CRLF와 LF를 구분할 수 없으며 원래 개행은 JSON 원값·source hash로 확인한다.

### Git과 정규화의 한계

기존 collect_git_snapshot은 이미 GIT_OPTIONAL_LOCKS=0, Git 환경 정리, lock 제외, not_repository/unavailable 구분과5초 timeout을 제공한다. 이를 유지하고 공유 조회에 GIT_TERMINAL_PROMPT=0과 `-c core.fsmonitor=false`를 추가한다. 저장소 fsmonitor 명령을 실행하지 않는 회귀 테스트를 추가한다. 다른 쓰기 명령의 Git 호출은 건드리지 않는다. Git 관측 시각은 수집 완료 시각과 다르며 snapshotId에 포함되지 않는다. 미커밋 N건을 ‘검증 이후 변경’으로 추정하지 않는다.

Python3.7과 최신브라우저는 Unicode DB 버전이 다를 수 있다. 공통 golden의 정규화 동등성 대상은 한글·ASCII와 Unicode11에 정의된 문자다. 이후 추가된 문자의 NFC 동등성은 미보장 한계로 문서화하고 원문은 보존한다. splitlines/일반 strip/일반 lower/JS의 줄구분 m정규식·UTF16 length를 계약의 대체물로 쓰지 않는다.

예산12000/상한100000은 초기 정책이다. 실제 문서 분포에서 기본 출력 성공률·필수 크기를 측정하고 변경은 한영 안내·경계 테스트와 함께 제안한다. 필수 정보가 크다는 이유로 몰래 줄이지 않는다. 결정 문서 전체나 자유 형식 제약을 자동으로 인수인계에 넣지 않는 점은 이번 범위의 명시적 제한이다.

## 10. 코드 리뷰 후 보완 (2026-11-01)

[실제 Claude 코드 리뷰](../reviews/2026-11-01-search-handoff-code-claude.md)에 따라 보수적인 미종결 펜스 격리, 실제 EOF 행 범위, 1~2자 setext/빈 ATX 경계, 단일 BOM, 선형 닫는 # 제거, inline-code 주석 구분을 반영했다. 한글 CRLF Markdown의 사전 예산 하한은 CRLF→LF 표시 길이를 사용한다. JSON notice는 권한 안내를 담는 추가 필드다. HTML 검색 제목 미리보기는 최대160자이며 원문 모델/응답을 줄이지 않는다. 결과 이동 시 미실행 debounce를 취소하고 빈 검색 탭에는 입력 안내를 표시한다.

경고 total은 코드별 발생 합계다. bidi는 terminal_controls와 bidi_controls 양쪽에 포함될 수 있고 displayStats는 제목·요약·recordText 등 선택 필드별 기준이다. 검색은 후보별 순회이며 하위 문자열 탐색의 최악 시간은 런타임/패턴에 좌우된다. 모든 20 MiB 입력의 지연을 보장하지 않는다. 기존 fromisoformat의 허용 범위 차이 때문에 비표준/확장 ISO 시각의 판정은 Python 버전에 따라 다를 수 있다.

2차 코드 리뷰 보완: 무시하는 목록·인용·들여쓰기 안에서 펜스 표식을 발견하면 해당 필수 블록을 container_or_indented_fence로 ambiguous 처리한다. 뒤에서 우연히 다시 닫혀도 다른 섹션을 흡수하지 않는다. 같은 문단의 미해결 backtick 뒤 실제 주석이 열리는 조합은 multiline_inline_comment로 보수적으로 제외한다. 인라인 코드의 여는 backtick escape는 홀수/짝수 백슬래시와 남은 backtick 길이를 구분한다. 전체 CommonMark 컨테이너/여러 줄 inline parser를 제공하는 것은 아니다.

여러 줄 행 중간 주석은 inline_comment_span으로 제외하고, backtick fence의 info에 backtick이 있으면 invalid_fence_info로 제외한다. `<!-->`/`<!--->`처럼 opener와 겹쳐 끝나는 주석은 같은 행에서 즉시 닫힌다. 원문의 후속 정상 섹션·본문을 삼키지 않도록 분류와 본문 존재 검사를 같은 규칙으로 맞췄다.
