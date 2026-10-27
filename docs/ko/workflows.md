# 작업 흐름

[English](../en/workflows.md) · [README](../../README.ko.md) · [시작하기](getting-started.md) · [설정](configuration.md) · [문제 해결](troubleshooting.md)

초기화를 마친 뒤 사용하는 작업 흐름입니다. 예시는 프로젝트 루트의 `ctx.sh`와 `source: sample-context/AGENT_RULES.md`를 기준으로 합니다. `scripts/`에 설치했다면 `bash scripts/ctx.sh`를 사용하고, `source`를 바꿨다면 아래 컨텍스트 경로를 해당 파일의 상위 디렉터리로 바꾸세요.

## 작업 세션 시작하기

1. 설정된 링크와 프로젝트 요약을 확인합니다.

   ```bash
   bash ctx.sh status
   ```

2. 규칙에서 지정한 순서대로 현재 상태, 기존 결정, 선택적인 과거 기록 다이제스트, 백로그를 읽습니다.

   ```bash
   cat sample-context/MASTER_PLAN.md
   cat sample-context/decisions.md
   if [ -f sample-context/work-log/timeline-digest.md ]; then
     cat sample-context/work-log/timeline-digest.md
   fi
   cat sample-context/backlog.md
   ```

3. 에이전트에 구체적인 작업과 “검토만 수행”, “이 파일만 수정” 같은 제한을 전달합니다. 컨텍스트 로드 응답이 현재 상태와 관련 ADR을 반영하는지 확인합니다.

규칙 파일은 에이전트가 읽고 기록할 내용을 안내합니다. CLI가 에이전트의 행동을 강제하거나 모델의 기억을 자동으로 유지하지는 않습니다. 다이제스트는 관련 보관 로그를 처리한 뒤에만 생깁니다. 과거 세부 정보가 필요한 작업에서는 해당 보관 파일을 읽고, 매 세션 전체 보관함을 불러오지 않습니다.

## 허가된 변경 수행 후 작업 단위 마무리하기

허가된 작업 안에서 사실이 바뀌면 `MASTER_PLAN.md`의 관련 Current State와 Next Actions만 갱신합니다. 바뀐 사실이 없으면 그대로 둡니다. 이미 허가받지 않은 새 기술 결정, 범위·우선순위 변경, 백로그 추가는 먼저 사용자에게 확인합니다. 기존 ADR과 충돌하면 결정을 변경하기 전에 사용자와 충돌을 해결합니다.

문서 작업을 포함해 프로젝트 파일을 변경한 작업 단위가 끝나면 다음을 수행합니다.

1. 실제 diff를 검토하고 관련 검증을 실행합니다. 구현, 검증, 커밋, 병합 여부를 구분해서 설명합니다.
2. 허가된 컨텍스트 변경을 반영합니다.
3. 실제 변경, 검증 결과, 남은 문제, 관련 파일을 정확하게 기록합니다.

   ```bash
   bash ctx.sh log \
     --summary "설정 안내 수정; 링크 검증 통과; 남은 문제 없음" \
     --files "README.md,docs/en/getting-started.md" \
     --type docs
   bash ctx.sh timeline --limit 1 --json
   ```

4. `log`가 성공 종료했는지 확인하고, 다시 읽은 결과에 **자신의** 요약·파일·유형이 있는지 확인합니다. 다른 작성자가 더 최신 행을 추가했다면 조회 범위를 늘려 자신의 기록을 찾습니다.

   ```bash
   bash ctx.sh timeline --limit 20 --json
   ```

`timeline.jsonl` 파일이나 관계없는 행이 존재하는 것만으로는 이 작업의 기록 성공을 검증할 수 없습니다. 기록 또는 다시 읽기가 실패하면 실패·미검증 상태로 보고합니다. 행 저장 이후 다른 단계에서 실패할 수 있으므로 재시도 전에 기존 기록을 찾으세요. CLI를 우회하려고 JSONL을 직접 수정하지 않습니다. [저장 및 기록 오류 해결](troubleshooting.md)을 참고하세요.

읽기 전용 검토에는 컨텍스트 수정이나 작업 로그가 필요하지 않습니다. 명시적인 기록 금지와 수정 허용 파일 제한이 우선합니다. 허용 범위를 넓히지 말고 생략한 마무리 절차를 보고합니다.

### log 옵션

