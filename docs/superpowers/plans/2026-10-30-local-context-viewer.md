# Local Context Viewer Implementation Plan

> 초기 뷰어의 설계·구현·검증 기록이다. 작업 분담과 의존 관계는 [병렬 실행 가이드](2026-10-30-local-context-viewer-parallel-execution.md)를 참고한다. 체크리스트는 구현 및 검증의 완료 여부를 나타낸다.

**Goal:** ctx-kit의 현재 문서와 활성·보관 작업 기록을 한 개의 오프라인 HTML로 탐색하여, 프로젝트 재개 시 현재 상태와 다음 행동을 1분 안에 파악하도록 돕는다.

**Architecture:** 기존 Markdown·JSONL을 정본으로 유지하고 `bash ctx.sh view`가 읽기용 스냅샷 HTML을 생성한다. 컨텍스트 수집, 기록 해석, Git 조회, 안전한 문서 표시, 파일 저장을 함수 단위로 분리하되 배포 코드는 기존 `ctx.sh`에 내장하여 두 파일 복사 설치를 유지한다. 외부 서버·DB·LLM 호출 없이 모든 검색과 탐색을 생성된 HTML 안에서 처리한다.

**Tech Stack:** Bash 3.2, Python 3.7 이상 표준 라이브러리, 인라인 HTML/CSS/일반 JavaScript, 기존 `unittest` 및 실제 브라우저 검증. npm·CDN·새 런타임 라이브러리·CI 설정 변경 없음.

---

## 1. 문서 상태와 조사 근거

