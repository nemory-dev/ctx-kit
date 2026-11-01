# 통합 검색·근거 있는 인수인계 구현 결과

2026-11-01, macOS Apple Silicon. [승인 계획](../plans/2026-11-01-search-handoff.md)과 [설계](../specs/2026-11-01-search-handoff-design.md)에 따른 구현이다. 이 문서의 자동 검증과 사람이 확인해야 할 항목을 구분한다. 커밋·push·PR·배포는 하지 않았다.

## 구현한 동작

- `ctx.sh search`: 허용된 문서와 활성/보관 로그의 모든 발생을 키워드 AND로 검색한다. NFC/ASCII case, scope, 제목4·경로2·본문1 점수, 고정 동점 순서, 최대50건, 160자 이내 스니펫을 제공한다.
- `ctx.sh handoff`: MASTER_PLAN의 명시적 필수 H2 다섯 섹션을 고정 순서로 인용한다. 빈/누락/모호 상태와 당시 보고를 구분하고 현재 검증을 추정하지 않는다. 추가 로그 기본5개, 최종 출력 기본12,000자, 접두 선정·생략 수·원문 JSONL을 제공한다.
- 공통 reader: 기존 잠금·입력 제한·journal 비복구·안전 경로·동시 수정 검사를 유지하고 수집 bytes의 sourceManifest/snapshotId를 만든다. source는 manifest의 SHA-256과 LF 줄 범위만 사용한다. 새 CLI의 전체 결과를 확정한 뒤 UTF-8 bytes로 출력한다.
- HTML: 독립된 통합 검색/인수인계 탭, 150ms debounce/IME, 50행 페이지, sq/ss/sp hash, 문서/로그 이동과 뒤로가기, textContent 기반 강조, 동일 Python builder의 기본 handoff와 명시 클릭 복사/수동 대안을 제공한다.
- 두 파일 복사 설치, 내장 Python/JS, 표준 라이브러리를 유지했다. 새 라이브러리·서버·DB·AI 호출·기록 스키마·영구 ID·입력 경로는 추가하지 않았다. 기존 export/timeline/초기화 템플릿은 수정하지 않았다.

`complete`는 필수 섹션 기재 여부다. JSON의 `grantsAuthority=false`와 `notice`, Markdown/HTML 안내는 테스트 성공·변경·커밋·배포 승인을 부여하지 않음을 명시한다. JSON notice는 schemaVersion 1의 추가 필드다.

## 변경 파일과 설계 연결

| 책임 | 파일 | 검증 근거 |
| --- | --- | --- |
| 공유 수집/출처/인자/복사 설치 | `ctx.sh`, `tests/context_read_support.py`, `tests/test_context_reader.py` | missing와 빈 파일, manifest, 시간/검색/출력과 무관한 snapshotId, 상속 환경변수 격리, 원문 보존, 손상/journal, Git fsmonitor, 부분 stdout write |
| CLI 검색 | `tests/test_context_search.py` | AND, scope, NFC/ASCII/비ASCII 공백, UTC·시각 불명·콜론 경로, 반복 발생, 큰 한 줄, 20개 평가 질문의 출처 |
| 섹션·안전 출력·예산 | `tests/test_handoff.py` | 코드/주석/인용/들여쓰기/setext, 반복/빈 H2, CRLF/BOM, N/N-1, 10건 경계, 접두 선정, 큰 정수·surrogate·제어문자·bidi, 경고 샘플 상한 |
| 내장 JS·동일 builder | `tests/test_view_context.py`, `tests/fixtures/context-read/browser-harness.js`, `search-cases.json` | CLI/JS 순서·점수·source·스니펫 동일, IME/페이지/hash/popstate, 공격 문자열 비실행, 복사 성공/거부/API없음, Python builder 본문 동일 |
| 기존 뷰어 회귀 | 기존 `test_view*.py`, `tests/fixtures/viewer/html/browser-harness.js` | 기존 단언 유지. 구 harness에는 새 탭 DOM id만 추가. CSP hash/외부 리소스 차단/원문/출력 보존 검증 |
| 사용/복구 안내 | `README.md`, `README.ko.md`, `docs/{en,ko}/{workflows,troubleshooting}.md` | 명령·허용 H2·누락·예산·현재 검증과 당시 보고 구분·복사 실패·공유 범위 |
| 재현·사람 평가 | `tests/fixtures/context-read/{evaluation.md,evaluation-corpus.json,measure.py,measure.js,performance-2026-11-01.jsonl}` | 자동 필수 출처 20문항, 합성 부하 실측, 수동 확인 양식 |