`record`는 `log`의 별칭입니다.

| 옵션 | 의미 |
| --- | --- |
| `--summary`, `-s` | 필수 작업 설명이며 비어 있으면 안 됩니다. 공백을 포함한 문장은 따옴표로 감쌉니다. |
| `--title`, `-t` | 선택 제목. 기본값은 요약 첫 줄의 최대 80자입니다. |
| `--files`, `-f` | `src/app.kt,README.md`처럼 쉼표로 구분한 경로. 작업과 실제로 관련된 파일을 지정합니다. |
| `--commit`, `-c` | 명시적인 커밋 참조. 기록한 작업을 정확하게 나타내는 경우에만 지정합니다. |
| `--type` | 분류 이름. 기본값은 `work`이며 `docs`, `release` 등을 사용할 수 있습니다. |

`--commit`이 없으면 Git이 변경을 감지할 때 `uncommitted`를 기록하고, 그렇지 않으면 가능한 경우 현재 짧은 커밋 해시를 사용합니다. `--files`가 없으면 해당 커밋이나 작업 트리에서 경로를 추출합니다. 이는 메타데이터 기본값이므로 관련 경로를 명시하면 기록을 더 정확하게 남길 수 있습니다. 로그 기록은 프로젝트 커밋을 만들지 않습니다.

## 최근 작업 찾기와 Git 이력 가져오기

```bash
bash ctx.sh timeline
bash ctx.sh timeline --limit 5 --json
bash ctx.sh timeline --commit abc123 --limit 20
```

`timeline`은 활성 `work-log/timeline.jsonl`에서 마지막에 저장된 행부터 읽습니다. 월별 보관 파일은 검색하지 않습니다.

| 옵션 | 의미 |
| --- | --- |
| `--limit`, `-n` | 표시할 행 수. 기본값 `20`. 양의 정수를 사용합니다. |
| `--commit`, `-c` | `commit` 또는 `fullCommit`의 접두사로 필터링합니다. |
| `--json` | 선택된 행을 JSON 배열로 출력합니다. 로그 파일이 없으면 대신 안내 메시지를 출력합니다. |

기존 프로젝트의 Git 이력을 활성 로그에 가져오려면 다음을 실행합니다.

```bash
bash ctx.sh backfill --limit 30
bash ctx.sh timeline --limit 5 --json
```

`backfill`은 Git의 커밋 메시지, 날짜, 파일명을 가져옵니다. 커밋하지 않은 작업이나 Git에 남기지 않은 검증 결과는 복원하지 못합니다.

| 옵션 | 의미 |
| --- | --- |
| `--limit`, `-n` | 확인할 최근 Git 커밋 수. 기본값 `30`. |
| `--all` | 제한 대신 전체 Git 이력을 확인합니다. 사용 전에 가져올 양을 고려합니다. |
| `--type` | 가져온 기록에 적용할 분류. 기본값 `work`. |

Git 커밋이 없으면 가져올 내용이 없다고 안내합니다. **활성** 로그에 이미 기록된 커밋은 건너뜁니다. 월별 보관함은 확인하지 않으므로 보관 후 다시 가져오면 해당 커밋이 중복으로 들어올 수 있습니다. 도입 상황에 맞는 제한을 선택하고 결과를 확인하세요.

## 활성 컨텍스트를 작게 유지하기

계획과 결정을 먼저 검토하고, 완료·폐기된 내용을 활성 컨텍스트에서 빼도 될 때 보관합니다.

```bash
bash ctx.sh archive --keep 30
bash ctx.sh timeline --limit 5 --json
```

| 옵션 | 의미 |
| --- | --- |
| `--keep`, `-k` | 활성 타임라인 끝에 남길 행 수. 기본값 `30`, 0 이상의 정수여야 합니다. `0`이면 모든 활성 행을 이동합니다. |
| `--no-tasks` | `MASTER_PLAN.md`의 완료 작업 줄을 그대로 둡니다. |
| `--no-logs` | 활성 타임라인 행을 그대로 둡니다. |
| `--no-decisions` | `decisions.md`의 ADR 구역을 그대로 둡니다. |

예를 들어 오래된 활성 로그만 보관하려면 다음을 실행합니다.

```bash
bash ctx.sh archive --keep 20 --no-tasks --no-decisions
```

기본 동작은 다음 내용을 이동합니다.

