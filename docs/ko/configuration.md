# 설정 참조

[English](../en/configuration.md) · [README](../../README.ko.md) · [시작하기](getting-started.md) · [작업 흐름](workflows.md) · [문제 해결](troubleshooting.md)

`ctx.config.json`에서 공유 규칙 파일, 에이전트 규칙 경로, 소스 번들 대상을 설정합니다. 이 문서는 배포 설정과 CLI의 동작을 설명합니다. 등록된 파일을 에이전트가 실제로 읽는지 검증하는 문서는 아닙니다.

## 전제 조건과 경로 규칙

- [시작하기](getting-started.md)에 따라 `ctx.sh`와 `ctx.config.json`을 설치합니다. Bash와 Python 3.7 이상이 필요하며, Git 연동에는 Git이 필요합니다. CLI는 `PATH`의 `python3`, `python`, `py -3` 순으로 검증하여 실제 실행과 최소 버전 검사를 통과한 첫 후보를 사용합니다. 유지보수 중인 Python 3 버전을 권장합니다.
- `ctx.config.json`은 프로젝트 루트에 둡니다. 스크립트는 `ctx.sh` 또는 `scripts/ctx.sh`에 둡니다. 스크립트가 `scripts`라는 디렉터리에 있으면 그 상위 디렉터리를 프로젝트 루트로 사용하고, 그 외에는 스크립트가 있는 디렉터리를 루트로 사용합니다.
- 예제 명령어는 프로젝트 루트에서 실행합니다. `scripts/ctx.sh`로 설치했다면 `bash ctx.sh`를 `bash scripts/ctx.sh`로 바꿉니다.
- JSON에는 주석이나 마지막 항목 뒤의 쉼표를 넣지 않습니다. 따옴표로 감싼 문자열 대신 JSON 불리언(`true`, `false`)을 사용합니다.
- `source`, 에이전트 `path`, `output`, `collect`에는 프로젝트 상대 경로를 사용합니다. 이 경로들과 프로젝트·Python 실행 파일 경로에는 공백, 한글 등 유니코드, 작은따옴표를 사용할 수 있습니다. 절대 경로, `..`, 심볼릭 링크인 상위 디렉터리는 피합니다. 이 설정들은 경로를 지정하며, 접근 범위를 격리하는 샌드박스는 아닙니다.
- 컨텍스트 문서는 일반 UTF-8 Markdown(`.md`)으로 유지합니다. 설정한 소스와 에이전트 대상은 서로 다른 파일시스템 항목이어야 합니다.

셸 경로는 자리표시자를 실제 경로로 바꾼 `bash "/path/to/팀's project/ctx.sh" status`처럼 큰따옴표로 감싸세요. JSON의 `"source": "팀's context/AGENT_RULES.md"` 같은 필드에서는 작은따옴표를 이스케이프할 필요가 없습니다. `generate.<type>.output`의 앞부분도 컨텍스트 위치에 맞추세요. 독립적인 Python 예제는 `python3`를 사용하므로 필요하면 유효한 `python`이나 `py -3` 후보로 바꾸세요.

## 전체 예제

다음 예제는 배포 설정의 컨텍스트 위치를 사용하고, 선택적인 Git 동작을 끄며, 명시적으로 허용한 문서만 수집합니다. `collect`에는 내용을 검토했고 공유하려는 파일을 지정해야 합니다.

```json
{
  "_comment": "Shared agent rules and reviewed source bundles",
  "_usage": "bash ctx.sh help",
  "source": "sample-context/AGENT_RULES.md",
  "git_sync": {
    "enabled": false,
    "auto_log": false
  },
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/en/getting-started.md",
        "docs/en/configuration.md"
      ]
    }
  },
  "agent_rules": [
    {
      "name": "Claude",
      "path": "CLAUDE.md",
      "enabled": true,
      "_note": "Claude Code"
    },
    {
      "name": "Codex",
      "path": "AGENTS.md",
      "enabled": true,
      "_note": "OpenAI Codex"
    },
    {
      "name": "Antigravity",
      "path": "AGENTS.md",
      "enabled": true,
      "_note": "Shares this target with Codex"
    },
    {
      "name": "Cursor",
      "path": ".cursor/rules/context.mdc",
      "enabled": true,
      "_note": "Check rule activation in Cursor"
    }
  ]
}
```

