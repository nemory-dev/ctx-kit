# ctx-kit

AI 코딩 에이전트가 바뀌어도 프로젝트의 결정, 진행 상황, 다음 행동을 이어가는 로컬 CLI.

[English](README.md) · [시작하기](docs/ko/getting-started.md) · [설정](docs/ko/configuration.md) · [사용 흐름](docs/ko/workflows.md) · [문제 해결](docs/ko/troubleshooting.md) · [기여하기](CONTRIBUTING.ko.md)

ctx-kit은 Bash와 Python 표준 라이브러리로 동작합니다. 편집 가능한 프로젝트 컨텍스트를 만들고, 에이전트의 지침 파일 경로를 하나의 규칙 파일에 연결하며, 작업 단위를 로컬 JSONL 타임라인에 기록합니다. LLM API를 호출하지 않으며 API 키나 서버가 필요하지 않습니다.

새 세션에서 **어떤 결정을 했고, 무엇이 바뀌었으며, 무엇을 검증했고, 다음에 무엇을 해야 하는지** 이어가고 싶을 때 사용합니다. 도구 사이에 파일을 공유하는 방식이며, 에이전트가 그 내용을 읽고 따라야 합니다.

## 빠른 시작

Bash, Python 3.7 이상, 기본 Unix 도구가 필요합니다. 저장소 복제와 Git 연동에는 Git이 필요합니다. CI는 Linux와 macOS에서 Python 3.11로 실행하며, macOS 검증에는 Apple Silicon과 Bash 3.2가 포함됩니다. Windows에서는 Git Bash, Python, 심볼릭 링크 생성 권한이 필요합니다. [Windows 설치](docs/ko/getting-started.md#windows)를 참고하세요.

CLI는 `PATH`에서 `python3`, `python`, `py -3` 순으로 실제 실행하여 Python 3.7 이상인 첫 후보를 사용합니다. 유지보수 중인 Python 3 버전을 권장합니다. 적합한 후보가 없으면 원인을 알리고 실패하며, `init`은 설정이나 컨텍스트 파일을 생성하기 전에 검사합니다. `help`와 `version`은 Python 없이 사용할 수 있습니다. 탐색에 실패하면 [Python 진단](docs/ko/troubleshooting.md#python-git-스크립트를-찾지-못할-때)을 참고하세요.

먼저 **새 데모 디렉터리**에서 확인하세요. `ctx-kit`과 `ctx-demo`가 없는 디렉터리에서 실행합니다.

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
mkdir ctx-demo
cp ctx-kit/ctx.sh ctx-kit/ctx.config.json ctx-demo/
cd ctx-demo
bash ctx.sh init --no-hook --no-backfill
bash ctx.sh status
```

`sample-context/`와 설정된 규칙 링크가 생성됩니다. 두 옵션은 Git 훅 설치와 과거 이력 가져오기를 건너뜁니다. 기존 프로젝트에 적용할 때는 설정과 규칙을 보존하는 [기존 프로젝트 설치 절차](docs/ko/getting-started.md#existing-projects)를 먼저 확인하세요.

설정 작업을 기록하고 다시 조회합니다.

```bash
bash ctx.sh log --summary "Initialized ctx-kit demo; checked rule links" --files "sample-context/AGENT_RULES.md,sample-context/MASTER_PLAN.md"
bash ctx.sh timeline --limit 1 --json
```

반환된 항목에서 같은 요약과 파일 경로를 확인할 수 있습니다. 에이전트와 사용하기 전에 생성된 파일의 프로젝트명, 기술 스택, 현재 상태, 다음 행동을 실제 내용으로 바꾸세요.

## 컨텍스트 구성

```text
project/
├── ctx.sh
├── ctx.config.json
├── CLAUDE.md ─────────────────┐
├── AGENTS.md ─────────────────┼──> sample-context/AGENT_RULES.md
├── .cursor/rules/context.mdc ─┘
└── sample-context/
    ├── MASTER_PLAN.md              현재 상태와 다음 행동
    ├── decisions.md                기술 결정과 이유
    ├── backlog.md                  아이디어와 열린 질문
    ├── work-log/timeline.jsonl      log/backfill/훅이 만드는 작업 기록
    ├── work-log/timeline-digest.md  archive가 만드는 과거 작업 제목 목록
    └── archive/                    완료 작업, 폐기된 결정, 월별 로그
```

컨텍스트 디렉터리는 `ctx.config.json`의 `source`로 정합니다. 계획과 결정 파일은 사용자 또는 권한을 받은 에이전트가 편집합니다. `sync`는 링크를 관리하고 계획의 날짜를 갱신하며, 진행 상황을 추론하거나 사용자 규칙 내용을 업그레이드하지 않습니다.

기본 규칙은 세션 시작 시 현재 컨텍스트를 읽고, 승인된 변경 후 관련 상태를 갱신하며, 종료 시 `log` 기록을 확인하도록 안내합니다. CLI가 이 행동을 자동으로 강제하는 것은 아닙니다. 전체 절차와 Git 훅이 실제로 기록하는 내용은 [사용 흐름](docs/ko/workflows.md)에 설명되어 있습니다.

## 저장과 공유

- **기존 규칙을 보존합니다.** `init`/`sync`는 일반 파일이나 관련 없는 링크와 충돌하면 오류를 알립니다. 기존 지침을 자동으로 병합하지는 않습니다. [충돌 해결](docs/ko/troubleshooting.md)을 참고하세요.
- **로컬 저장과 비공개 설정은 구분해야 합니다.** `--no-hook`은 자동 Git 제외 설정도 건너뜁니다. 훅 설치는 컨텍스트 제외 규칙을 추가하거나 기존 규칙을 인식하지만, 이미 추적 중인 파일은 계속 추적됩니다. 커밋 전에 [로컬 Git 제외](docs/ko/getting-started.md#local-git-exclusions)를 확인하세요. 생성된 링크가 공유되면 팀원에게 없는 개인 디렉터리를 가리킬 수도 있습니다.
- **공유 전 결과를 검토하세요.** `generate`는 `.gitignore`를 적용하거나 비밀정보를 검사하지 않습니다. `export --all`은 보관된 작업·결정 Markdown과 월별 타임라인 JSONL의 전체 레코드를 추가하므로 비공개 상세와 출력 분량을 확인하세요. 고정된 토큰 절감률을 보장하지 않습니다. [내보내기와 수집](docs/ko/workflows.md)을 참고하세요.

작업 로그는 공통 잠금과 파일의 원자적 교체를 사용합니다. archive는 원본 내용을 제거하기 전에 복구 파일에 저장 계획을 기록합니다. 중단된 작업은 다음 컨텍스트 쓰기 전에 복구하고, 예상하지 못한 외부 수정이 있으면 덮어쓰는 대신 오류를 알립니다. [복구 안내](docs/ko/troubleshooting.md)에서 파일 보존과 확인 절차를 설명합니다.

## 명령어

프로젝트 루트에서 실행합니다. `scripts/`에 설치했다면 `bash scripts/ctx.sh`로 바꿉니다.

| 명령어 | 용도 |
| --- | --- |
| `bash ctx.sh init --no-hook --no-backfill` | 없는 컨텍스트 템플릿과 규칙 링크 생성 |
| `bash ctx.sh status` | 계획 요약과 링크 상태 표시 |
| `bash ctx.sh sync` | 충돌 검사, 링크 관리, 계획 날짜 갱신 |
| `bash ctx.sh list` | 설정된 에이전트 목록 조회 |
| `bash ctx.sh enable Cursor` / `disable Cursor` | 에이전트 활성화 설정 변경 후 sync 실행 |
| `bash ctx.sh log --summary "..."` | 작업 단위 기록. `record`도 같은 명령 |
| `bash ctx.sh timeline --limit 20` | 현재 타임라인 조회 |
| `bash ctx.sh backfill --limit 30` | 최근 Git 커밋을 현재 타임라인으로 가져오기 |
| `bash ctx.sh archive --keep 30` | 완료 작업, 폐기된 결정, 오래된 로그 보관 |
| `bash ctx.sh export` | 검토 후 수동 공유할 컨텍스트 출력 |
| `bash ctx.sh generate project` | `generate.project.collect`로 지정한 파일 결합 |
| `bash ctx.sh hook install` | 커밋 전 자동 로그와 로컬 컨텍스트 스냅샷 사용 |
| `bash ctx.sh hook status` / `hook uninstall` | ctx-kit 훅 연동 조회 또는 해제 |
| `bash ctx.sh version` / `help` | 스크립트 버전 또는 명령 개요 출력 |

옵션, 검증 명령, 제한 사항은 [사용 흐름](docs/ko/workflows.md)을 참고하세요. `status`는 CI 상태 검사 도구가 아닌 표시 명령입니다. 출력과 실제 링크 대상을 함께 확인하세요.

## 에이전트 지침 파일

기본 설정은 아래 경로를 활성화합니다. 링크가 만들어졌다는 사실만으로 에이전트가 지침을 읽거나 따랐다고 판단할 수는 없습니다.

| 에이전트 | 설정 경로 | 로딩 시 확인할 점 |
| --- | --- | --- |
| Claude Code | `CLAUDE.md` | 호환성을 위해 유지합니다. 최신 버전은 문서의 조건에 따라 `AGENTS.md`도 지원합니다. [공식 문서](https://code.claude.com/docs/en/memory) |
| Codex | `AGENTS.md` | 시작 시 지침을 구성합니다. 변경한 지침을 적용하려면 새 세션을 시작하세요. [공식 문서](https://learn.chatgpt.com/docs/agent-configuration/agents-md) |
| Antigravity | `AGENTS.md` | Codex와 설정 경로를 공유합니다. [공식 문서](https://antigravity.google/docs/rules) |
| Cursor | `.cursor/rules/context.mdc` | 기본 템플릿에는 MDC 활성화 메타데이터가 없습니다. 생성된 `AGENTS.md`도 지원하므로 MDC가 항상 적용된다고 가정하지 말고 로딩을 확인하세요. [공식 문서](https://prod.cursor.com/docs/rules) |

로딩 설명은 2026-10-24 공식 문서를 기준으로 확인했습니다. 다른 에이전트는 `agent_rules`에 경로를 추가하고 해당 도구의 지침 파일 요건을 검증하세요. 공유 경로와 컨텍스트 디렉터리 변경은 [설정](docs/ko/configuration.md)에 설명합니다.

## 관련 도구

| 필요한 작업 | 살펴볼 도구 |
| --- | --- |
| 여러 코딩 도구의 설정 생성·가져오기 | [Rulesync](https://github.com/dyoshikawa/rulesync) |
| 중앙 규칙과 디렉터리별 에이전트 규칙 배포 | [Ruler](https://github.com/intellectronica/ruler) |
| 토큰 수 확인과 보안 검사를 포함한 저장소 내용 패키징 | [Repomix](https://repomix.com/guide/) |
| 세션 사이의 결정·작업 기록·다음 행동을 작은 편집 가능한 파일로 관리 | ctx-kit |

## 문서

| 가이드 | 확인할 내용 |
| --- | --- |
| [시작하기](docs/ko/getting-started.md) | 새 프로젝트·기존 프로젝트 설치, `scripts/`·Windows 사용, 설치 검증 |
| [설정](docs/ko/configuration.md) | 경로, 에이전트, 수집 규칙, Git 옵션 |
| [사용 흐름](docs/ko/workflows.md) | 작업 시작·종료, 로그 조회, 보관, 공유, 기존 설치 업데이트 |
| [문제 해결](docs/ko/troubleshooting.md) | 충돌, 지침 로딩 문제, Git 제약, 중단된 쓰기 복구 |
| [기여하기](CONTRIBUTING.ko.md) | 로컬 검증, PR 생성, 필수 CI 확인, 머지와 main 푸시 검증 |

각 가이드 상단에서 영문 문서로 이동할 수 있습니다. 이 문서는 현재 체크아웃의 소스를 설명합니다. 문서와 `ctx.sh`는 같은 리비전을 사용하세요.

## 개발과 기여

별도 테스트 의존성은 필요하지 않습니다.

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

테스트는 임시 프로젝트에서 초기화, 기존 규칙 보존, 기록, 동시 쓰기, archive 실패와 복구를 확인합니다. AI 모델을 실행하거나 지침 준수를 증명하지는 않습니다. 현재 macOS 테스트 환경에서 Windows 실행은 검증하지 않았습니다.

루트 `AGENT_RULES.md`와 `ctx.sh`에 내장된 템플릿을 일치시키세요. 내장본 덕분에 스크립트와 설정만 복사해 설치할 수 있으며, 초기화 테스트가 템플릿 차이를 검사합니다.

[CI](.github/workflows/ci.yml)는 문서 변경을 포함한 모든 PR과 `main` 푸시에서 위 Bash 문법 검사와 전체 unittest 명령을 실행합니다. 각 실행은 `ubuntu-latest`와 `macos-latest`에서 Python 3.11을 사용합니다.

이 저장소의 `main` 변경은 관리자도 PR을 거쳐야 합니다. 다음 GitHub Actions 검사 두 개가 모두 필수입니다.

- `Regression tests (ubuntu-latest)`
- `Regression tests (macos-latest)`

PR에는 최신 `main` 변경이 반영되어야 합니다. `main` 강제 푸시와 삭제는 금지되어 있습니다. 필수 리뷰 승인 인원은 **0명**이며, PR과 두 CI 결과는 반드시 필요합니다. 이 보호 정책은 워크플로 파일과 별개로 GitHub에서 설정합니다.

작업 브랜치에서 로컬 검증을 실행하고, 검토한 파일만 커밋·푸시해 `main` 대상 PR을 만드세요. 머지 전에는 두 필수 검사를, 머지 후에는 별도의 `main` 푸시 CI를 확인합니다. [기여 가이드](CONTRIBUTING.ko.md)에 전체 명령과 fork 사용, 최신 main 반영, 브랜치 정리 절차를 정리했습니다.

## 라이선스

MIT