## 구현 중 발견해 고친 경계 사례

1. reader의 수집값은 bytes와 fingerprint의 쌍이었다. manifest 입력에 bytes만 전달하도록 바로잡고 원본을 다시 읽지 않게 했다.
2. CRLF 섹션의 마지막 LF를 빠뜨리면 정상 CR이 제어문자로 보였다. 원문 범위의 줄 종결자를 포함해 JSON에 보존하고 Markdown에서 CRLF→LF 표시를 적용했다.
3. 열린 HTML 주석은 들여쓴 `-->`로도 닫힌다. 주석 내부에서는 들여쓰기 분류보다 주석 종료를 우선해 실제 뒤쪽 H2가 사라지지 않게 했다.
4. NFD 제목의 정규화된 위치를 원래 Jamo 문자열에 적용하면 강조가 어긋났다. 표시 제목을 NFC로 통일하고 모델/JSON의 원래 제목은 보존한다.
5. 20 MiB 문서에서 페이지 이동이 스니펫을 다시 계산했다. query/scope 캐시의 hit에 계산 결과를 저장해 페이지 이동에서 재사용한다.

처음 새 CLI/DOM이 없는 상태에서 신규 계약 테스트가 실패함을 확인한 뒤 구현했다. 주석 종료와 NFD 강조도 별도 실패→수정→통과로 확인했다. 테스트를 삭제해 실패를 숨기지 않았다.

## 성능 실측

macOS Bash3.2 / Python3.11.8 / Node26.12.1, 합성 입력을 임시 디렉터리에 복사한 단일 관측값이다. 측정 스크립트는 원본 저장소를 init하거나 기록을 쓰지 않는다. Node는 실제 내장 JS를 DOM 대역에서 실행하며 브라우저 paint·실제 peak heap을 측정하지 않는다. 아래 heap은 모델 로드 후부터 측정한 GC 미강제 변화량으로 총 메모리가 아니다.

재현: `python3 -B tests/fixtures/context-read/measure.py`. 기계별 편차가 있으므로 CI 성능 보장으로 해석하지 않는다. 마지막 두 경계 수정(주석 종료/제목 표시 NFC)은 측정 후 적용됐으며 성능 수치는 그 직전 캐시 구현의 값이다.

| 입력 | 입력 bytes | HTML bytes | 생성 초 | CLI 검색 초 | Node 최초 검색 ms | 다음 검색 ms | 캐시 페이지 ms | DOM 결과 행 | heap 변화 MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 55 | 16050 | 108332 | 0.1211 | 0.1008 | 1.95 | 0.79 | 0.15 | 50 | 1.13 |
| 5000 | 1440210 | 4195883 | 0.1944 | 0.1479 | 11.14 | 4.41 | 0.53 | 50 | 18.14 |
| 20000 | 5760210 | 16620890 | 0.6323 | 0.3135 | 41.37 | 9.83 | 0.39 | 50 | 55.42 |
| 20MiB | 20971520 | 21030390 | 0.2653 | 0.2423 | 83.37 | 39.72 | 0.09 | 2 | 20.54 |
| one-line-1MiB | 1048786 | 1107654 | 0.1237 | 0.1143 | 7.29 | 5.18 | 0.09 | 2 | 1.52 |
| 40000-warnings | 60210 | 11097029 | 0.2995 | 0.1795 | 18.97 | 1.81 | 0.06 | 1 | 30.71 |

5천 건의 생성 3초/검색 200ms 목표는 이 합성 관측에서 충족했다. 2만 건에서도 50행으로 제한했다. 경고 4만 개는 기존 뷰어의 접힌/50건 페이지를 유지하고, 인수인계는 경고 총수와 제한된 예시만 포함한다. 시각 미확인 대량 기록의 인수인계 JSON도 기본 예산 안에 들어갔다.

기본 12,000자 예산은 이 6개 합성 fixture에서 Markdown 6/6, JSON 6/6 성공했다. 출력 크기와 선택 수는 원시 JSONL에 있다. 이는 실제 사용자 문서의 성공률이 아니다. 필수 원문이 15,000자를 넘는 회귀 fixture는 CLI 실패/뷰어 해당 탭 budget_exceeded로 확인했다. 같은 필수 출력의 N자 성공/N-1자 실패와 형식별 필요 크기를 자동 검증한다.