항목을 활성화하기 전에 대상 파일이 이미 있는지 확인합니다. 예를 들어 프로젝트에 `AGENTS.md`나 `CLAUDE.md`가 이미 있을 수 있습니다. 기존 지침을 보존하고 통합한 뒤 링크를 만들어야 합니다. [문제 해결](troubleshooting.md)을 참고하세요.

## 필드와 기본값

배포된 `ctx.config.json`과 단독 설치 시 `init`의 내장 설정은 아래 기본값을 사용합니다. 배포 기본값이 곧 필드 생략 시의 대체값은 아닙니다. 여러 필드는 직접 읽으며, 설정 전체를 검사하는 스키마 검증기는 없습니다.

| 필드 | 타입 | 배포 값 또는 필드 생략 시 동작 | 효과 |
| --- | --- | --- | --- |
| `source` | 문자열 | 배포 값: `sample-context/AGENT_RULES.md`. 생략하지 않습니다. | `sync`가 사용하는 공유 규칙 파일입니다. 상위 디렉터리는 `init`, `status`, `export`, `log`, `timeline`, `backfill`, `archive`, hook 작업이 사용하는 컨텍스트 디렉터리이기도 합니다. |
| `git_sync` | 객체 | 배포 설정은 `enabled: true`, `auto_log: true`입니다. 객체가 없으면 hook 상태 조회·실행 시 `{}`로 읽습니다. | 선택적으로 설치하는 관리형 Git hook의 설정입니다. JSON 값만 바꿔서는 hook이 설치되지 않습니다. |
| `git_sync.enabled` | 불리언 | 배포 값: `true`. 실행 시 필드가 없으면 `false`. | 설치된 hook이 컨텍스트 자동 로그·로컬 커밋을 실행하도록 허용합니다. `false`이면 해당 작업 없이 hook 호출을 종료합니다. |
| `git_sync.auto_log` | 불리언 | 배포 값: `true`. 실행 시 필드가 없으면 `false`. | 설치된 hook이 `enabled: true`로 실행될 때 메인 커밋 전에 스테이징된 파일 정보와 diff 통계를 기록합니다. LLM 호출이나 코드 의미 요약은 하지 않습니다. |
| `generate` | 객체 | 배포 설정에 `project` 타입이 있습니다. 섹션이 없으면 `generate`가 실패합니다. | 타입 이름과 번들 정의를 연결합니다. 이름은 `generate <type>`에 전달하는 정확한 값이며 대소문자를 구분합니다. |
| `generate.<type>.output` | 문자열 | 배포 `project` 값: `sample-context/generated/project-raw.md`. 값이 없거나 비어 있으면 `generate`가 실패합니다. | 수집 성공 후 교체하는 파일이며 기존 권한을 유지합니다. 필요한 상위 디렉터리는 생성합니다. `source`를 바꿔도 이 경로는 바뀌지 않습니다. 출력이 심볼릭 링크이거나 일반 파일이 아니면 거부합니다. |
| `generate.<type>.collect` | 문자열 배열 | 배포 `project` 값: README, `docs` 아래 Markdown, `src` 아래 파일. 필드가 없으면 빈 배열로 처리합니다. | 프로젝트 상대 파일 경로나 Python glob 패턴입니다. 각 패턴 안에서 일치한 경로를 정렬하고, 패턴 순서대로 이어 붙입니다. 일치하지 않는 항목과 출력 파일의 별칭은 건너뜁니다. 남은 입력이 없으면 실패하며 기존 출력을 보존합니다. |
| `agent_rules` | 객체 배열 | 배포 설정에 아래 네 항목이 있습니다. 빈 배열을 쓰더라도 필드는 유지합니다. | `list`, `sync`, `status`, `enable`, `disable`이 읽는 등록 목록입니다. |
| `agent_rules[].name` | 문자열 | 항목별 필수 값이며 대체값이 없습니다. | 표시 이름이자 `enable`/`disable`이 대소문자 구분 없이 찾는 이름입니다. 이름은 서로 다르게 지정합니다. 일치하는 항목은 모두 변경됩니다. |
| `agent_rules[].path` | 문자열 | 항목별 필수 값이며 대체값이 없습니다. | `source`를 가리킬 심볼릭 링크의 프로젝트 상대 경로입니다. 여러 항목이 같은 경로를 공유할 수 있습니다. 소스 자체를 지정하면 안 됩니다. |
| `agent_rules[].enabled` | 불리언 | 배포 값: 모든 항목이 `true`. 항목별 필수 값이며 대체값이 없습니다. | `true`이면 관리 링크를 요청합니다. `false`이면 같은 경로를 사용하는 활성 항목이 없을 때 현재 소스를 가리키는 링크를 제거할 수 있습니다. |
| `agent_rules[]._note` | 문자열 | 선택 사항. | JSON 편집자를 위한 설명이며 CLI는 무시합니다. |
| `_comment`, `_usage` | 문자열 | 선택 사항. | 설명용 메타데이터이며 CLI는 무시합니다. `_usage`를 바꿔도 명령어 실행 방식은 바뀌지 않습니다. |