- 작성일: 2026-10-30, Asia/Seoul.
- 상태: 초기 뷰어와 후속 통합 검색·근거 있는 인수인계의 **구현·통합 및 `main` 머지 완료**. [PR #7](https://github.com/nemory-dev/ctx-kit/pull/7)은 `75dac4e`로 머지됐다. 실제 브라우저 최종 확인과 사람의 1분 재개 평가는 남아 있다.
- 정리 기준: 2026-11-01, `main`의 `75dac4e`. 2~12절은 초기 뷰어의 설계·구현 계획, 13절은 구현 커밋 전 기록, 14절의 실행 결과는 초기 뷰어 커밋 `6c0eb86`의 후속 검증 기록이다. 과거 수치를 현재 버전의 결과로 바꾸지 않는다.
- 초기 구현 기준: Git 메타데이터 처리가 반영된 `537e1a3`의 CLI·저장소·테스트 구조를 바탕으로 개발했다.
- Claude 검토는 제안문만 대상으로 수행했다. 저장소를 읽은 코드 리뷰와 구분한다. [검토 원문](../reviews/2026-10-30-local-viewer-claude.md)에 응답을 그대로 보존했다.

구현 단계별 기준과 검증 범위:

| 단계 | 기준 커밋 | 검증 범위·근거 |
| --- | --- | --- |
| 초기 오프라인 뷰어 | `6c0eb86` | 뷰어 테스트 70개, 전체 회귀 258개. 당시 실행 환경과 수치는 13~14절에 보존한다. |
| 통합 검색·근거 있는 인수인계 추가 | `35893f8` | 뷰어 테스트 75개, 전체 회귀 331개 구성. 최종 실행 결과·플랫폼별 범위·성능은 [후속 구현 결과](../reports/2026-11-01-search-handoff-implementation.md)에 기록했다. |
| `main` 머지 후 CI | `75dac4e` | [CI 성공](https://github.com/nemory-dev/ctx-kit/actions/runs/41287543903). macOS는 331개 통과, Ubuntu는 330개 통과·대소문자를 구분하지 않는 파일시스템이 필요한 1개 건너뜀. 두 환경의 Bash 문법 검사도 통과했다. |

계획 작성 당시 코드에서 확인한 사실:

| 근거 | 확인 내용 | 설계에 미치는 영향 |
|---|---|---|
| `README.ko.md`, `docs/ko/getting-started.md` | `ctx.sh`와 설정만 복사하는 설치, 루트와 `scripts/` 설치, Python 3.7 이상 지원 | 별도 UI 폴더를 런타임 필수 파일로 추가하지 않는다. |
| `ctx.sh: context_python()` | JSONL 읽기, archive 경로 열거, 공통 잠금, 원자적 쓰기와 복구 함수가 있다. | 기존 잠금을 수집에 사용하되 복구 동작과 분리한다. |
| `context_python --read-only` | 현재는 잠금과 archive 복구를 모두 생략한다. | 이 모드를 호출하는 것만으로 일관된 통합 이력이 보장되지는 않는다. |
| `cmd_log()`, `cmd_backfill()` | 제목·요약·시각·유형·커밋 참조·브랜치·파일 목록을 기록한다. | 기존 레코드만으로 타임라인과 파일별 조회가 가능하다. |
| `_hook_run_pre_commit()` | `pending`을 저장하고 나중에 실제 해시로 교체하지 않는다. | 비슷한 시각·파일 목록을 이용한 커밋 추정 연결을 하지 않는다. |
| `cmd_archive()`, `tests/test_storage.py` | 동일 내용이나 legacy ID 충돌도 별개 기록으로 보존한다. 중단 시 journal과 겹치는 레코드가 남을 수 있다. | 중복 제거를 하지 않고, 미완료 archive가 있으면 생성을 중단한다. |
| 내장 문서 템플릿 | 계획과 ADR은 편집 가능한 Markdown이며 고정 JSON 스키마가 아니다. | 섹션을 읽되 내용의 정당성·결정 효력을 자동 판정하지 않는다. |
| `tests/`, `.github/workflows/ci.yml` | 임시 프로젝트에 CLI를 복사하는 unittest, Linux/macOS 검사 | 새 테스트도 실제 복사 설치를 사용한다. |

## 2. Claude 의견 취합과 최종 판단

| Claude 의견 | 판단 | 반영 방식·근거 |
|---|---|---|
| 정적 HTML부터 시작 | 채택 | 서버 관리가 없고 기존 로컬 CLI 배포에 맞는다. |
| 현황·통합 타임라인·파일별 조회에 집중 | 채택 | 세 가지 사용 흐름을 먼저 완성한다. 파일 조회는 타임라인의 필터·상세 기능으로 제공한다. |
| 출처를 데이터 모델에 명시 | 채택 | 문서 기재, 기록 당시 로그, 생성 시점 Git 조회를 별도 필드·문구로 표시한다. |
| 해시가 있는 기록만 커밋에 연결 | 채택·보정 | 실제 커밋 객체 조회 여부를 표시한다. 객체가 조회돼도 작업 완료·현재 브랜치 포함·배포를 증명하지 않는다. |
| 결정 기록은 보류 | 부분 조정 | `decisions.md`와 보관된 결정 문서를 읽기 좋게 표시한다. 결정 상태 자동 분류와 코드 연결은 보류한다. 실제 Markdown 파일은 이미 존재한다. |
| 내용 해시로 중복 제거, pending과 최종 로그 묶기 | 미채택 | 같은 내용도 별개 작업일 수 있다. 기존 archive의 발생 건수 보존 원칙과 충돌하며 두 로그를 연결할 키도 없다. |
| 잘린 JSONL 마지막 행을 건너뛰기 | 미채택 | 기존 저장소는 손상에 명시 실패한다. 일부 기록을 누락한 HTML을 정상 결과처럼 만들지 않는다. |
| 잠금 없는 경우 archive를 먼저 읽고 deduplicate | 미채택 | 수집 시점 일관성을 보장하지 못한다. 이미 존재하는 공통 잠금을 사용한다. |
| NFC 정규화로 한글 검색 보완 | 범위 제한 후 채택 | 검색용 문자열만 정규화한다. 원문 경로·ID·파일 선택의 동일성은 변경하지 않는다. |
| 중간 JSON 출력 옵션 | 내부 모델만 채택 | HTML 내 데이터 블록으로 테스트한다. 새 공개 JSON API는 첫 버전에 추가하지 않는다. |
| 오래된 문서의 커밋 수 계산 | 보류 | 컨텍스트는 별도 로컬 Git 저장소일 수도 있어 단순 계산이 부정확하다. 수집 시각과 원문 날짜를 그대로 표시한다. |
| 안전한 데이터 삽입, 외부 요청 차단, 원자적 출력 | 채택 | 데이터 이스케이프·DOM 텍스트 삽입·CSP·안전한 파일 저장을 먼저 구현한다. |
| `.gitignore` 자동 추가, `--force` 덮어쓰기 | 미채택 | 뷰어 생성이 프로젝트 설정까지 바꾸지 않게 한다. 기존 사용자 HTML은 보존하고 다른 출력 경로를 안내한다. |

## 3. 첫 버전의 범위

포함:

1. 현재 상태와 다음 행동을 첫 화면에 배치하고 원문 문서로 이동.
2. 활성 로그와 `archive/timeline-*.jsonl` 전체를 합친 작업 목록.
3. 제목·요약·기록된 파일명 검색, 유형·날짜·정확한 파일 경로 필터.
4. 작업 상세에서 원문 요약, 출처 파일·행, 기록 시각, 브랜치, 커밋 참조, 파일 목록 표시.
5. 파일을 선택하면 해당 문자열이 `files`에 있는 기록으로 필터.
6. 계획·결정·백로그·다이제스트·보관된 완료 작업과 결정 문서 탐색.
7. 생성 시점의 Git 브랜치·HEAD·미커밋 파일 목록, 조회 불가 상태 표시.
8. 생성 시각, 조회 범위와 경고 표시. `--open` 선택 시 생성 후 브라우저 열기.

제외:

- 문서·로그 편집, 작업 실행, 자동 archive 복구, 자동 커밋.
- Git 훅 자동 HTML 생성, 파일 감시, 백그라운드 서버.
- 코드 전문 수집, 함수·호출 관계 분석, rename 추적, 코드 diff 표시.
- AI 요약·RAG·의미 검색, 로그에서 테스트 결과를 추출한 현재 상태 배지.
- 결정과 파일의 추론 연결, 결정 유효성 판정, pending 기록의 커밋 추정.
- 여러 프로젝트 통합, 원격 공유·호스팅·로그인.

## 4. 사용자 흐름과 화면

### 4.1 CLI 계약

```bash
# 제안 명령. 구현 완료 후 사용할 수 있다.
bash ctx.sh view
bash ctx.sh view --open
bash ctx.sh view --output reports/context-view.html
bash scripts/ctx.sh view --open
bash ctx.sh view --help
```

- 기본 출력: 설정된 컨텍스트 디렉터리의 `generated/view.html`.
- `--output`: 프로젝트 루트 기준 상대 경로. 프로젝트 안의 절대 경로도 허용한다. 확장자는 `.html`이며 실제 경로가 프로젝트 밖이면 거부한다.
- 인자 없는 `--output`, 빈 문자열, 알 수 없는 옵션·위치 인자: stderr 설명과 종료 코드 1. `--help`는 변경 없이 0.
- `--open`을 생략하면 브라우저를 열지 않는다. 생성 성공은 0.
- 생성 후 브라우저 열기에 실패하면 HTML을 보존하고 경로와 실패 이유를 출력하며 1로 종료한다. 생성 실패와 구분해서 설명한다.
- 설정과 컨텍스트 디렉터리가 없으면 `init` 안내와 함께 실패한다. `view`가 초기화·sync를 대신 실행하지 않는다.
- 출력 파일과 필요한 출력 디렉터리, 공통 잠금 파일 이외에는 쓰지 않는다. 로그도 자동 추가하지 않는다.

### 4.2 화면 구성

```text
프로젝트명   생성 시각 / 생성 이후 경과 시간   [갱신 명령 안내]
──────────────────────────────────────────────────────────
탐색          본문
  개요         현재 상태             다음 행동
  작업 기록    문서 기재라는 표시     문서 기재라는 표시
  문서         생성 시점 Git: 브랜치 / HEAD / 변경 파일 수
               최근 작업 5건

작업 기록: 검색창 + 유형·날짜·파일 필터 + 결과 개수
               작업 목록             선택한 작업 상세
```

- 불필요한 랜딩 화면 없이 곧바로 현황을 표시한다. 좁은 창에서는 목록 아래에 상세를 배치한다.
- 문서 탐색은 `MASTER_PLAN`, 결정, 백로그, 다이제스트, 보관 문서를 명확히 구분한다.
- 계획의 `## Current State`/`## 현재 상태`, `## Next Actions`/`## 다음 행동`을 다음 동급·상위 제목 전까지 추출한다. 섹션이 없으면 ‘해당 섹션 없음’과 전체 문서 이동을 표시하며 임의 요약하지 않는다.
- 체크박스는 문서에 기재된 표시일 뿐 실제 완료를 재판정하지 않는다.
- 기본 정렬은 시간대가 확인되는 기록의 UTC 시각 내림차순. 같은 시각은 출처 경로·원문 행으로 안정 정렬한다. 시각 미확인 기록은 뒤에 모으며 개수를 표시한다.
- 날짜 필터는 브라우저 현지 날짜 기준임을 라벨에 표시한다. 시간대 없는 legacy 시각은 필터에서 제외하고 제외 건수를 안내한다.
- 검색은 제목·요약·파일명을 대상으로 대소문자를 구분하지 않는다. 검색용 문자열만 NFC 정규화한다. 한글 IME 조합 중에는 실행을 미루고 조합 완료 후 반영한다.
- 정확한 파일 필터는 원본 문자열로 비교한다. 정규화 결과가 같은 서로 다른 경로도 합치지 않는다.
- 한 번에 50건을 표시하고 다음·이전 페이지, 전체 결과 수, 필터 해제를 제공한다. 검색어 변경 시 첫 페이지로 이동한다.
- 필터·검색어·선택 항목은 URL hash에 넣는다. `localStorage`, 외부 JSON `fetch`, ES module 로딩에 의존하지 않는다. 잘못된 hash 값은 무시하고 기본 화면을 표시한다.
- 목록 행과 필터는 키보드로 접근하고 선택 상태를 표시한다. 검색창 label과 상세 영역 제목을 제공한다.
- 경고는 총건수가 있는 접힌 요약으로 시작하고, 펼친 동안 50개씩 표시한다. 원래 경고 목록은 모델에 모두 보존한다.
- 항상 ‘생성 시점의 스냅샷’임을 표시한다. 경과 시간은 참고 정보이며 원본 변경 여부를 감지했다고 표현하지 않는다. 브라우저 새로고침만으로 원본이 갱신되지는 않는다.

## 5. 입력과 내부 데이터 모델

### 5.1 입력 허용 목록

설정된 컨텍스트 디렉터리에서만 다음 파일을 읽는다.

```text
MASTER_PLAN.md
decisions.md
backlog.md
work-log/timeline-digest.md
work-log/timeline.jsonl
archive/completed-tasks.md
archive/decisions-deprecated.md
archive/timeline-*.jsonl
```

- 프로젝트 코드·환경 파일·대화 전문을 재귀 수집하지 않는다. `generate.collect`도 사용하지 않는다.
- Markdown·로그가 없으면 ‘기록 없음’으로 표시한다. 모두 비어 있어도 컨텍스트 디렉터리가 있으면 빈 상태 뷰어를 만든다.
- 각 입력은 일반 파일이어야 한다. 입력 파일·하위 입력 디렉터리의 심볼릭 링크와 컨텍스트 밖으로 나가는 경로는 거부한다. 설정으로 선택한 컨텍스트의 실제 루트도 프로젝트 안이어야 한다. 이 제약은 `view`에만 적용하고 다른 명령의 해석을 변경하지 않는다.
- UTF-8 디코딩 실패, JSON 문법 손상, JSONL 행이 객체가 아닌 경우에는 파일·행을 알리고 생성 실패. 기존 결과는 보존한다.
- 객체 내 legacy 선택 필드가 없거나 타입이 맞지 않으면 표시값을 ‘미기록’으로 두고 경고를 남긴다. 원문 객체는 상세에서 텍스트로 확인할 수 있게 보존한다. 알 수 없는 `type`도 삭제하지 않는다.
- 초기 한도는 전체 입력 20 MiB, 작업 기록 20,000건이다. 초과 시 조용히 생략하지 않고 실패한다. 실제 성능 검증에서 변경한다면 문서와 경계값 테스트를 함께 변경한다.

### 5.2 내부 모델 예시

아래는 HTML 내부 데이터 형식이며 새 공개 저장 형식은 아니다.

```json
{
  "viewModelVersion": 1,
  "generatedAt": "2026-10-30T01:00:00+00:00",
  "project": {"name": "example", "contextPath": "sample-context"},
  "documents": [
    {"key": "plan", "path": "MASTER_PLAN.md", "sourceKind": "document", "status": "present", "text": "# Plan"}
  ],
  "entries": [
    {
      "key": "work-log/timeline.jsonl:1",
      "sourceKind": "work_log",
      "sourcePath": "work-log/timeline.jsonl",
      "sourceLine": 1,
      "record": {"summary": "작업 기록", "commit": "pending", "files": ["src/app.kt"]},
      "recordText": "{\"summary\":\"작업 기록\",\"commit\":\"pending\",\"files\":[\"src/app.kt\"]}",
      "commitObjectRef": null,
      "timestampUtc": null,
      "commitObjectStatus": "not_recorded"
    }
  ],
  "git": {"status": "not_repository", "observedAt": "2026-10-30T01:00:00+00:00"},
  "warnings": []
}
```

- `recordText`는 LF를 제외한 원래 JSONL 행을 보존한다. 원문 상세는 이 문자열을 표시하여 JavaScript의 큰 정수·소수 반올림이나 재직렬화로 값을 바꾸지 않는다.
- `record`는 파싱한 원래 레코드를 유지한다. `id`는 DOM 키나 중복 제거 키로 사용하지 않는다. `key`는 이 스냅샷 안에서만 쓰는 식별자이며 archive 이후에도 유지되는 영구 ID가 아니다.
- 같은 ID·내용·커밋의 여러 행도 모두 표시한다. 서로 다른 기록을 같은 작업으로 추정하지 않는다.
- 원래 `createdAt`은 그대로 보존한다. offset/Z를 포함하고 해석 가능한 경우에만 UTC 비교값을 만든다. 누락·잘못된 형식·시간대 없는 값은 시각 미확인으로 처리한다.
- `dirty`는 기록 당시의 값으로만 표시한다. 특히 `pending`과 `dirty=false`를 현재 작업 트리가 깨끗하다는 뜻으로 해석하지 않는다.
- 원문의 ‘테스트 통과’, ‘완료’는 당시 로그에 남긴 보고로 표시한다. 문자열을 분석해 현재 성공 배지를 만들지 않는다.

## 6. 스냅샷의 일관성

1. `require_config`, 기존 경로 해석, `require_python`을 사용한다. 기존 명령의 동작은 변경하지 않는다.
2. `context_python --read-only` 안에서 명시적으로 기존 `context_lock()`을 획득한다. `recover_archive()`는 호출하지 않는다. 기존 잠금의 대기 상한 30초와 오류 처리를 따른다.
3. 잠금을 보유한 상태에서 `.ctx-archive-transaction.json`이 있으면 중단한다. 잘못된 journal이나 symlink도 존재하는 한 중단 대상이다. journal과 기록을 복구·삭제하지 않고 기존 복구 가이드를 안내한다.
4. 입력 목록과 문서·JSONL의 바이트를 잠금 안에서 모두 읽는다. 외부 편집기의 수정을 고려해 설정·대상 목록·내용 지문을 수집 전후에 비교한다. 다르면 잠금을 해제하고 한 번만 다시 수집하며, 반복되면 중단한다.
5. 잠금을 따르지 않는 수동 편집까지 완전한 원자성을 보장한다고 표현하지 않는다. 표시 문서는 실제 읽은 바이트이며 수집 기간을 메타데이터에 남긴다.
6. 수집 후 잠금을 해제한다. Git 조회, HTML 구성, 출력 저장, 브라우저 실행 중에는 잠금을 유지하지 않는다.

읽기 전용은 ‘컨텍스트 원본을 변경하지 않음’을 뜻한다. 기존 잠금 기구는 `work-log/.ctx.lock`과 필요한 부모 디렉터리를 만들 수 있다. 이를 생성 작업의 동기화 파일로 설명하고, 만들거나 획득할 수 없으면 명시적으로 실패한다. 읽기 전용 파일시스템에 대응하기 위해 잠금을 생략하지 않는다.

## 7. Git 정보의 처리

- `subprocess`의 인자 배열로 호출하고 shell은 사용하지 않는다. 경로는 `--` 뒤에 전달한다. 네트워크 작업은 수행하지 않는다.
- Git 없음, Git 관리 밖, HEAD 없음, detached HEAD, 조회 실패를 별도 상태로 둔다. 문서와 로그 생성은 계속하고 Git 영역에 원인을 표시한다. 실패를 ‘변경 없음’으로 바꾸지 않는다.
- 브랜치·HEAD와 `status --porcelain=v1 -z --untracked-files=all`을 읽는다. rename/copy의 추가 경로도 NUL 단위로 해석하고 공백·개행·탭·한글 경로를 보존한다. 구현 시점의 `git_output`/`git_paths`를 재사용할 수 있으면 동작을 확인하고 활용한다.
- 각 Git 프로세스에 5초 timeout을 적용한다. HEAD와 status를 전후 확인하고 달라지면 한 번 다시 조회한다. 안정되지 않으면 ‘조회 중 변경됨’으로 표시한다. 컨텍스트와 Git 전체를 한 시점에 원자적으로 수집했다고 표현하지 않는다.
- 기존 생성 출력과 `work-log/.ctx.lock`은 literal pathspec으로 status 대상에서 제외한다. HTML 생성 때문에 생긴 변경을 관측값에 섞지 않는다.
- `pending`/`uncommitted`는 ‘커밋 미확인’으로 표시한다. `commit`이 누락·null·빈 문자열일 때만 명시된 `fullCommit`을 사용한다. 실제 조회한 문자열은 `commitObjectRef`로 구분하고 원래 필드를 보존한다. 모호한 축약 참조를 `fullCommit`으로 추정 보정하지 않는다.
- 명시된 16진수의 축약·전체 해시만 대상으로, 서로 다른 참조를 `git cat-file --batch-check`에 전달해 커밋 객체를 일괄 확인한다. 모호한 참조·미존재·commit이 아닌 객체는 확인 불가로 처리한다. 기록마다 별도 프로세스를 실행하지 않는다.
- 성공 라벨은 ‘기록의 참조 대상을 Git에서 확인’, 실패 라벨은 ‘이 checkout에서 참조 대상을 확인할 수 없음’으로 한다. 작업 완료·과거 커밋 실패·현재 브랜치 포함 여부는 추측하지 않는다.
- 파일명을 눌러도 코드 전문을 읽지 않는다. Git remote에서 GitHub URL을 추측하거나 임의 `file:` 링크를 만들지 않는다.

## 8. HTML 생성과 출력 보호

### 8.1 데이터와 문서 표시

- HTML·CSS·JS·JSON을 한 파일에 넣는다. 외부 폰트·이미지·라이브러리·fetch·module import·service worker를 사용하지 않는다.
- JSON 데이터 블록의 `<`, `>`, `&`, U+2028, U+2029는 Unicode escape로 변환한다. `</script>` 입력으로 script 요소가 늘어나지 않는지 검증한다.
- `JSON.parse`로 데이터를 읽고 문자열은 `textContent`와 DOM 생성 API로 표시한다. 입력을 `innerHTML`·`eval`·`Function`에 전달하지 않는다.
- Markdown은 제목·문단·글머리 목록·번호 목록·체크리스트·인용·코드 펜스·인라인 코드·링크를 제한적으로 지원한다. 인용이 32단계를 넘으면 나머지를 원문으로 표시한다. 반복 입력은 선형 스캔으로 처리한다. 미지원 표와 확장 문법은 내용을 버리지 않고 등폭 원문으로 표시한다. raw HTML은 문자열로 표시한다.
- URL의 제어문자를 거부하고 `http`/`https`와 확인된 내부 앵커만 링크로 만든다. 상대 링크는 허용 문서에 대응하는 경우에만 내부 이동으로 처리하고 나머지는 텍스트로 표시한다.
- 외부 링크는 사용자가 누를 때만 열며 `noopener noreferrer`를 붙인다. Markdown 이미지는 읽지 않고 alt 텍스트로 표시한다.
- CSP는 `default-src 'none'`, `connect-src 'none'`, `img-src 'none'`, `object-src 'none'`, `base-uri 'none'`, `form-action 'none'`을 기본으로 한다. 고정 JS/CSS는 실제 바이트의 SHA-256으로 허용한다. meta에서 유효한 범위로 적용하고 CSP에만 의존하지 않는다.

### 8.2 저장과 실패 동작

- 첫 줄에 `<!-- ctx-kit-viewer:1 -->`이 있는 생성물만 덮어쓸 수 있다. 표식 없는 기존 HTML, symlink, 디렉터리, FIFO, hardlink가 여러 개인 출력은 거부한다. `--force`는 제공하지 않는다.
- 출력 부모의 symlink를 포함해 실제 경로를 확인하고 입력·설정·스크립트와 실제 경로/inode가 충돌하면 거부한다. 입력을 출력으로 읽거나 교체하지 않는다.
- 같은 디렉터리의 전용 임시 파일에 전체를 쓰고 flush·fsync 후 `os.replace`한다. 기존 생성물의 권한을 유지하고 새 파일은 소유자만 읽고 쓸 수 있게 만든다.
- 쓰기·교체 전에 기존 출력의 상태가 달라지면 중단한다. 다른 생성 프로세스와의 완전한 배타성을 보장하지 않으며, 감지한 변경은 덮어쓰지 않는다.
- 입력·렌더링·임시 쓰기·교체 실패 시 이전 출력의 내용을 보존하고 이번 실행의 임시 파일만 정리한다. 교체 후 디렉터리 동기화가 실패하면 새 출력이 존재할 수 있음을 알리고 종료 코드 1을 반환한다.
- `.gitignore`·설정·hook은 자동 변경하지 않는다. 생성물에 로그 전문이 포함된다는 점과 공유 전 검토를 CLI 출력과 가이드에 짧게 안내한다. 자동 마스킹을 보장하지 않는다.

## 9. 변경 예정 파일과 책임

| 파일 | 변경 내용 |
|---|---|
| `ctx.sh` | `cmd_view`, help·dispatch 추가. Python 수집·모델·렌더링·저장 함수와 고정 CSS·JS 내장. 기존 기능의 대규모 재배치는 하지 않는다. |
| `tests/viewer_support.py` | 통합 담당 소유의 공통 임시 프로젝트 fixture와 HTML 데이터 추출 helper. |
| `tests/test_view.py` | 실제 두 파일 복사 설치와 CLI 계약. 통합 담당 소유. |
| `tests/test_view_data.py` | 수집·정규화·출처·Git·동시성 테스트. 데이터 담당 소유. |
| `tests/test_view_html.py` | HTML 데이터 삽입·문서·CSP·표시 구조 테스트. 화면 담당 소유. |
| `tests/test_view_safety.py` | 출력 보호·장애·브라우저 실행 테스트. 저장 담당 소유. |
| `tests/fixtures/viewer/` | 작은 정상·legacy·공격 문자열 예제. 실제 개인 로그와 인증값은 넣지 않는다. |
| `README.md`, `README.ko.md` | 명령 표, 로컬 열람의 가장 짧은 예와 스냅샷 제약. |
| `docs/en/workflows.md`, `docs/ko/workflows.md` | 생성·열기·재생성·검색·출력 경로 변경 절차. |
| `docs/en/troubleshooting.md`, `docs/ko/troubleshooting.md` | 미완료 archive, 손상 로그, 잠금, 출력 보호, 브라우저 실행 실패. |

`AGENT_RULES.md`, 내장 규칙 템플릿, `ctx.config.json` 기본값, CI 설정은 변경하지 않는다. 기존 `source`를 사용하므로 새 설정 키도 필요하지 않다.

## 10. 구현 작업: 조사 → 수정 → 검증 → 정리

각 작업은 테스트 추가 → 미구현·부족 동작에 의한 실패 확인 → 최소 구현 → 해당 테스트 성공 순서로 진행한다.

병렬 실행 시 기능 범위는 유지하면서 테스트 파일을 위 소유권 표에 따라 분리한다. Task 2~3은 데이터 담당, Task 4~5는 화면 담당, Task 6은 저장 담당이 소유한다. Task 0~1과 최종 통합은 통합 담당이 수행한다. 의존 관계와 함수 계약은 병렬 실행 가이드를 따른다.

### Task 0: 작업 상태와 구현 경계 재확인

대상: `ctx.sh`, 기존 테스트, 작업 트리. 이 단계에서는 변경하지 않는다.

- [x] `git status --short`, `git diff -- ctx.sh`로 타 작업을 확인하고 보호 범위를 기록한다.
- [x] 현재 `context_lock`, read-only 호출, Git 경로 수집 구현을 다시 읽고 계획과 차이를 확인한다.
- [x] `bash -n ctx.sh`와 기존 unittest로 시작 상태를 확인한다. 기존 실패를 이번 기능 수정에 섞어 해결하지 않는다.

### Task 1: CLI 진입점과 복사 설치 계약

대상: `ctx.sh: cmd_help/main dispatch/cmd_view`, `tests/test_view.py`.

- [x] 테스트 fixture는 임시 프로젝트에 `ctx.sh`와 최소 설정만 복사하고 문서·JSONL을 직접 준비한다. init·hook의 부가 동작에 의존하지 않는다.
- [x] `test_view_help_does_not_write`, `test_view_rejects_missing_output_value`, `test_view_rejects_unknown_option`, `test_view_requires_context`를 추가해 실행한다.
- [x] 옵션 해석·오류 계약·help·dispatch를 구현한다. help는 Python이 필요한 처리보다 먼저 실행한다.
- [x] `test_view_standalone_copy`, `test_view_scripts_install_and_custom_context`를 추가해 별도 UI 파일 없이 최소 생성 경로가 동작하는지 확인한다.

### Task 2: 원본을 보존하는 스냅샷 수집

대상: `ctx.sh: cmd_view 내부 collect_snapshot`, `tests/test_view.py`, fixture.

- [x] 활성·월별·legacy archive, 빈 파일, 누락 문서 수집 테스트를 추가한다.
- [x] `test_view_keeps_identical_occurrences_and_colliding_ids`로 같은 ID·내용의 여러 행이 남는지 검증한다.
- [x] 다른 프로세스가 `context_lock()`을 보유하면 생성이 대기하고 해제 후 진행하는지 확인한다. journal이 있으면 기존 HTML·원본을 보존하고 실패하는 테스트도 추가한다.
- [x] 잠금 안에서 허용 목록·바이트·원래 행 번호를 확정하는 수집 함수를 구현한다. 잠금 외에 원본 쓰기는 하지 않는다.
- [x] 문서 중간 변경·파일 목록 변경을 주입해 한 번 재수집하거나 명시 실패하는지 확인한다.
- [x] 잘못된 JSON·객체가 아닌 행·잘못된 UTF-8·일반 파일이 아닌 입력·상한 초과 테스트로 기존 출력을 보존하는지 확인한다.

### Task 3: 출처 모델과 Git 관측

대상: `ctx.sh: build_view_model / collect_git_snapshot`, `tests/test_view.py`.

- [x] 타입이 다른 legacy 필드, 시차가 있는 날짜, offset 없는 시각, 빈 `files` 테스트를 추가한다.
- [x] 원본을 유지하면서 출처·행 번호·비교 가능한 시각을 별도 보유하는 모델을 구현한다. 현재 timeline 저장 형식은 바꾸지 않는다.
- [x] Git 관리 밖·Git 없음·HEAD 없음·detached HEAD, 정상·불명·모호한 커밋, pending, Git 실패·timeout 테스트를 추가한다.
- [x] NUL 구분 status의 rename/copy, 개행·공백·탭·쉼표·NFC/NFD 한글 경로를 검증한다.
- [x] Git을 일괄 조회하고 부분 실패를 모델 상태로 남긴다. 기록 당시 dirty와 현재 Git 변경을 분리한다.
- [x] 생성 출력과 lock 파일이 현재 변경 수에 혼입되지 않는지 확인한다.

### Task 4: 단일 HTML과 안전한 문서 표시

대상: `ctx.sh: render_view_html / VIEW_CSS / VIEW_JS`, `tests/test_view.py`, 공격 fixture.

- [x] 표준 `html.parser.HTMLParser`로 데이터 블록을 추출하고 JSON을 복원하는 테스트를 추가한다.
- [x] `</script><script>`, raw HTML, `javascript:`, 외부 이미지, 따옴표, U+2028/U+2029를 문서·로그·경로에 넣는 테스트를 추가한다.
- [x] 안전한 JSON 삽입, 고정 script/style의 CSP 해시, DOM textContent 표시를 구현한다.
- [x] 지원 Markdown의 제목·목록·코드 펜스·링크와 미지원 문법의 원문 표시를 구현한다.
- [x] 공격 fixture가 추가 script·img·외부 리소스를 만들지 않는지 정적으로 확인한다. 실제 실행 검증은 Task 7에서 수행한다.

### Task 5: 검색 가능한 열람 화면

대상: `ctx.sh: VIEW_CSS / VIEW_JS`, 정상·legacy fixture.

- [x] 현황·다음 행동·최근 5건·문서 유무·생성 시점 Git 상태를 표시한다.
- [x] 검색·유형·날짜·정확한 파일 필터·50건 페이지·상세를 구현한다.
- [x] 검색용 NFC, IME 조합, 빈 결과, 필터 해제, 누락 날짜, URL hash 복원·잘못된 값 처리를 구현한다.
- [x] 같은 시각·ID·내용의 행도 각각 선택할 수 있고 파일 선택은 원래 문자열로 비교하는지 확인한다.
- [ ] 1280px·768px·390px 폭과 키보드 조작에서 첫 화면부터 다음 행동까지 접근 가능한지 확인한다. 폭별 Headless Chromium 검증과 Node 키보드 접근 계약 검증은 수행했으며 실제 브라우저 키보드 조작은 미실시했다.

### Task 6: 저장 보호와 브라우저 실행

대상: `ctx.sh: write_view_html / open_view`, `tests/test_view.py`.

- [x] 첫 생성·기존 생성물 갱신·사용자 HTML 보존 테스트를 추가한다.
- [x] 출력 symlink·부모 symlink·hardlink·디렉터리·입력 별칭 충돌·프로젝트 밖 출력을 검증한다.
- [x] 임시 파일의 flush·fsync·원자적 교체와 교체 전 출력 변경 감지를 구현한다.
- [x] 기존 테스트와 같은 `sitecustomize.py` 방식으로 쓰기·fsync·replace 실패를 주입한다. 이전 출력·원본 바이트·임시 파일 정리를 확인한다.
- [x] 브라우저는 Python `webbrowser`로 열고 테스트에서는 `BROWSER`에 임시 기록용 stub을 지정한다. 기본 실행에서는 열지 않고 `--open`에서만 열며 실행 실패 시 HTML이 남는지 확인한다.

### Task 7: 실제 브라우저·성능·문서·전체 회귀

대상: 한국어·영문 README/이용 가이드/문제 해결 문서, 전체 테스트.

- [ ] Safari·Chrome에서 생성 파일을 `file://`로 열고 초기 표시·검색·페이지 이동·문서 이동 시 외부 요청이 없는지 확인한다. Firefox는 사용 가능하면 확인하고 미실시라면 명시한다.
- [ ] 공격 fixture에서 script 실행·외부 이미지 요청·위험 URL 이동이 없고, 명시적으로 클릭한 https 링크는 동작하는지 확인한다.
- [ ] 5,000건·20,000건, 입력 합계 20 MiB 이내의 합성 데이터로 생성 시간·HTML 크기·검색 지연을 측정한다. Apple Silicon 기종·브라우저 버전을 남긴다. 잠정 목표는 5,000건 생성 3초 이내·검색 반영 200ms 이내이며, 20,000건에서도 전체 행을 DOM에 생성하지 않고 조작 가능해야 한다.
- [ ] 내용을 모르는 상태에서 HTML을 열어 현재 상태와 다음 행동을 설명하기까지 시간을 잰다. 같은 fixture의 Markdown 직접 열람과 비교하고 ‘1분’을 평가한다. 테스트 수만으로 달성을 선언하지 않는다.
- [x] 한국어·영문 예제, 스냅샷 제약, 입력 상한, 잠금, 원본 보존, 공유 범위, 장애 대응을 갱신한다.
- [x] 대상 테스트 이후 기존 전체 테스트·Bash 구문·diff를 검사한다. 추가 변경·실패가 없다면 같은 검사를 무의미하게 반복하지 않는다.

## 11. 검증 명령과 합격 기준

아래는 구현 후 실행할 명령이다. 계획 작성 시점에 새 테스트가 존재한다는 뜻은 아니다.

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -p 'test_view*.py' -v
python3 -B -m unittest discover -s tests -v
git diff --check
```

구현 테스트의 최소 단언 예:

```python
# fixture: 같은 ID·내용을 active와 archive에 한 행씩 준비한다.
self.assertEqual(result.returncode, 0, result.stderr)
model = self.read_view_model(output)
self.assertEqual(len(model["entries"]), 2)
self.assertNotEqual(model["entries"][0]["key"], model["entries"][1]["key"])

# fixture: 이전 생성물과 미완료 archive journal을 준비한다.
self.assertNotEqual(result.returncode, 0)
self.assertEqual(output.read_bytes(), previous_html)
self.assertEqual(self.source_snapshot(), sources_before)
```

`read_view_model`은 `HTMLParser`로 `application/json` 블록을 추출하는 테스트 helper, `source_snapshot`은 입력 파일의 바이트 사전을 반환하는 fixture helper로 `tests/viewer_support.py`에 정의한다. 통합 담당이 공통 fixture를 먼저 준비하고 각 테스트 파일에서 사용한다. 브라우저에서 JS를 실행하는 검증은 Python 문자열 검사와 별도로 수행해야 한다.

완료 판정:

- 별도 리소스 파일·서버 없이 HTML 하나로 대상 브라우저에서 열람·검색한다.
- 보관 전후를 포함한 입력 행 수·내용을 보존하고 pending·legacy·미확인을 사실로 오표시하지 않는다.
- 공격 입력이 코드 실행이나 자동 네트워크 요청으로 이어지지 않는다.
- 생성 실패 시 기존 결과·원본을 보존하고 미완료 archive를 임의 복구하지 않는다.
- 복사 설치·`scripts/` 설치·사용자 지정 컨텍스트와 기존 회귀가 통과한다.
- 미검증 OS·브라우저·Python 버전을 명시한다. Python 3.7 구문 호환은 필요하지만 실행하지 않은 환경을 검증 완료로 표시하지 않는다.
- 구현·검증·기록·commit·merge를 구분해 보고한다.

## 12. 단계별 도달점과 후속 판단

1. **Task 1~4:** 원본을 보존하며 출처가 있는 안전한 HTML을 생성한다.
2. **Task 5~6:** 일상적으로 사용할 검색·열람·재생성·브라우저 실행을 완성한다.
3. **Task 7:** 실제 브라우저·성능·1분 목표·기존 회귀로 도입 가능 여부를 판단한다.

수동 재생성이 실제 작업에서 부담이 되거나 입력 상한·검색 성능이 사용 목적을 충족하지 못한다는 근거가 생기면 localhost 읽기 전용 뷰어를 별도 계획으로 검토한다. 이때 시작·종료, loopback 제한, 접근 보호, 임의 파일 공개 방지를 설계한다. HTML 버전에 앞서 서버 기능을 만들지는 않는다.

구현 전 사용자가 검토할 중심 사항은 (1) 단일 HTML과 세 가지 이용 흐름, (2) 원본 보존과 손상 시 명시 실패, (3) 수동 재생성과 선택적 `--open`, (4) 내장 배포로 현재 설치 방식을 유지하는 것, 네 가지이다.


## 13. 구현·검증 기록 (2026-10-30, Asia/Seoul)

아래는 구현 커밋 전 기록이다. 이후 `6c0eb86` (`feat: add offline local context viewer`)으로 커밋했으며, 해당 커밋에서 이어진 검증은 14절에 구분했다.

- 통합 코드: `ctx.sh`에 수집·Git·모델·HTML/CSS/JS·출력 보호를 내장했다. 실행 시 두 파일 복사 설치와 Python 표준 라이브러리만 필요하다. Node는 선택적 테스트 도구다.
- 시작 검사: `bash -n ctx.sh` 성공, 기존 unittest 188개 통과(89.601초).
- 최종 검사: `bash -n ctx.sh` 성공, `python3 -B -m unittest discover -s tests -v` **258개 통과(115.760초)**. 새 뷰어 테스트는 70개다. `git diff --check` 통과.
- 환경: macOS arm64, Bash 3.2.57, Python 3.11.8, Node 26.12.1. 내장 Python과 뷰어 테스트의 Python 3.7 AST 구문 검사 통과. Python 3.7 실제 실행, Linux, Windows는 미실시했다.
- 별도 명세 검토와 코드 품질 검토를 완료했다. 대량 경고 DOM, 수집 중 출력 변경, symlink 출력의 Git 혼입, 원문 숫자 반올림, fence 속 가짜 섹션, 반복 Markdown의 이차 지연, 깊은 인용의 call stack 초과를 재현 테스트 뒤 수정했다.
- 추가 수동 검증: 실제 Git 4자리 해시 충돌은 unavailable로 남김, copy의 NUL 추가 경로 보존, 보호 입력 hardlink 거부.

### 성능

입력은 개인정보가 없는 합성 로그다. 같은 제목/요약/파일 검색을 9회 반복했고 결과 DOM은 최대 50행이었다. 최종 Node 수치는 테스트용 DOM에서 실행한 실제 내장 JS의 동기 처리 시간이며, 화면 페인트 시간과 구분한다.

| 최종 합성 입력 | CLI 생성 | HTML 크기 | Node 검색 9회 범위 |
| --- | ---: | ---: | ---: |
| 5,000건 | 0.213초 | 4,605,326 bytes | 4.0~9.0ms |
| 20,000건 | 0.723초 | 18,320,329 bytes | 16.5~44.9ms |
| 빈 legacy 객체 20,000건 / 경고 40,000개 | 0.321초 | 11,077,111 bytes | 0.9~16.1ms |

경고 40,000개는 초기 DOM 0개, 펼쳤을 때 50개만 생성함을 확인했다. 20 MiB(설정 포함)·20,000건 정확 경계는 허용하고 초과는 실패하는 자동 테스트가 있다.

### 브라우저 검증 범위와 남은 확인

중간 구현을 Headless Chromium 145.0.7632.6에서 `file://`로 열어 개요·검색·50행 페이지·정확한 NFC/NFD 파일 필터·hash 복원·문서 내부 링크·pending 미확인 표시를 검증했다. 1280/768/390px 화면을 확인했고 390px 가로 overflow는 없었다. script/HTML/외부 이미지 공격 문자열을 문서와 로그에서 열어도 실행·이미지 생성·자동 HTTP 요청이 없었고 콘솔 오류도 없었다. 1차 UI 브라우저 검색은 5,000건 2.4~5.6ms, 20,000건 5.0~6.9ms였다.

이후 경고 페이지·파서 방어·원문 표시·skip link 수정은 실제 내장 JS의 Node 회귀로 검증했다. 최종 코드의 Chrome/Safari 재검증과 명시적 HTTPS 링크 클릭, Firefox 검증은 미실시다. 실제 사람의 Markdown 대비 1분 재개 평가는 수행하지 않았으므로 달성으로 선언하지 않는다.

컨텍스트가 초기화된 대상 프로젝트에서 다음 명령으로 뷰어를 생성하고 연다.

```bash
bash ctx.sh view --open
# scripts/ 설치 시
bash scripts/ctx.sh view --open
```

수동 후속 확인은 생성 파일을 Chrome/Safari에서 직접 열어 검색·키보드·HTTPS 링크를 확인하고, 처음 보는 컨텍스트의 현재 상태와 다음 행동을 1분 안에 파악할 수 있는지 측정하는 것이다.

## 14. 후속 호환성·사용성 검증 (2026-10-30, Asia/Seoul)

### 14.1 실제 실행 환경과 한계

이 절의 실행 결과는 초기 뷰어 커밋 `6c0eb86`을 기준으로 한다. 해당 후속 검증에서 구현 결함은 발견하지 않았으며 코드·테스트·CI 설정은 변경하지 않았다. 통합 검색·인수인계 추가 후 결과는 1절의 후속 구현 결과와 머지 후 CI를 참고한다.

| 실제 환경 | 실행한 검증 | 결과 |
| --- | --- | --- |
| macOS arm64 / Bash 3.2.57 / Python 3.9.6 | 뷰어 unittest 전체 | 70개 통과, 14.659초 |
| macOS arm64 / Bash 3.2.57 / Python 3.13.3 | 뷰어 unittest 전체 | 70개 통과, 12.763초 |
| Linux aarch64 / Bash 5.2.15 / Python 3.11.15 / Git 2.39.5 | 뷰어 unittest 전체 | 69개 통과, Node 미설치로 1개 건너뜀, 6.442초 |
| Linux aarch64 / Python 3.11.16 / Node 20.20.2 | 위에서 건너뛴 `test_browser_logic_search_filters_pages_and_hash` | 1개 통과, 0.292초 |
| Python 3.7 | 실행 환경 미확보 | 실제 실행 미실시. 13절의 AST 검사는 구문 호환 증거만 제공 |
| Windows | 실행 환경 미확보 | 미실시. 기존 launcher/CRLF 모의 테스트를 Windows 실행으로 간주하지 않음 |

macOS 검증은 CLI 자식 프로세스도 같은 Python을 선택하도록 `PATH`를 지정했다. Node 테스트는 화면을 그리지 않는 DOM 대역에서 내장 JS를 실행하므로 실제 브라우저·키보드·화면 페인트 검증을 대신하지 않는다. 기존 Python 3.11.8의 전체 회귀 258개 결과는 13절에 보존했고, 코드 변경이 없어 후속 세션에서 반복하지 않았다.

아래 명령은 실행한 checkout의 테스트를 대상으로 한다. 표의 70개 구성으로 재현하려면 별도로 준비한 `6c0eb86` checkout에서 실행한다. 현재 기준 `75dac4e`에서는 `test_view_context.py` 5개가 추가되어 뷰어 테스트 대상이 75개다. 각 Python 버전을 검사할 때는 해당 실행 파일이 `PATH`의 `python3`로 선택되는 환경을 준비해 CLI 자식 프로세스에도 같은 버전을 적용한다.

```bash
# 검증할 Python 환경과 checkout 루트에서 실행한다.
python3 --version
python3 -B -m unittest discover -s tests -p 'test_view*.py' -v
```

Linux 검증은 네트워크를 차단하고 소스·루트 파일시스템을 읽기 전용으로 둔 두 독립 환경에서 수행했다. Python 3.11.15 환경의 뷰어 테스트 70개 중 Node가 필요한 1개는 건너뛰었고, 해당 테스트만 Python 3.11.16·Node 20.20.2 환경에서 실행했다. 서로 다른 두 환경의 결과를 한 환경에서 전체 통과한 것으로 합산하지 않는다. 복사한 테스트 구성은 `6c0eb86` 기준이므로 현재 `main` 전체의 검증 결과로 해석하지 않는다.

### 14.2 합성 fixture 재현

전제 조건은 기존 Bash·Git·Python 3.7 이상과 이 저장소 checkout이다. 저장소 루트에서 아래 블록을 실행하면 시스템 임시 폴더 아래에 55건·5,000건·20,000건 프로젝트를 만든다. 사용자 컨텍스트를 읽거나 초기화하지 않으며 브라우저도 열지 않는다. JSONL은 활성/보관으로 나누고 동일 발생 2건·NFC/NFD 파일 경로·시간대 없는 legacy 1건·공격 문자열을 포함한다. 프로젝트가 Git 관리 밖인 것은 의도된 상태다.

이 예제는 초기 뷰어의 작업 기록 탐색·원본 보존·출력 크기를 확인하기 위한 입력이다. `MASTER_PLAN.md`에는 `현재 상태`와 `다음 행동`만 있으며, 현재 인수인계가 요구하는 `제약 조건`·`검증`·`미검증` H2는 없다. 따라서 현재 `main`에서 인수인계의 `incomplete` 표시는 정상이다. 기존 측정과 비교할 수 있도록 예제 입력은 유지한다. 필수 섹션을 갖춘 통합 검색·인수인계 검증에는 [최신 평가 fixture와 절차](../../../tests/fixtures/context-read/evaluation.md)를 사용한다.

```bash
python3 -B - <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unicodedata

repo = Path.cwd()
assert (repo / "ctx.sh").is_file(), "저장소 루트에서 실행하세요."
attack = json.loads((repo / "tests/fixtures/viewer/html/attacks.json").read_text(encoding="utf-8"))
root = Path(tempfile.mkdtemp(prefix="ctx-kit-view-manual-")).resolve()
for count in (55, 5000, 20000):
    project = root / str(count)
    context = project / "context"
    (context / "work-log").mkdir(parents=True)
    (context / "archive").mkdir()
    shutil.copy2(repo / "ctx.sh", project / "ctx.sh")
    config = project / "ctx.config.json"
    config.write_text(json.dumps({"source": "context/AGENT_RULES.md", "agent_rules": [],
                                 "git_sync": {"enabled": False}}), encoding="utf-8")
    plan = context / "MASTER_PLAN.md"
    plan.write_text("# 합성 재고 조회 도구\n\n## 현재 상태\n"
                    "캐시 조회 구현 완료. 네트워크 타임아웃 복구는 미검증.\n\n"
                    "## 다음 행동\n- [ ] 타임아웃 복구 테스트 작성\n"
                    "- [ ] 실패 시 캐시 안내 확인\n\n"
                    "[결정](decisions.md#재시도-결정) · [HTTPS 확인](https://example.com/)\n",
                    encoding="utf-8")
    decisions = context / "decisions.md"
    decisions.write_text("# 재시도 결정\n자동 재시도는 한 번으로 제한한다.\n\n" + attack["markdown"],
                         encoding="utf-8")
    nfc = "src/한글.kt"
    nfd = unicodedata.normalize("NFD", nfc)
    records = [{"id": "fixture-%d" % i, "title": "작업 %05d" % i,
                "summary": "합성 검색 needle", "createdAt": "2026-10-30T12:00:00+09:00",
                "type": "work" if i % 2 == 0 else "decision", "commit": "pending",
                "branch": "fixture", "dirty": False, "files": [nfc if i % 2 == 0 else nfd]}
               for i in range(count)]
    records[1].update(title=attack["title"], summary=attack["summary"])
    records[-2] = dict(records[0])  # 같은 행을 archive와 active에 각각 보존한다.
    records[-1] = {"id": "legacy", "title": "시각 없는 legacy", "type": "legacy",
                   "summary": "시간대 없는 원문", "createdAt": "2026-10-30T12:00:00", "files": []}
    paths = [context / "archive/timeline-2026-10.jsonl", context / "work-log/timeline.jsonl"]
    for path, items in zip(paths, (records[:count // 2], records[count // 2:])):
        path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in items), encoding="utf-8")
    inputs = [config, plan, decisions] + paths
    before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    input_bytes = sum(p.stat().st_size for p in inputs)
    assert input_bytes <= 20 * 1024 * 1024
    started = time.perf_counter()
    result = subprocess.run(["bash", str(project / "ctx.sh"), "view"], cwd=project,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, timeout=45)
    elapsed = time.perf_counter() - started
    assert result.returncode == 0, result.stdout + result.stderr
    assert before == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    output = context / "generated/view.html"
    print(json.dumps({"records": count, "input_bytes": input_bytes, "html_bytes": output.stat().st_size,
                      "generation_seconds": round(elapsed, 3), "html": str(output)}, ensure_ascii=False))
print("fixture_root=" + str(root))
PY
```

출력된 `fixture_root`와 각 HTML 경로를 보관한다. 아래 수동 확인에는 이 파일을 사용하며 로컬 서버를 띄우지 않는다. 생성 실패 시 stderr의 대상 경로를 확인하고, fixture 문제를 해결하려고 기존 사용자 컨텍스트를 수정하지 않는다. 재실행하면 별도의 임시 폴더를 만든다.

위 블록을 초기 뷰어 커밋 `6c0eb86`의 macOS/Python 3.11.8 환경에서 그대로 실행해 종료 0을 확인했다. 모든 크기에서 원본 SHA-256 보존, 모델 행 수, 활성/보관의 동일 발생 2건, NFC/NFD 경로 분리, 시각 미확인 1건, Git 관리 밖 상태를 확인했다. 아래는 당시 이 재현 fixture의 CLI 측정이며 13절과 입력 내용이 다르다. 브라우저 검색·화면 표시 시간은 측정하지 않았다.

| 기록 수 | 입력 bytes (설정 포함) | HTML bytes | 생성 시간 |
| --- | ---: | ---: | ---: |
| 55 | 13,565 | 85,765 | 0.118초 |
| 5,000 | 1,174,654 | 3,986,196 | 0.192초 |
| 20,000 | 4,709,652 | 15,856,199 | 0.449초 |

2026-11-01 문서 검토에서 `6c0eb86`과 `main`의 `75dac4e`로 같은 예제를 각각 재실행했다. 두 버전 모두 세 크기의 생성·입력 SHA-256 보존·모델 행 수·동일 발생 보존 검사가 통과했다. 초기 커밋의 입력 크기와 HTML 크기는 위 표와 일치했다. 현재 버전에는 통합 검색·인수인계 모델과 화면이 추가되어 HTML 크기가 달라지므로 위 표를 현재 버전의 크기·성능 보장으로 사용하지 않는다. 최신 코드의 별도 합성 성능 측정은 [후속 구현 결과](../reports/2026-11-01-search-handoff-implementation.md)를 참고한다.

### 14.3 사람이 수행할 Chrome/Safari 확인 (미실시)

다음은 **사람이 자신의 브라우저에서 수행할 절차**이며 아직 실행 결과가 기록되지 않았다. Chrome과 Safari 각각 결과·브라우저 버전·OS/기종·화면 폭·일시·실패 지점을 기록한다. Firefox는 사용 가능할 때만 같은 절차를 수행한다.

아래 체크리스트는 초기 뷰어의 작업 기록 탭과 문서 열람을 대상으로 한다. 현재 버전의 통합 검색·출처 이동·인수인계 복사 성공/권한 거부/API 없음 확인은 [최신 브라우저 평가 절차](../../../tests/fixtures/context-read/evaluation.md#실제-브라우저-확인-미실시)를 함께 따른다. 실제 브라우저·복사 권한·화면 그리기 검증을 Node DOM 대역의 통과로 대체하지 않는다.

- [ ] 55건 `view.html`을 브라우저의 ‘파일 열기’로 연다. 생성 시각, 현재 상태, 다음 행동, Git 관리 밖 표시를 확인한다. 1280/768/390px 폭에서 본문과 조작부가 가려지지 않고 가로 스크롤 없이 읽히는지 확인한다.
- [ ] 키보드만으로 Tab/Shift+Tab, 본문 이동, 탐색, 검색, 각 필터, 행 선택, 페이지 이동, 문서 선택을 조작한다. 포커스가 보이고 Enter/Space로 해당 버튼이 동작하며 상세와 다음 행동까지 도달하는지 확인한다. Safari에서 필요하면 ‘Tab 키로 웹 페이지의 각 항목 하이라이트’ 설정을 켜고 그 조건도 기록한다.
- [ ] 작업 기록은 55건, 첫 페이지 50건, 다음 페이지 5건이다. `작업 00010`은 1건, `작업 00000`은 archive/active 출처가 다른 2건으로 표시된다. 없는 검색어는 0건, 필터 해제는 55건으로 돌아온다.
- [ ] 한글 IME 조합 중에는 검색이 확정되지 않고 조합 완료 후 반영된다. `한글.kt`와 NFD `한글.kt`로 같은 54건을 찾되, 정확한 파일 필터의 NFC/NFD 두 항목은 각각 28건/26건으로 좁혀진다. 필터 해제 후 Asia/Seoul에서 2026-10-30 날짜를 선택하면 시각 미확인 legacy 1건이 제외되어 54건이 된다.
- [ ] 검색·선택 후 URL hash를 복사하고 같은 파일을 다시 열어 hash를 붙이면 상태가 복원된다. 계획 문서의 ‘결정’ 링크가 결정 문서 제목으로 이동하고, pending과 dirty=false가 현재 완료·깨끗한 작업 트리를 증명하는 것처럼 표시되지 않는지 확인한다.
- [ ] 개발자 도구 Network 기록을 시작하고 새로고침·검색·페이지 이동·모든 문서 열람과 `ctxAttack` 검색 결과의 상세 선택을 한다. HTML 자체의 `file://` 읽기 외에 뷰어에서 시작한 자동 HTTP(S) 요청이 없어야 한다. Console의 예상하지 못한 오류가 없고, `globalThis.ctxAttack`은 `undefined`, 공격 문자열은 텍스트, 외부 이미지는 미로딩, `javascript:`는 비링크인지 확인한다.
- [ ] 자동 요청 확인 후 계획 문서의 ‘HTTPS 확인’을 직접 눌러 `https://example.com/`이 새 탭으로 열리는지 확인한다. 사용자 클릭으로 발생한 요청은 자동 요청과 구분한다. 외부 통신이 불가능한 환경이면 클릭 확인을 미실시로 남긴다.
- [ ] 5,000건/20,000건 HTML도 열어 검색·페이지 이동이 가능하고 작업 목록 DOM 행이 최대 50개인지 확인한다. 작업 기록 탭에서 Console의 `document.querySelectorAll("#entry-list > *").length`로 센다. DevTools Performance에서 같은 검색어를 여러 번 입력해 입력 확정부터 화면 갱신까지 측정한다. 5,000건 생성 3초/검색 200ms 이내라는 잠정 목표를 평가하고 Node 동기 시간과 브라우저 그리기 시간을 혼동하지 않는다.

### 14.4 Markdown 대비 1분 재개 평가 (미실시)

fixture 내용을 아직 모르는 평가자가 파일을 연 순간부터 ‘현재 상태’, ‘다음 행동 2개’, ‘미검증 사항’, ‘근거 문서’를 설명할 때까지 잰다. 준비자는 위 합성 데이터의 답을 읽었으므로 처음 보는 평가자로 세지 않는다. 1분 이내여도 설명이 틀리면 미달성이다.

같은 55건 fixture의 `context/MASTER_PLAN.md`, `decisions.md`, 두 JSONL을 사용해 한 명은 HTML, 다른 한 명은 Markdown/JSONL을 처음 보는 조건으로 비교한다. 처음 보는 평가자가 한 명뿐이면 열람 순서를 추첨하고, 두 번째에는 학습 효과가 있음을 명시해 참고 비교로만 남긴다. 결과를 입력하기 전에는 ‘1분 달성’으로 기록하지 않는다.

| 익명 참여자 ID/처음 보는지 | 환경·브라우저 버전 | HTML 초/정답 여부 | Markdown 초/정답 여부 | 열람 순서·의견 |
| --- | --- | --- | --- | --- |
| 미실시 | — | — | — | — |

남은 미검증 항목은 Python 3.7 실행·Windows·최종 Chrome/Safari 조작/그리기/HTTPS·사람의 재개 평가다. 이들을 완료하기 전에는 Task 5/7의 해당 체크를 완료로 바꾸지 않는다.