- `-` 또는 `*`와 `[x]` 또는 `[X]`로 시작하는 완료 체크박스 **줄**을 `archive/completed-tasks.md`로 이동합니다. 중첩된 작업 블록 전체나 주변 설명까지 이동하지는 않습니다. 실행 후 들여쓴 설명과 하위 작업을 검토하세요.
- 폐기된 ADR 구역을 `archive/decisions-deprecated.md`로 이동합니다. `## ADR-001 로컬 저장소 사용`처럼 인식 가능한 2~4단계 ADR 제목과 `Status: Deprecated` 또는 `상태: 폐기됨` 같은 상태 표기를 사용합니다. `Superseded`, `Obsolete`, `Cancelled`, `대체됨`도 인식하며 영어는 대소문자를 구분하지 않습니다. 파서는 구역 안의 텍스트에서 상태를 찾으므로 임의 제목이나 사용자 정의 상태 형식은 감지되지 않을 수 있습니다.
- 오래된 타임라인 행을 `archive/timeline-YYYY-MM.jsonl`로 이동합니다. 날짜 접두사를 인식하지 못한 행은 `timeline-legacy.jsonl`로 이동합니다. 기존 ID와 개별 레거시 행의 발생 횟수를 보존하며, 보관 과정에서 중복을 제거하지 않습니다.

월별 보관 로그가 있으면 `work-log/timeline-digest.md`를 생성합니다. 각 기록의 날짜, 제목, 해당하는 커밋 참조를 월별로 나열한 파일입니다. AI가 내용을 해석해 작성하는 요약이 아니라 일정한 규칙으로 만든 색인입니다. 다이제스트와 내보내기로 읽을 분량을 줄일 수 있지만 고정된 토큰 절감률은 보장하지 않습니다.

명령 실행 후 남아 있는 계획과 ADR, 관련 보관 파일, 다이제스트를 확인하세요. `--no-logs`를 사용해도 기존 월별 보관함에서 다이제스트를 다시 생성할 수 있습니다. 컨텍스트 디렉터리에 별도 Git 저장소가 있으면 `archive`는 로컬 스냅샷도 시도합니다. 보관 파일을 변경한 뒤 Git 사용자 정보나 커밋 오류가 발생할 수 있습니다.

### 중단된 쓰기와 동시 작업

CLI 저장 작업은 배타적인 `work-log/.ctx.lock`을 사용하며 최대 30초 기다립니다. 대상 파일을 바꾸기 전에 교체 파일을 준비합니다. 컨텍스트의 로컬 Git 스냅샷 작업도 같은 잠금을 사용합니다. 다른 도구의 임의 수동 편집까지 조율하지는 않습니다.

보관 작업은 내부 `work-log/.ctx-archive-transaction.json` 저널에 예정된 파일 교체를 기록합니다. 중단 후 다음 저장 작업이 남은 교체를 완료하려고 시도합니다. 대상 파일이 해당 트랜잭션 외부에서 바뀌었다면 덮어쓰지 않고 복구를 중단합니다. 저널과 파일을 보존하고 [문제 해결](troubleshooting.md)을 따르세요. 저널을 삭제하거나 `log`를 무작정 반복하지 않습니다. 읽기 전용인 `timeline`과 `export`는 이 복구를 수행하지 않습니다.

## 웹 LLM에 선택한 컨텍스트 공유하기

```bash
bash ctx.sh export
bash ctx.sh export --all
```

외부 서비스에 붙여넣기 전에 출력을 검토하세요. 기본 내보내기는 존재하는 `MASTER_PLAN.md`, `decisions.md`, `backlog.md`, 다이제스트, 최근 활성 타임라인 10개 행의 표시 내용을 포함합니다. `AGENT_RULES.md`와 생성한 소스 묶음은 포함하지 않습니다.

`--all`은 `archive/completed-tasks.md`와 `archive/decisions-deprecated.md`를 추가합니다. CLI 안내 문구가 더 넓은 범위를 암시하더라도 월별 `timeline-*.jsonl`은 포함하지 **않습니다**. 과거 로그가 필요하면 해당 보관 파일만 별도로 검토하고 공유하세요.

내보내기에는 터미널 안내와 ANSI 색상 이스케이프가 포함되며 `--plain` 옵션은 없습니다. 파일로 리다이렉트해도 해당 바이트가 남습니다. 또한 `timeline --json`으로 최근 로그를 따로 확인하세요. 내보내기는 타임라인 표시 오류를 숨긴 채 “Export complete.”를 출력할 수 있습니다.

