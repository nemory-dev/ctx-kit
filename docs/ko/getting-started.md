# ctx-kit 시작하기

[English](../en/getting-started.md) · [README](../../README.ko.md) · [설정](configuration.md) · [사용 흐름](workflows.md) · [문제 해결](troubleshooting.md)

작은 프로젝트 컨텍스트를 만들고 작업 하나를 기록한 뒤, 다른 세션에서도 읽을 수 있는지 확인합니다. 기존 프로젝트에 적용하기 전에 새 데모 디렉터리에서 시작하세요.

## 준비 사항

| 도구 | 필요한 이유 |
| --- | --- |
| Bash와 기본 Unix 도구 | `ctx.sh` 실행, 링크 생성, 텍스트 파일 읽기·편집. Windows에서는 Git Bash를 사용합니다. |
| Python 3.7 이상 | JSON 처리와 로그 관리. 유지보수 중인 Python 3 버전을 사용하세요. 3.7은 코드의 최소 기준이며 설치 권장 버전은 아닙니다. |
| Git | 저장소 복제, 커밋 이력 가져오기, 로컬 컨텍스트 스냅샷. 프로젝트 자체가 Git 저장소가 아니어도 컨텍스트를 초기화할 수 있습니다. |

```bash
bash --version
python3 --version
git --version
```

CLI는 `PATH`에서 `python3`, `python`, `py -3` 순으로 후보를 찾습니다. 각 후보를 실제 실행하고 `sys.version_info >= (3, 7)`을 검사하며, 없거나 실행할 수 없거나 버전이 낮은 후보는 건너뜁니다. 명령을 실행할 때 처음 통과한 후보를 사용합니다. 모두 실패하면 설명과 함께 0이 아닌 코드로 종료하며, `init`은 설정이나 컨텍스트 파일을 생성하기 전에 Python을 검증합니다. `help`와 `version`에는 Python이 필요하지 않습니다. 개인 런타임 위치는 탐색하지 않습니다.