에이전트 등록 기본값은 다음과 같습니다.

| 이름 | 경로 | 활성화 |
| --- | --- | --- |
| Claude | `CLAUDE.md` | `true` |
| Codex | `AGENTS.md` | `true` |
| Antigravity | `AGENTS.md` | `true` |
| Cursor | `.cursor/rules/context.mdc` | `true` |

이 표는 제공되는 등록 목록을 설명합니다. 공유 소스는 일반 Markdown입니다. 특히 `init`은 Cursor MDC frontmatter나 활성화 설정을 추가하지 않습니다. Cursor는 MDC Project Rules와 일반 `AGENTS.md` 지침을 별도 형식으로 설명합니다. [공식 Cursor 규칙 문서](https://prod.cursor.com/docs/rules)에 따라 경로와 활성화 방식을 선택하세요. 등록을 사용하기 전에 각 에이전트의 로딩 조건을 확인하세요. [시작하기](getting-started.md)를 참고하세요.

## 컨텍스트 디렉터리 변경

첫 `init` 전에 위치를 선택합니다. 예를 들어 다음 전체 설정은 컨텍스트를 `.ctx-local/` 아래에 두고 `CLAUDE.md` 대상만 활성화합니다.

```json
{
  "source": ".ctx-local/AGENT_RULES.md",
  "git_sync": {
    "enabled": false,
    "auto_log": false
  },
  "generate": {
    "project": {
      "output": ".ctx-local/generated/project-raw.md",
      "collect": [
        "README.md"
      ]
    }
  },
  "agent_rules": [
    {
      "name": "Claude",
      "path": "CLAUDE.md",
      "enabled": true
    }
  ]
}
```

선택적인 연동을 명시적으로 끈 뒤 초기화합니다.

```bash
bash ctx.sh init --no-hook --no-backfill
```

파일명은 `AGENT_RULES.md`로 유지합니다. `init`은 `source`에서 얻은 디렉터리 안에 이 고정 파일명을 생성하며, 임의의 다른 소스 파일명을 생성하지 않습니다. 새 템플릿의 참조 경로에는 설정한 컨텍스트 디렉터리와 실제 스크립트 위치를 반영합니다. 기존 컨텍스트 파일은 내용을 업그레이드하지 않고 보존합니다.

`source`를 바꿔도 컨텍스트 파일 이동, 기존 링크 이전, `generate.<type>.output` 재작성은 하지 않습니다. 이전 소스를 가리키는 기존 링크는 새 설정에서 충돌이 될 수 있습니다. 이 값을 바꾸기 전에 기존 설치를 백업하고 통합하세요. [문제 해결](troubleshooting.md)을 참고하세요.

## 에이전트 등록과 링크 동작

`agent_rules`에 항목을 추가한 뒤 `sync`를 실행합니다. 표시 이름은 서로 다르게 지정하며, 대상은 해당 도구가 실제로 읽는 파일 경로여야 합니다. CLI가 설치된 에이전트를 자동으로 찾지는 않습니다.

```bash
bash ctx.sh list
bash ctx.sh disable cursor
bash ctx.sh enable Cursor
bash ctx.sh sync
bash ctx.sh status
```

`enable`과 `disable`은 JSON을 수정한 직후 `sync`를 실행합니다. 이름은 대소문자를 구분하지 않습니다. 동기화가 실패하면 설정도 확인하세요. `enabled` 값은 이미 기록된 상태입니다.

`sync`는 다음 규칙을 적용합니다.

- 소스 파일이 있어야 합니다. 활성 대상에 소스 자체를 지정하면 안 됩니다.
- 링크나 계획의 `Last Updated` 필드를 바꾸기 전에 모든 활성 대상의 충돌을 확인합니다. 일반 파일, 디렉터리, 설정된 소스로 연결되지 않는 심볼릭 링크가 있으면 실패하며 기존 항목을 보존합니다.
- 없는 활성 링크는 상대 경로로 생성합니다. 소스로 연결되는 기존 심볼릭 링크는 허용하고 그대로 둡니다. `sync`는 링크의 경로 문자열을 교체하거나 문서 내용을 업그레이드하지 않습니다.
- 여러 항목이 같은 경로를 쓰면 하나라도 활성화된 동안 링크를 유지합니다. 기본 설정에서는 Codex만 비활성화해도 Antigravity를 위해 `AGENTS.md`를 유지합니다.
- 같은 경로의 모든 항목이 비활성화되면 현재 소스로 연결되는 심볼릭 링크를 제거합니다. 단, 소스 자체나 활성 규칙 링크의 연결 과정에 필요한 링크는 보존합니다. 비활성 대상의 일반 파일, 관련 없는 링크, 깨진 비관리 링크도 보존합니다.
- 충돌 검사를 통과하면 컨텍스트의 `MASTER_PLAN.md`에 `> Last Updated:` 줄이 있을 때 날짜를 갱신합니다.

`force`, `import`, `doctor` 명령어는 없습니다. 기존 지침을 검토하고 백업한 뒤 충돌하지 않는 대상을 선택하거나 파일을 의도적으로 통합해야 합니다. 구체적인 절차는 [문제 해결](troubleshooting.md)을 따르세요.

## 소스 번들 수집

설정한 타입은 다음과 같이 실행합니다.

```bash
bash ctx.sh generate project
```

`generate`는 선택한 파일에 제목을 붙여 이어 붙입니다. 완성된 명세서를 만들거나 LLM을 실행하거나 토큰 예산을 강제하지 않습니다. 모델이나 서비스에 공유하기 전에 결과물을 검토하세요.

명령어는 쓰기 전에 모든 입력 패턴을 확정합니다. 출력 파일 자체와 같은 실제 경로로 이어지거나 inode를 공유하는 경로는 심볼릭 링크·하드 링크 별칭까지 제외하고, 나머지 일치 파일은 수집합니다. 남은 입력이 없으면 stderr에 오류를 출력하고 0이 아닌 종료 코드를 반환합니다. 기존 출력은 보존하며, 출력 파일이 없었다면 새로 만들지 않습니다.

최종 출력 경로는 없거나 일반 파일이어야 합니다. 끊어진 링크를 포함한 심볼릭 링크, 디렉터리, FIFO 등 일반 파일이 아닌 항목은 해당 항목과 연결 대상을 변경하지 않고 거부합니다. 출력과 같은 디렉터리의 임시 파일에 전체 번들을 작성하고 flush·동기화를 마친 다음 출력을 원자적으로 교체합니다. 기존 파일 권한은 유지합니다. 교체 전에 읽기·쓰기·교체 오류가 발생하면 0이 아닌 종료 코드를 반환하며, 이 실행은 출력을 변경하지 않고 자체 임시 파일을 정리합니다. 교체 직전에 출력의 변경을 감지해도 중단하지만, 다른 작성자의 동시 쓰기를 잠그지는 않습니다.

`collect`는 명시적인 허용 목록으로 관리합니다. Glob 확장은 보안 필터가 아닙니다. `.gitignore`를 참조하지 않고, 비밀값 제거, 바이너리 판별, 출력과 무관한 입력 심볼릭 링크 거부, 겹치는 패턴의 중복 제거를 하지 않습니다. `README.md`나 구체적인 문서 경로처럼 검토한 텍스트 파일을 우선합니다. 프로젝트 전체의 광범위한 재귀 수집, 인증 정보, 환경 파일, 로컬 컨텍스트 이력, 빌드 결과물, 의존성 디렉터리는 피합니다. 생성 파일은 다시 만들 수 있도록 관리하고 직접 작성한 문서와 분리합니다.

## 선택적인 Git 설정

복사한 배포 설정의 두 Git 값은 모두 `true`이지만, 커밋 직전 동작에 영향을 주려면 관리형 hook도 설치되어 있어야 합니다. 수동 설정에서는 두 값을 `false`로 유지하고 `--no-hook --no-backfill`로 초기화합니다.

`hook install`은 `git_sync.enabled`를 `true`로 설정합니다. `auto_log`는 필드가 없을 때만 `true`로 설정하므로 명시적인 `false`는 유지합니다. 또한 hook 설치, 필요한 경우 컨텍스트 Git 제외 설정, 별도 로컬 컨텍스트 저장소 초기화를 수행합니다. 사용을 선택하기 전에 [작업 흐름](workflows.md)을 확인하세요. `hook uninstall`은 보관한 원본 훅을 복원하고, 원본이 없었다면 관리형 wrapper를 제거한 뒤 `enabled`를 `false`로 설정합니다. 로컬 컨텍스트 저장소나 제외 규칙은 제거하지 않습니다. wrapper 수정, 백업 충돌, 필수 백업 누락이 감지되면 훅 파일을 덮어쓰지 않고 오류를 반환합니다.

## 설정 검증과 반영

설정을 반영하기 전에 JSON 문법을 검사합니다.

```bash
python3 -m json.tool ctx.config.json > /dev/null
bash ctx.sh list
bash ctx.sh sync
bash ctx.sh status
```

`json.tool`은 JSON 문법을 검사하며 ctx 필드 타입, 경로 안전성, 에이전트 호환성을 검사하지 않습니다. `list`는 설정된 활성화 값을 보여줍니다. `status`는 소스 존재 여부와 링크 상태를 보여주지만, 연결 표시가 설정된 소스로 연결되는지 또는 에이전트가 읽었는지 검증하지는 않습니다. 활성 대상의 충돌 검사는 `sync`로 수행하고, 불일치 조사 시 실제 링크 대상을 확인합니다.

규칙이나 등록을 바꾼 뒤에는 새 에이전트 세션을 시작하거나 해당 에이전트가 지원하는 새로고침·다시 읽기 방법을 사용하세요. 디스크의 파일이 바뀌어도 이미 실행 중인 세션이 지침을 갱신했다는 뜻은 아닙니다. 일상 사용은 [작업 흐름](workflows.md), 충돌이나 컨텍스트 누락은 [문제 해결](troubleshooting.md)을 참고하세요.