## 호환성·회귀 검증

리뷰 전 구현 코드의 `python3 -B -m unittest discover -s tests -v`: **306개 / 117.259초 / OK**, skip 없음. 기준 258개에 신규 48개가 추가됐다. Bash 문법 및 `git diff --check` 통과, 내장 Python3.7 문법5개·Markdown 펜스/로컬 파일 링크165개 확인도 통과했다. 조사/계획 검토를 테스트 결과로 집계하지 않았다.

- macOS Bash3.2.57에서 문법 검사와 CLI 실행.
- Python3.7 문법: 내장 PYEOF 블록5개와 신규 Python 파일을 AST feature_version=(3,7)로 검사. 실제 3.7 런타임 검증은 아니다.
- macOS Python3.9.6와 3.13.3에서 각각 신규 48개 테스트 통과(25 검색/reader + 21 handoff + 2 HTML).
- Linux arm64 기존 이미지 f462f91ca01c: Python3.11.15/Bash5.2.15/Git2.39.5. 대상 118개 중 116개 통과, Node 미설치로 DOM harness 2개 skip. 네트워크 차단·rootfs/read mount 읽기 전용·임시 tmpfs에서 실행했다.
- Linux Node20.20.2 기존 이미지 50b7342053b1: 같은 새 HTML harness의 검색/페이지/IME/hash/복사 분기 통과. 모델은 macOS 생성 합성 입력을 제공했다. 실제 브라우저 확인이 아니다.
- Linux 최초 시도의 Git 오류 대역 테스트 실패는 tmpfs noexec가 원인이었다. `/proc/mounts`로 확인한 뒤 격리된 /tmp만 exec로 재실행했고 제품 코드를 바꾸지 않았다.
- `git diff --check`, Bash 문법, 신규 Node harness 문법을 확인한다. 추가 패키지·이미지 다운로드·CI 변경은 없다.

## 미실시와 다음 확인

실제 Python3.7/Windows 실행, Chrome/Safari file:// 화면·키보드·복사 권한·네트워크 관측, 사람의 60초 재개 비교는 미실시다. 이전 file:// 자동 접근 차단을 다른 브라우저/서버로 우회하지 않았다. Node의 DOM 대역은 이를 대신하지 않는다. [평가 양식](../../../tests/fixtures/context-read/evaluation.md)에 사람이 확인할 절차를 남겼다.

기존 수정 파일 `2026-10-30-local-context-viewer.md`는 작업 전 SHA-256 `8ecd05c687658bfe659da7fa184addb5875be7de32850c6dd5270a75de7319fd`와 동일하게 유지했다. contracts는 수정·이동·삭제·스테이징하지 않았다. 조사·설계·Claude 검토 원문도 그대로 두었다. 기존 전체 테스트 258개를 유지하고 새 테스트48개를 추가했다. 별도 소스 초기화·커밋·push·PR은 없다.

## Claude 코드 리뷰 후 수정·최종 검증

[코드 리뷰·반영 판단·응답 원문](../reviews/2026-11-01-search-handoff-code-claude.md)에 1차 전체 검토와 후속4회 조건 확인을 기록했다. 마지막 accept는 남아 있던 주석 종료 조건의 수정 확인이며 전체 제품이나 실브라우저 인증이 아니다.

리뷰를 재현해 수정한 내용: 목록/주석/코드 경계 오귀속의 모호 블록 격리, 잘못 수락된 scope, 텍스트 검색 출처 줄 위조 방지, 선형 제목 처리, 실제 EOF 행 범위, CRLF 표시 기준 예산 하한, extra-CR Python/JS 일치, 단일 BOM/빈 heading, lookbehind 제거, debounce 취소와 실제 callback, 빈 탭 안내, 긴 제목의 표시/DOM 상한이다. Git 공유 조회의 소유권 우회는 제거했다. 신뢰하는 Git clean/process 필터가 실행될 수 있는 제약은 한영 사용·복구 안내와 설계에 명시했다.