이 가이드의 독립적인 Python 예제는 `python3`를 사용합니다. 유효한 후보가 `python`이나 `py -3`이면 `-m json.tool`을 포함한 예제에서도 해당 명령으로 바꾸세요. [Python 진단](troubleshooting.md#python-git-스크립트를-찾지-못할-때)으로 같은 셸의 후보를 확인할 수 있습니다.

현재 검증 환경은 macOS Apple Silicon, Bash 3.2.57, Python 3.11.8, Git 2.42.0입니다. Linux에서도 같은 Bash 명령을 사용합니다. Windows 설치는 아래에 설명하지만 이 macOS 환경에서 실제 실행을 검증하지는 않았습니다. Node.js, pip 패키지, LLM API 키, 실행 중인 서버는 필요하지 않습니다.

## 1. 데모 만들기

`ctx-kit`과 `ctx-demo`가 없는 디렉터리에서 실행합니다. 이미 이 저장소가 있다면 다시 복제하지 않고 해당 체크아웃의 `ctx.sh`와 설정을 사용하세요. 스크립트와 문서는 같은 리비전을 사용합니다.

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
mkdir ctx-demo
cp ctx-kit/ctx.sh ctx-kit/ctx.config.json ctx-demo/
cd ctx-demo
bash ctx.sh init --no-hook --no-backfill
bash ctx.sh status
```

첫 명령은 전역 설치를 하지 않습니다. 복사한 CLI는 데모 프로젝트 안에 위치합니다. `init`은 `sample-context/` 아래에 없는 템플릿을 만들고 활성화된 에이전트 경로를 `sample-context/AGENT_RULES.md`에 연결합니다.

Git 연동은 별도 단계에서 선택하도록 옵션을 지정했습니다.

- `--no-hook`: Git 훅, 컨텍스트 제외 설정, 별도 로컬 Git 저장소를 설치하지 않습니다.
- `--no-backfill`: 과거 커밋을 가져오지 않습니다.

일반 Git 저장소에서 옵션 없는 `init`은 이력과 훅 설치를 물을 수 있으며, 훅 설치 기본 응답은 yes입니다. 스크립트나 CI에서는 위 옵션을 명시해 초기화 동작을 정하세요. `--hook`과 `--backfill`은 훅 설치와 최근 30개 커밋 가져오기를 명시적으로 선택합니다. 아래 Git 연동을 검토한 뒤 사용하세요. 이 선택은 프로젝트에 일반 `.git/` 디렉터리가 있을 때 적용됩니다.

## 2. 검증하고 프로젝트에 맞게 편집하기

데모 루트에서 원본과 각 링크를 확인합니다.

```bash
test -f sample-context/AGENT_RULES.md
readlink CLAUDE.md
readlink AGENTS.md
readlink .cursor/rules/context.mdc
bash ctx.sh list
```

기본 설치에서 `CLAUDE.md`와 `AGENTS.md`는 `sample-context/AGENT_RULES.md`를, Cursor 링크는 `../../sample-context/AGENT_RULES.md`를 가리킵니다. 컨텍스트 디렉터리를 바꾸면 경로도 달라집니다. `status`는 링크 존재 상태를 표시하며, 도구가 지침을 읽었는지 또는 링크가 정확한 대상을 가리키는지까지 검증하지는 않습니다.

편집기로 다음 파일을 수정하세요.

| 파일 | 바꾸거나 추가할 내용 |
| --- | --- |
| `sample-context/AGENT_RULES.md` | Project Context의 프로젝트명, 단계, 기술 스택, 프로젝트별 제약 |
| `sample-context/MASTER_PLAN.md` | 실제 Current State와 적은 수의 Next Actions |
| `sample-context/decisions.md` | 프로젝트명. 실제로 채택한 결정만 기록 |
| `sample-context/backlog.md` | 프로젝트명과 기록이 허용된 아이디어·열린 질문 |

생성 규칙의 기준은 [AGENT_RULES.md](../../AGENT_RULES.md)입니다. 컨텍스트 읽기와 종료 검증을 에이전트에 지시하지만, CLI가 AI 모델의 준수를 강제하지는 않습니다. 새 에이전트 세션을 열고 `sample-context/AGENT_RULES.md`와 그 안에 연결된 컨텍스트 파일을 읽도록 명시하세요. 요약한 상태가 `MASTER_PLAN.md`와 맞는지 확인합니다.

## 3. 작업 하나를 기록하고 다시 읽기

```bash
bash ctx.sh log --summary "Initialized ctx-kit demo; checked rule links" --files "sample-context/AGENT_RULES.md,sample-context/MASTER_PLAN.md"
bash ctx.sh timeline --limit 1 --json
```

`log`가 `sample-context/work-log/timeline.jsonl`을 만듭니다. 반환된 JSON에서 입력한 요약과 파일 경로가 일치하는지 확인하세요. ID와 시각은 실행마다 달라집니다. 다른 작성자가 동시에 기록했다면 `--limit`을 늘려 자신의 항목을 찾으세요. 일상 작업 전체 절차는 [사용 흐름](workflows.md)에 설명합니다.

<a id="existing-projects"></a>
## 기존 프로젝트에 적용하기

기존 저장소에 적용하기 전에 설정과 지침을 보존하세요. 아래 `/path/to/...`는 자리표시자이므로 실제 경로로 바꿉니다.

1. 기존 설치를 조용히 덮어쓰지 않도록 CLI와 설정을 복사합니다.

   ```bash
   cp -i "/path/to/ctx-kit/ctx.sh" "/path/to/project/"
   cp -i "/path/to/ctx-kit/ctx.config.json" "/path/to/project/"
   cd "/path/to/project"
   ```

   대상 파일이 이미 있으면 비교하기 전에는 교체를 거절하세요. 프로젝트에서 사용하던 `source`, 에이전트, 수집 규칙을 유지합니다.

   Python 실행 파일과 프로젝트 경로, 설정한 컨텍스트·에이전트·수집 경로에는 공백, 한글 등 유니코드, 작은따옴표를 사용할 수 있습니다. 셸 경로는 `cd "/path/to/team's project"`처럼 큰따옴표로 감싸세요. [경로 규칙](configuration.md#전제-조건과-경로-규칙)을 참고하세요.

2. `ctx.config.json`과 이미 사용 중인 규칙 파일을 확인합니다.

   ```bash
   python3 -m json.tool ctx.config.json
   ls -ld CLAUDE.md AGENTS.md .cursor/rules/context.mdc
   ```

   없는 규칙 경로는 정상이며 `ls`가 이를 오류로 표시할 수 있습니다. `agent_rules`에 추가 경로가 있으면 함께 확인하세요. 지침을 병합하기 전에 기존 규칙 내용과 설정된 컨텍스트 디렉터리를 비공개 위치에 백업합니다. 심볼릭 링크는 다른 파일을 가리키므로 이동하기 전에 실제 대상을 확인하세요.

3. 컨텍스트 디렉터리는 **최초 초기화 전에** 선택합니다. 기본값은 `sample-context/AGENT_RULES.md`입니다. `.ctx-local/AGENT_RULES.md`를 사용하려면 기존 설정의 `source`와 해당 `generate.*.output` 경로를 수정하세요. [설정](configuration.md)의 전체 예제를 참고하되 일부 예제로 설정 파일 전체를 대체하지는 마세요.

4. 자동 Git 변경 없이 초기화합니다.

   ```bash
   bash ctx.sh init --no-hook --no-backfill
   ```

   활성 규칙 경로에 일반 파일, 관련 없는 링크, 디렉터리가 있으면 충돌을 알리고 보존합니다. 링크 검사 전에 없는 컨텍스트 템플릿은 생성되었을 수 있습니다. 각 충돌은 명시적으로 해결하세요.

   - 기존 진입 파일을 유지하려면 해당 ctx-kit 에이전트 설정을 비활성화합니다. 공유 `AGENTS.md`를 관리하지 않으려면 Codex와 Antigravity 두 행을 모두 비활성화해야 합니다.
   - 또는 기존 지침을 설정된 원본에 비교·병합하고 비공개 백업을 확인한 뒤 충돌 항목을 대상 경로 밖으로 옮겨 `init`을 다시 실행합니다. 프로젝트별 제약을 유지하고 사용자 규칙 전체를 기본 템플릿으로 덮어쓰지 마세요.

   `--force`나 자동 가져오기·병합 명령은 없습니다. `enable`/`disable`의 sync가 실패해도 설정 변경은 저장되었을 수 있으므로 재시도 전에 설정과 파일 상태를 함께 확인하세요.

5. `status`와 데모 2단계의 실제 링크 검사를 실행하고, 다음 프로젝트 커밋 전에 제외 규칙을 설정합니다. 일반 `init`은 기존 컨텍스트 파일을 보존하며 `sync`는 그 내용을 업그레이드하지 않습니다. 기존 설치에서 `source`를 바꿔도 파일 이동이나 기존 링크 대상 변경을 자동으로 처리하지 않습니다.

충돌과 컨텍스트 이동은 [문제 해결](troubleshooting.md)을, 기존 설치 업데이트는 [사용 흐름](workflows.md)을 참고하세요.

## scripts/에 설치하기

CLI는 이름이 정확히 `scripts`인 디렉터리를 프로젝트 루트의 한 단계 아래로 인식합니다. 설정은 프로젝트 루트에 둡니다. 새 대상 프로젝트를 만들려면 `ctx-kit`이 있는 디렉터리에서 실행하세요.

```bash
mkdir ctx-scripts-demo
mkdir ctx-scripts-demo/scripts
cp ctx-kit/ctx.sh ctx-scripts-demo/scripts/
cp ctx-kit/ctx.config.json ctx-scripts-demo/
cd ctx-scripts-demo
bash scripts/ctx.sh init --no-hook --no-backfill
bash scripts/ctx.sh log --summary "Verified scripts installation" --files "scripts/ctx.sh"
bash scripts/ctx.sh timeline --limit 1 --json
```

생성된 규칙의 명령 예제도 `bash scripts/ctx.sh`를 사용합니다. `tools/` 같은 임의의 하위 디렉터리는 프로젝트 루트 설치로 해석하지 않습니다. 문서의 루트 또는 `scripts/` 배치를 사용하세요.

<a id="local-git-exclusions"></a>
## 로컬 Git 제외 설정

훅을 건너뛰면 ignore 규칙도 추가하지 않습니다. Git 프로젝트에서는 어떤 파일이 개인용이고 어떤 파일을 팀이 의도적으로 공유할지 먼저 정하세요. 기본 컨텍스트와 생성 링크를 모두 개인용으로 사용할 경우, **프로젝트 루트**에서 다음 명령으로 로컬 제외 규칙을 추가합니다.

```bash
CTX_EXCLUDE_PATH=$(git rev-parse --git-path info/exclude)
printf '\n# Personal ctx-kit context and generated links\n/sample-context/\n/CLAUDE.md\n/AGENTS.md\n/.cursor/rules/context.mdc\n' >> "$CTX_EXCLUDE_PATH"
git check-ignore -v sample-context/AGENT_RULES.md
git ls-files -- sample-context/
git status --short
```

경로를 수정했다면 실제 컨텍스트와 대상 경로를 사용하세요. 비공개·미추적 컨텍스트라면 `git ls-files -- sample-context/` 출력은 비어 있어야 합니다. 제외 규칙은 추적 중인 파일이나 과거 커밋을 지우지 않습니다. 경로가 출력되면 공유 전에 추적·이관 정책부터 정하세요. 데모를 적용하기 위해 팀이 관리하던 규칙을 삭제하지 마세요.

규칙 링크를 팀과 공유한다면 원본도 팀원이 사용할 수 있어야 합니다. 커밋된 링크가 개인의 ignored 디렉터리를 가리키면 새로 복제한 저장소에서 끊어집니다. `.git/info/exclude`는 해당 로컬 저장소용이며 `.gitignore`는 팀과 공유할 제외 규칙에 적합합니다. 훅 설치는 컨텍스트 디렉터리를 제외하며 모든 생성 링크를 제외하지는 않습니다.

나중에 훅을 사용하려면 Git 작성자 정보와 기존 훅 설정부터 확인합니다.

```bash
git var GIT_AUTHOR_IDENT
git config --get core.hooksPath
```

두 번째 명령은 미설정 상태에서 보통 출력 없이 종료 코드 1을 반환합니다. 현재 설치기는 일반 `.git/` 디렉터리를 요구하고 `.git/hooks/pre-commit`에 기록하므로 worktree와 사용자 지정 훅 경로는 [Git 제약](troubleshooting.md)을 확인하세요. 설정을 확인한 뒤 실행합니다.

```bash
bash ctx.sh hook install
bash ctx.sh hook status
```

컨텍스트 안에 별도 로컬 Git 저장소를 초기화하고 컨텍스트 제외 규칙과 Git sync를 설정합니다. 로컬 컨텍스트 커밋을 만들 수 있지만 푸시하지는 않습니다. 커밋 전 동작과 연동 해제는 [사용 흐름](workflows.md)을 참고하세요.

## Windows

Git for Windows와 유지보수 중인 Python 3를 설치하고, Git Bash에서 `python3`, `python` 또는 Python 런처 `py -3`로 실행되는지 확인하세요. CLI는 이 순서로 후보를 검증하며 Python 3.7 이상을 요구합니다. 다른 터미널에서만 찾을 수 있는 Python 설치로는 부족합니다. Windows의 심볼릭 링크 생성도 허용되어야 합니다. 실패하면 [Windows 문제 해결](troubleshooting.md)을 참고하세요. CLI에는 링크를 일반 복사로 바꾸는 자동 대체 기능이 없습니다.

두 대상 디렉터리가 없는 위치에서 PowerShell로 데모를 만듭니다.

```powershell
git clone https://github.com/nemory-dev/ctx-kit.git
New-Item -ItemType Directory -Path ctx-demo
Copy-Item -Path .\ctx-kit\ctx.sh,.\ctx-kit\ctx.cmd,.\ctx-kit\ctx.config.json -Destination .\ctx-demo\
Set-Location .\ctx-demo
.\ctx.cmd init --no-hook --no-backfill
.\ctx.cmd status
.\ctx.cmd log --summary "Initialized Windows demo" --files "ctx.config.json"
.\ctx.cmd timeline --limit 1 --json
```

`ctx.cmd`는 Git Bash가 필요한 래퍼이며 네이티브 PowerShell 구현이 아닙니다. **`ctx.sh` 옆에** 복사하세요. `scripts/` 설치에서는 두 파일을 `scripts/`에 두고 설정은 프로젝트 루트에 유지한 뒤, 프로젝트 루트에서 `.\scripts\ctx.cmd`를 실행합니다. CMD에서는 `ctx.cmd status`를, Git Bash에서는 위의 Bash 명령을 사용하세요. 래퍼가 Git Bash나 Python 설치를 찾지 못하면 [문제 해결](troubleshooting.md)의 진단 절차를 따르세요.

## 완성한 것

공유 규칙 원본, 편집 가능한 상태·결정·백로그 파일, 다른 세션에서 조회할 수 있는 작업 기록을 만들었습니다. 경로를 조정하려면 [설정](configuration.md)을, 일상 작업에는 [사용 흐름](workflows.md)을, 검증에 실패했다면 [문제 해결](troubleshooting.md)을 확인하세요.