## 검토한 소스 파일을 LLM용으로 모으기

나머지 설정을 유지하면서 `ctx.config.json`의 `generate.project` 구역을 수정합니다. 직접 검토한 파일의 명시적인 허용 목록으로 시작하세요.

```json
{
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/architecture.md"
      ]
    }
  }
}
```

두 파일이 모두 존재하는 상태에서 실행합니다.

```bash
bash ctx.sh generate project
```

터미널 출력에는 다음 내용이 포함됩니다. 여기서는 색상 형식을 생략했습니다.

```text
[ctx generate project]

  + README.md
  + docs/architecture.md

  ✓ 2 file(s) collected → sample-context/generated/project-raw.md
  Open and paste into your LLM.
```

공유 전에 `sample-context/generated/project-raw.md`를 열고 `## [README.md]`, `## [docs/architecture.md]` 구역과 내용을 확인합니다. 이 명령은 일치한 파일을 제목과 함께 이어 붙이며 내용을 요약하지 않습니다. 경로 기준은 프로젝트 루트이고 재귀 glob 패턴도 지원합니다. 패턴이 겹치면 같은 파일이 여러 번 들어갈 수 있습니다.

쓰기 전에 입력 패턴을 확정합니다. 출력과 그 심볼릭 링크·하드 링크 별칭은 제외하고 나머지 일치 파일을 수집합니다. 지정한 유형이나 출력 경로가 없으면 오류입니다. 남은 입력이 없으면 stderr에 오류를 출력하고 0이 아닌 종료 코드를 반환하며, 기존 출력을 변경하거나 새 출력을 만들지 않습니다.