CLI 텍스트 검색은 제목/스니펫 고정 라벨과 한 줄 escape 형식으로 변경했다. JSON 응답/원문/입력·로그 저장 스키마는 유지했다. 전체 CommonMark 파서는 추가하지 않았고 불확실한 컨테이너/인라인 조합은 ambiguous로 제외한다. source/원문을 추정해서 채우지 않는다. 초기 구현 때의 설계 보존 기록과 달리 이번에는 리뷰 보완을 설계10절에 명시적으로 반영했다. 기존 사용자 수정 계획과 contracts는 그대로 보존했다.


## 최종 실행 검증 (2026-11-01)

최종 ctx.sh SHA-256: `60b389235fb2d5ee2c6e84d837683968be311d29c8946d69c77f5b0262b2bdb2`. 플랫폼 검증 복사본과 동일하다.

| 검증 | 실제 결과 |
| --- | --- |
| macOS Bash3.2 / Python3.11.8 전체 | `python3 -B -m unittest discover -s tests -v`: **331개 / 117.194초 / OK**, skip 없음 |
| macOS Python3.9.6 | reader/search32 + handoff36 + HTML5 = **73개 통과** |
| macOS Python3.13.3 | 같은 **73개 통과** |
| Linux arm64 Python3.11.15 / Bash5.2 / Git2.39 | 대상143개 중 **138개 통과, Node 부재로5개 skip** |
| Linux Python3.11.16 / Node20.20.2 | Linux에서 CLI/HTML 생성부터 실제 내장 JS의 **5개 통과** |
| 문법/정적 | Bash 문법, Python3.7 AST(내장5블록+신규 Python), Node harness 문법, diff 공백 검사 |

리뷰 전 306개에서 **25개 회귀 테스트를 추가**했다. 실패를 관찰한 뒤 수정한 사례와 기존 동작 확인을 구분했다. 전체/대상 테스트는 최종 코드로 실행했다. Linux의 두 이미지 모두 기존 로컬 이미지를 사용했고 network none / read-only root+source / 임시 tmpfs로 실행했다. 새 이미지·패키지 다운로드나 CI 변경은 없다.

실제 브라우저의 file:// 화면·키보드·클립보드 권한/paint, Python3.7 실런타임, Windows, 사람60초 평가는 계속 미실시다. 초기 자동 file:// 거부를 우회하지 않았다. Node 대역이나 Claude의 정적 accept를 이 검증으로 표현하지 않는다. Linux에서 skip된 기존 브라우저 harness 하나는 macOS 전체 테스트의 Node에서 통과했으며 Linux 실브라우저 검증은 아니다.

기존 수정 계획의 SHA-256 `8ecd05c687658bfe659da7fa184addb5875be7de32850c6dd5270a75de7319fd` 동일. contracts 미수정/미이동/미삭제/미스테이징, HEAD `6c0eb861c31c64f593cc66c25ad37a88a6b289bf` 유지, staged diff 없음. 원본 프로젝트의 init/commit/push/PR은 하지 않았다.

### 최종 코드의 합성 성능 재측정

원시 결과: `tests/fixtures/context-read/performance-2026-11-01-review.jsonl`. 앞선 구현 단계의 측정 파일은 보존했다. 같은 재현 스크립트의 단일 관측이며 Node DOM 대역/GC 미강제 값이다. 실브라우저 paint/총 peak 메모리 보장이 아니다.

| 입력 | HTML bytes | 생성 초 | CLI 검색 초 | Node 최초 검색 ms | 캐시 페이지 ms | DOM 행 |
| --- | --- | --- | --- | --- | --- | --- |
| 55 | 109008 | 0.1184 | 0.0971 | 1.86 | 0.13 | 50 |
| 5000 | 4196559 | 0.2071 | 0.1544 | 9.86 | 0.61 | 50 |
| 20000 | 16621566 | 0.4524 | 0.2996 | 40.39 | 0.42 | 50 |
| 20MiB | 21031066 | 0.2762 | 0.2299 | 85.05 | 0.10 | 2 |
| one-line-1MiB | 1108330 | 0.1253 | 0.1118 | 7.32 | 0.04 | 2 |
| 40000-warnings | 11097705 | 0.2957 | 0.1770 | 21.66 | 0.05 | 1 |

6개 합성 fixture는 Markdown/JSON 모두 기본 예산에 성공했다. 이 결과를 실제 사용자 문서의 성공률로 일반화하지 않는다.