수집 성공 시 출력을 원자적으로 교체하며 기존 파일 권한을 유지합니다. 교체 전에 오류가 발생하면 이 실행은 출력을 변경하지 않습니다. 교체 직전 출력의 변경을 감지해도 중단하지만, 다른 작성자의 동시 쓰기를 잠그지는 않습니다. 최종 출력이 끊어진 링크를 포함한 심볼릭 링크이거나 디렉터리·FIFO 등 일반 파일이 아닌 항목이면, 해당 항목과 연결 대상을 변경하지 않고 거부합니다. [문제 해결](troubleshooting.md#generate가-실패하거나-export가-불완전할-때)을 참고하세요.

수집 시 `.gitignore`를 필터로 사용하지 않으며 비밀값이나 바이너리를 검사하지 않습니다. 특히 정확한 경로를 넓은 glob으로 바꾸기 전에 패턴과 출력을 직접 검토하세요. 출력 제외는 다른 비공개 파일을 걸러내거나 겹치는 패턴의 중복을 제거하지 않습니다.

## 로컬 Git 스냅샷과 커밋 전 로그 사용하기

훅은 `.gitignore`, `ctx.config.json`, `.git/hooks/pre-commit`, 컨텍스트 디렉터리를 변경합니다. 이러한 로컬 변경을 원하는 경우에 사용하세요. 일반적인 프로젝트 `.git` 디렉터리와 사용 가능한 Git 작성자 정보가 필요합니다. 설치 전에 사용자 정보를 확인합니다.

```bash
git var GIT_AUTHOR_IDENT
bash ctx.sh hook install
bash ctx.sh hook status
```

사용자 정보 확인에 실패하면 먼저 평소 사용하는 프로젝트 또는 전역 Git 사용자 정보를 설정합니다. 프로젝트에만 설정한 사용자 정보는 독립적인 컨텍스트 저장소에 자동으로 적용되지 않습니다. [Git 사용자 정보 문제 해결](troubleshooting.md)을 참고하세요.

설치는 컨텍스트 디렉터리에 독립적인 Git 저장소를 초기화하고, 필요하면 컨텍스트 ignore 규칙을 추가하고, `git_sync.enabled`를 활성화하고, pre-commit wrapper를 설치합니다. `auto_log` 키가 없을 때만 기본값 `true`를 넣으며 기존 `false`는 유지합니다. `hook status`로 실제 설정을 확인하세요.

기존 훅은 내용, 권한, 심볼릭 링크를 보존하여 `.git/hooks/pre-commit.ctx-kit-original`에 보관합니다. wrapper는 실행 가능한 원본 훅을 같은 작업 디렉터리, 인자, 입력으로 먼저 실행합니다. 원본이 0이 아닌 코드로 종료하면 커밋을 막고 ctx-kit을 실행하지 않습니다. 정상 종료하면 ctx-kit을 이어서 실행합니다. 실행 권한이 없는 원본은 보관하되 실행하지 않습니다. 변경하지 않은 wrapper는 재설치해도 안전하며, 이전 인라인 연동을 재설치하면 알려진 ctx-kit 블록을 변환하고 나머지 훅 내용은 유지합니다.

`git_sync.enabled`와 `auto_log`가 모두 `true`이면 일반 프로젝트의 커밋 시도 시 커밋 **전**에 로그가 추가될 수 있습니다. 제목은 스테이징된 파일명을 사용하고 요약에는 스테이징 diff 통계가 들어갑니다. 두 커밋 필드는 `pending`이며, 나중에 실제 커밋 해시를 연결하거나 AI가 의미를 해석해 요약하지 않습니다. 뒤의 훅이나 커밋 자체가 실패해도 커밋 전 기록이 남을 수 있습니다. 검증 결과와 최종 결과는 명시적인 작업 단위 마무리 절차로 기록하세요.

설치된 훅은 컨텍스트 변경의 스냅샷도 별도의 로컬 Git 저장소에 남깁니다. 컨텍스트 Git 명령은 상속된 저장소 전용 Git 환경변수를 제거하여 컨텍스트 저장소 자체 인덱스를 사용합니다. 프로젝트 조회는 `git commit --only`를 포함해 해당 커밋의 활성 인덱스를 유지합니다. ctx-kit에는 원격 push 단계가 없지만 로컬 Git과 ignore 규칙이 비밀 유지를 보장하지는 않습니다. 이미 추적 중인 파일, 별도로 설정한 원격 저장소, 내보내기, 생성 묶음은 여전히 검토해야 합니다.

설치 도구는 `.git/hooks/pre-commit`을 직접 사용합니다. `.git`이 파일인 연결된 worktree와 사용자 정의 `core.hooksPath`는 자동 지원하지 않습니다. 자동 실행에 의존하기 전에 [훅 문제 해결](troubleshooting.md)을 확인하세요.

ctx-kit wrapper를 제거하고 Git 동기화를 비활성화하려면 다음을 실행합니다.

```bash
bash ctx.sh hook uninstall
bash ctx.sh hook status
```

제거하면 보관한 원본 훅의 내용, 권한, 심볼릭 링크를 그대로 복원하며, 원본이 없었다면 wrapper를 삭제합니다. 컨텍스트 이력, ignore 규칙, 독립적인 컨텍스트 저장소는 유지합니다. 설치와 제거 시 wrapper 수정, 백업 충돌, 필수 백업 누락이 감지되면 진행하지 않습니다. 해당 파일을 보존하고 표시된 오류를 확인한 뒤 재시도하세요.

## 기존 설치 업그레이드하기

사용자 정의 규칙을 포함해 기존 설정과 컨텍스트의 복구 가능한 사본을 확보합니다. 검토한 저장소 리비전에서 새 `ctx.sh`를 받아 기존 위치의 스크립트를 교체합니다. `ctx.config.json`과 `source`로 선택한 디렉터리는 보존합니다.

해당 리비전 루트의 `AGENT_RULES.md`와 현재 설정된 원본 파일을 비교해 필요한 절차 변경만 사용자 정의 규칙에 병합합니다. `sample-context/` 참조를 실제 설정 디렉터리에 맞추고, 해당하면 `bash ctx.sh` 예시를 `bash scripts/ctx.sh`로 바꾸세요. `init` 재실행은 기존 컨텍스트 파일을 보존하며 사용자 정의 내용을 업그레이드하지 않습니다.

결과를 확인합니다.

```bash
bash ctx.sh version
bash ctx.sh sync
bash ctx.sh status
bash ctx.sh timeline --limit 5 --json
bash ctx.sh hook status
```

기존 에이전트 지침을 덮어쓰지 말고 링크 충돌을 해결하세요. [설정](configuration.md)과 [문제 해결](troubleshooting.md)을 참고하세요. 활성화한 기능에 맞는 검증만 실행한 뒤, 허용된 경우 일반적인 마무리 절차로 업그레이드와 검증 결과를 기록합니다.
