# 문제 해결과 복구

[English](../en/troubleshooting.md) · [README](../../README.ko.md) · [시작하기](getting-started.md) · [설정](configuration.md) · [워크플로](workflows.md)

Bash 예제는 프로젝트 루트에서 실행합니다. 루트에 `ctx.sh`가 있고 `source`가 `sample-context/AGENT_RULES.md`인 구성을 기준으로 합니다. `scripts/`에 설치했다면 `bash scripts/ctx.sh`를 사용하고, `sample-context`는 설정한 컨텍스트 디렉터리로 바꾸세요. CLI는 현재 작업 디렉터리가 아니라 스크립트 위치로 프로젝트를 찾습니다.

## 먼저 현재 상태 보존하기

로그 수정, 충돌 파일 이동, 중단된 아카이브 조정 전에 컨텍스트를 쓰는 작업을 멈추고 프로젝트 밖의 비공개 경로에 백업하세요. 컨텍스트에는 프로젝트 내부 정보가, 복구 저널에는 반영 대기 중인 파일 전체 내용이 들어갈 수 있습니다.

```bash
ctx_backup="$(mktemp -d "$HOME/ctx-kit-recovery.XXXXXX")"
cp -p ctx.config.json "$ctx_backup/"
cp -R sample-context "$ctx_backup/context"
printf 'Private backup: %s\n' "$ctx_backup"
```

비공개 로컬 경로를 사용하세요. 초기화가 덜 끝났다면 존재하는 파일만 복사하고, 복구를 검증할 때까지 백업을 보관하세요. 컨텍스트나 저널 전체를 공개 이슈에 붙여 넣지 마세요.

## Python, Git, 스크립트를 찾지 못할 때

| 증상 | 원인 | 안전한 조치와 검증 |
| --- | --- | --- |
| `Error: Python 3.7 or newer is required.` | `PATH`의 `python3`, `python`, `py -3` 후보 중 실제 실행과 버전 검사를 모두 통과하는 후보가 없습니다. 후보가 없거나 실행할 수 없거나 너무 오래되었을 수 있습니다. | 유지보수 중인 Python 3를 설치하거나 같은 셸의 `PATH`에서 기존 설치를 찾을 수 있게 하세요. 후보는 순서대로 검사하며 부적합한 후보는 건너뜁니다. 재시도 전에 아래 진단을 실행하세요. |
| `git: command not found` 또는 Git 연동 실패 | 해당 셸에서 Git을 찾지 못합니다. 일부 명령은 Git 오류를 숨기므로 Git 관련 필드가 비어 있다는 것만으로 정상 여부를 판단할 수 없습니다. | `command -v git`, `git --version`을 확인하고 기존 Git 실행 파일을 `PATH`에서 찾을 수 있게 한 뒤 Git 기능을 재시도하세요. |
| `bash: ctx.sh: No such file or directory` | 실행 경로가 틀리거나 CLI를 다른 디렉터리에 복사했습니다. | `ctx.sh`를 프로젝트 루트 또는 이름이 정확히 `scripts`인 디렉터리에 두고 해당 경로로 실행하세요. 저장소 쓰기 헬퍼가 포함되어 있어 `ctx.sh` 한 파일만 복사해도 동작합니다. |

```bash
command -v python3
python3 -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v python
python -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v py
py -3 -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v git
git --version
bash --version
```

후보가 없거나 실행할 수 없으면 해당 진단은 0이 아닌 코드로 종료됩니다. 위 버전 진단도 Python 3.7 미만이면 0이 아닌 코드를 반환합니다. 다른 후보를 사용할 수 있다면 이런 실패는 정상입니다. CLI는 처음 통과한 후보를 선택하여 해당 명령 전체에 사용합니다. 모두 실패하면 요구 사항을 설명하고 0이 아닌 코드로 종료합니다. `init`은 설정이나 컨텍스트 파일을 생성하기 전에 검사하며, `help`와 `version`은 Python 없이 사용할 수 있습니다.

설치된 Python이 `PATH` 밖에 있다면 ctx-kit을 실행하는 셸에서 실행 파일이 있는 디렉터리를 추가하세요. 예를 들어 자리표시자를 실제 경로로 바꾼 `export PATH="/path/to/Python directory:$PATH"`를 사용할 수 있습니다. 공백이나 작은따옴표가 있으면 큰따옴표를 유지하세요. 모든 후보가 너무 오래되었다면 유지보수 중인 Python 3를 설치하고 `PATH`를 갱신하세요. 최소 버전은 3.7입니다. CLI는 이 `PATH` 후보만 탐색하며 개인 런타임 대체 경로는 없습니다.

아래 독립적인 Python 예제는 `python3`를 사용하므로 필요하면 통과한 `python`이나 `py -3` 명령으로 바꾸세요. 회귀 테스트는 macOS의 Bash 3.2, Python 3.11.8 환경에서 검증하며, 여기서 실제 Windows 실행을 검증하지는 않았습니다. CI는 Linux와 macOS에서 Python 3.11로 실행합니다. Python 3.7 기준이 이후 모든 버전에서 테스트했다는 뜻은 아닙니다.

## 설정 파일이 없거나 잘못되었을 때

`Error: ctx.config.json not found.`는 스크립트 위치로 정한 프로젝트 루트에 설정이 없다는 뜻입니다. 임의의 tools 디렉터리에 둔 스크립트는 그곳에서 설정을 찾습니다. 잘못된 위치에 설정을 하나 더 만들기 전에 CLI를 지원되는 루트 또는 `scripts/` 위치로 옮기세요.

새 프로젝트라면 [시작하기](getting-started.md)를 따르세요. 기존 프로젝트라면 설정을 덮어쓰지 말고 정상 버전을 복구하세요. 내용 출력 없이 JSON 문법을 확인할 수 있습니다.

```bash
python3 -m json.tool ctx.config.json >/dev/null
```

`JSONDecodeError`는 보통 마지막 쉼표 같은 JSON 문법 오류입니다. `KeyError: 'source'`, `KeyError: 'agent_rules'`는 필수 필드 누락을 뜻합니다. JSON 문법이 맞아도 설정 구조가 맞는 것은 아닙니다. [설정](configuration.md)과 비교하여 백업한 설정을 수정한 뒤 `bash ctx.sh status`를 다시 실행하세요.

`init`은 `source`에서 컨텍스트 디렉터리를 구하지만 규칙 템플릿의 파일명은 `AGENT_RULES.md`로 고정합니다. `.ctx-local/AGENT_RULES.md` 같은 디렉터리 변경은 지원합니다. `source`를 `.ctx-local/team-rules.md`로 바꿔도 `init`이 그 이름의 파일을 만들지는 않습니다. 지원되는 파일명을 사용하거나 `sync` 전에 기존 원본을 직접 준비하세요.

프로젝트·Python 실행 파일 경로, 설정한 컨텍스트·에이전트 경로, 수집 파일명에는 공백, 한글 등 유니코드, 작은따옴표를 사용할 수 있습니다. 셸 경로는 `bash "/path/to/team's project/ctx.sh" status`처럼 큰따옴표로 감싸세요. JSON에서는 `"source": "team's context/AGENT_RULES.md"`처럼 일반적인 큰따옴표 문자열을 사용하며 작은따옴표를 따로 이스케이프할 필요는 없습니다. 파일이 없다는 오류를 진단할 때 따옴표와 실제 설정 경로를 확인하세요. 예전에 복사한 CLI에서 이런 경로로 Python 문법 오류가 계속 나면 `ctx.sh`를 갱신하고 같은 리비전의 문서를 사용하세요.

## 설정 저장에 실패할 때

`enable`, `disable`, `hook install`, `hook uninstall`은 설정과 같은 디렉터리의 임시 JSON 쓰기를 마친 뒤 일반 파일인 `ctx.config.json`을 교체합니다. 교체 전 실패하면 0이 아닌 코드로 종료하고, 기존 설정과 권한을 보존하며 이 실행의 임시 파일을 정리합니다. `Refusing to replace non-regular configuration file`은 설정이 심볼릭 링크 등 일반 파일이 아닌 항목이어서 해당 항목과 연결 대상을 변경하지 않고 거부했다는 뜻입니다. 프로젝트 루트에 일반 설정 파일을 준비할 방법을 결정할 때까지 기존 항목과 백업을 보존하세요.

쓰기나 교체 오류라면 표시된 경로, 남은 저장 공간, 프로젝트 디렉터리의 쓰기 권한을 확인하세요. 교체에는 디렉터리 쓰기 권한이 필요합니다. 프로젝트 전체를 누구나 쓸 수 있게 바꾸지 마세요. 원인을 해결한 뒤 보존된 설정 문법과 현재 작업 상태를 확인합니다.

```bash
python3 -m json.tool ctx.config.json >/dev/null
bash ctx.sh list
bash ctx.sh hook status
```

실패한 작업에 필요한 확인만 실행하세요. 설정 교체는 다른 변경을 되돌리지 않습니다. `enable`/`disable`은 이후 `sync` 실패 전에 활성화 값을 저장했을 수 있습니다. 훅 설치는 ignore 규칙이나 컨텍스트 Git을 이미 변경했을 수 있고, 제거는 원본 훅을 이미 복원했거나 wrapper를 삭제했을 수 있습니다. 재시도 전에 해당 경로를 검토하세요. 다른 설정 작성자의 작업을 먼저 마치거나 중단하세요. 설정 수정을 잠그지는 않습니다.

## 규칙 파일 충돌, 누락, 잘못된 링크

`Conflict: ... already exists and is not a ctx-managed symlink`는 기존 일반 파일, 디렉터리, 다른 원본을 향하는 링크, 관련 없는 끊어진 링크를 보호하는 오류입니다. `sync`는 링크나 계획의 날짜를 바꾸기 전에 활성 대상 전체의 충돌을 확인합니다. 첫 `init`은 이 충돌을 만나기 전에 템플릿을 일부 생성했을 수 있습니다.

변경 전에 설정한 원본과 실제 링크 대상을 확인하세요.

```bash
python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
config = json.loads((root / "ctx.config.json").read_text(encoding="utf-8"))
source = root / config["source"]
print("Expected source:", source.resolve())
print("Source is a file:", source.is_file())
for agent in config["agent_rules"]:
    if str(agent["enabled"]).lower() != "true":
        continue
    target = root / agent["path"]
    print(agent["path"], "symlink:", target.is_symlink(),
          "file:", target.is_file(), "resolves to:", target.resolve(),
          "matches source:", target.resolve() == source.resolve())
PY
readlink CLAUDE.md
readlink AGENTS.md
```

Python 진단은 경로를 확인합니다. `is_file()`은 존재·파일 유형 확인이며 전체 접근 권한 검사는 아닙니다. `readlink`는 일반 파일이나 없는 파일에서 0이 아닌 코드로 종료됩니다. 해석된 경로가 설정한 원본과 같은지 비교한 뒤 규칙 내용을 로컬에서 확인하세요.

기존 규칙을 보존하는 방법을 선택하세요.

1. 충돌 항목과 의도한 링크 대상을 백업하고, 계속 필요한 지침을 설정한 원본에 병합하세요.
2. 검토한 충돌 항목만 안전한 위치로 이동하거나 이름을 바꾸세요. 또는 설정의 `agent_rules` 항목을 수정·비활성화하세요. 링크 충돌을 없애려고 컨텍스트 디렉터리나 원본을 삭제하지 마세요.
3. `bash ctx.sh sync`를 실행하고 위 진단과 `bash ctx.sh status`를 다시 실행하세요.

`target is the configured source file`은 에이전트 대상 경로를 다른 곳으로 바꿔야 한다는 뜻입니다. Codex와 Antigravity 중 하나만 비활성화하면 다른 하나가 쓰는 공유 `AGENTS.md`는 유지됩니다. 원본 자체가 심볼릭 링크일 수도 있으므로 확인 중 링크 체인을 보존하세요.

`status`의 초록색 표시는 심볼릭 링크가 현재 파일로 연결된다는 뜻입니다. 설정한 원본과 일치하는지까지 검증하지는 않습니다. 원본 누락이나 끊어진 링크를 표시하면서도 종료 코드가 0일 수 있으므로 위의 명시적 경로 비교를 사용하세요.

새로 clone한 뒤 에이전트 링크가 끊겨 있다면 로컬 컨텍스트 디렉터리가 Git에서 제외되어 공유되지 않았을 수 있습니다. `init --no-hook --no-backfill`로 로컬 컨텍스트를 준비하고 생성된 자리표시자를 검토한 뒤 `sync`하세요. 기존 규칙이나 커스텀 원본이 있다면 먼저 보존 절차를 따르세요. 링크를 공유해도 링크가 가리키는 비공개 파일은 배포되지 않습니다. 팀이 원본 규칙을 공유할지 각자 초기화할지 합의해야 합니다.

## 링크는 맞지만 에이전트가 규칙을 반영하지 않을 때

먼저 위 진단으로 해석된 링크 경로와 실제 규칙 내용을 확인하세요. 도구마다 규칙 탐색, 파일 우선순위, 자동 로딩이 다르므로 [설정](configuration.md)을 참고하세요. Codex는 지침을 바꾼 뒤 새 세션을 시작하여 지침 체인을 다시 구성하세요([Codex 지침 탐색](https://learn.chatgpt.com/docs/agent-configuration/agents-md)). Cursor는 `.mdc` 규칙에 의도한 활성화 방식에 필요한 메타데이터가 있는지 확인하세요([Cursor 규칙](https://prod.cursor.com/docs/rules)). 규칙 디렉터리에 파일이 있다는 것만으로 활성화되었다고 볼 수 없습니다. 규칙에 의존하기 전에 에이전트 안에서 실제 적용 지침을 확인하세요.

## 훅 설치 후에도 커밋이 동기화되지 않을 때

`hook install` 전에 Git 구조와 설정을 확인하세요.

```bash
git rev-parse --show-toplevel
git rev-parse --git-dir
git config --get core.hooksPath
bash ctx.sh hook status
```

`core.hooksPath`가 설정되지 않았다면 `git config --get core.hooksPath`는 출력 없이 종료 코드 1을 반환합니다. 정상적인 결과입니다. 변경 전에 실제 사용 중인 `pre-commit` 파일을 로컬에서 확인하세요.

| 확인 결과 | 의미와 안전한 다음 단계 |
| --- | --- |
| Git worktree처럼 `.git`이 파일임 | 설치기는 `.git` **디렉터리**를 요구하므로 정상 worktree에서도 `.git not found`를 표시할 수 있습니다. 수동 `log`·`backfill`을 사용하고 실제 Git 디렉터리를 쓰는 훅 연동은 저장소 담당자와 검토하세요. |
| `core.hooksPath`가 설정됨 | 설치기와 `hook status`는 이 설정을 따르지 않고 `.git/hooks/pre-commit`을 사용합니다. “Installed”만으로 Git이 그 파일을 실행한다고 볼 수 없습니다. 기존 훅 체계를 검토한 뒤 그곳에 연동하세요. |
| 이전 인라인 훅이 ctx-kit 실행 전에 종료됨 | 갱신한 CLI로 `bash ctx.sh hook install`을 실행해 알려진 인라인 블록을 wrapper로 변환합니다. 실행 가능한 보관 원본을 먼저 실행하며, 원본이 0이 아닌 코드로 종료하면 여전히 커밋을 막고 ctx-kit을 실행하지 않습니다. |
| wrapper 수정, 백업 충돌, 원본 백업 누락 | `.git/hooks/pre-commit`과 `.git/hooks/pre-commit.ctx-kit-original`이 있으면 보존합니다. 설치·제거 시 안전하지 않은 교체를 거부하므로 표시된 파일을 확인하고 의도한 원본을 복구한 뒤 재시도하세요. 오류를 우회하려고 백업을 삭제하지 마세요. |
| 훅에서 CLI를 찾지 못함 | 설치된 wrapper는 루트의 `ctx.sh`와 `scripts/ctx.sh`만 확인합니다. 지원되는 위치를 복원하세요. |
| `Author identity unknown` 또는 로컬 Git 커밋 실패 | 컨텍스트는 독립 Git 저장소를 쓰며 설치 중 첫 로컬 커밋 오류는 숨겨질 수 있습니다. 아래 명령으로 해당 저장소의 작성자 설정을 확인하고, 의도한 작성자 정보를 직접 설정한 뒤 재시도하세요. |

```bash
git -C sample-context config --get user.name
git -C sample-context config --get user.email
git -C sample-context status --short
git -C sample-context log -1 --oneline
```

작성자 필드가 없으면 종료 코드 1이며, 커밋이 없는 저장소에서는 `git log`가 실패합니다. 설치는 `.gitignore`, 설정, 컨텍스트 Git 저장소, 훅을 바꾸는 작업입니다. 읽기 전용 복구가 아니므로 구조를 검토한 뒤 재설치하세요. 컨텍스트 쓰기나 로컬 커밋 실패는 바깥쪽 Git 커밋도 막을 수 있습니다. 원인을 해결한 뒤 재시도 전에 타임라인을 확인하세요. 자동 로그는 이미 기록되었을 수 있습니다.

## “Ignored”만으로 비공개를 보장할 수 없음

ignore 규칙은 새 미추적 파일이 일반적인 방법으로 추가되지 않게 합니다. 이미 메인 저장소가 추적하는 파일을 해제하거나, 과거 커밋을 지우거나, 강제·수동 staging을 막지는 않습니다.

```bash
git ls-files -- sample-context
git check-ignore -v sample-context/AGENT_RULES.md
git diff --cached --name-only
```

실제 컨텍스트 경로로 바꾸세요. `git ls-files`가 출력하는 항목은 push 전에 검토해야 합니다. 디렉터리만 대상으로 한 `git check-ignore`나 훅 상태의 초록색 표시만으로는 부족합니다. 이미 추적하는 파일에 대해 `git check-ignore`가 출력 없이 종료 코드 1을 반환할 수 있습니다. 추적 파일, staged 변경, 팀 공유 정책을 확인한 뒤 추적 해제 범위를 정하세요. 일괄 삭제 명령을 적용하지 마세요. 비공개 내용이 이미 push되었다면 지금 ignore해도 과거 기록에서는 사라지지 않습니다.

추적하는 에이전트 링크와 제외하는 컨텍스트는 별도 결정입니다. Git은 심볼릭 링크의 대상 경로를 저장합니다. 원본 공유 정책과 각 플랫폼의 checkout 동작을 함께 검토하세요.

## 잘못된 JSONL, 권한 오류, 로그 실패

쓰기 명령은 잘못된 JSONL에 대해 파일명과 줄 번호를 보고합니다. 예: `invalid JSON at line 2`, `expected a JSON object at line 1`. 비어 있지 않은 각 줄은 JSON 객체여야 합니다. `null`, 배열, 문자열은 올바른 레코드가 아닙니다. 빈 줄은 무시하며 마지막 줄의 개행이 없어도 유효한 객체라면 지원합니다.

쓰기 작업을 멈추고 컨텍스트를 백업한 뒤 로컬 편집기로 해당 줄을 확인하세요. 정상 레코드를 복원하거나 원래 증거를 바탕으로 검토한 수정을 하세요. 잘못된 줄을 조용히 버리거나, 이력을 지어내거나, 파일을 잘라내지 마세요. `archive`는 기존 월별 아카이브도 검증하므로 문제가 hot 로그 대신 `archive/timeline-YYYY-MM.jsonl`에 있을 수 있습니다.

다음 읽기 전용 진단은 레코드 내용을 출력하지 않고 hot 로그와 월별 아카이브의 줄별 객체 문법을 확인합니다.

```bash
python3 - <<'PY'
import json
from pathlib import Path

root = Path("sample-context")
paths = [root / "work-log/timeline.jsonl"]
paths += sorted((root / "archive").glob("timeline-*.jsonl"))
failed = False
for path in paths:
    if not path.exists():
        continue
    with path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                if not isinstance(entry, dict):
                    raise ValueError("expected a JSON object")
            except ValueError as error:
                print(f"{path}: line {number}: {error}")
                failed = True
raise SystemExit(1 if failed else 0)
PY
bash ctx.sh timeline --limit 20 --json
```

객체 문법 확인은 각 필드의 의미까지 검증하지는 않습니다. 잘못된 데이터에서 `timeline`이 traceback을 출력할 수 있습니다. `export`는 이 오류를 숨기므로 직접 실행하세요.

`Refusing to replace non-regular file`, `Permission denied`, I/O 오류는 해당 경로의 유형, 권한, 저장 공간을 확인해야 합니다. 원자적 쓰기 기능은 로그·출력 대상 자리에 있는 디렉터리나 심볼릭 링크를 의도적으로 덮어쓰지 않습니다. 기존 항목을 보존하고 파일 유형 충돌을 검토해 해결하세요. 프로젝트 전체를 누구나 쓸 수 있는 권한으로 바꾸지 마세요.

동반 README 생성이나 로컬 컨텍스트 커밋 과정에서 실패하면 로그는 이미 저장되었을 수 있습니다. `log` 또는 Git 커밋을 재시도하기 전에 의도한 기록이 타임라인에 있는지 확인하세요. 새 작업 단위로 다시 기록하면 새 ID가 생겨 같은 사건이 중복될 수 있습니다.

## 쓰기 잠금 시간 초과

`Timed out waiting for context writer lock: .../.ctx.lock`는 다른 쓰기 작업이 잠금을 잡은 채 30초 대기 시간이 지났다는 뜻입니다. `.ctx.lock` 파일은 정상 종료 후에도 남습니다. 파일이 있다는 것만으로 잠금이 사용 중이라는 뜻은 아닙니다.

다른 작업이 끝나기를 기다리거나 정상적으로 중지하세요. macOS에서는 `lsof sample-context/work-log/.ctx.lock`로 파일을 사용하는 프로세스를 확인할 수 있습니다. 사용 중인 잠금 파일을 삭제하면 다른 작업이 새 파일에 잠금을 잡아 동시 쓰기 보호가 깨질 수 있습니다. 쓰기 작업이 종료된 뒤 재시도하고, 이전 명령이 레코드를 추가했을 가능성이 있다면 타임라인부터 확인하세요. pre-commit 훅도 같은 잠금을 사용하므로 이 오류로 커밋이 막힐 수 있습니다.

## 중단된 아카이브와 복구 저널

`work-log/.ctx-archive-transaction.json`은 반영 대기 중인 아카이브 트랜잭션을 기록합니다. 공통 저장소 헬퍼를 쓰는 컨텍스트 쓰기 작업은 자기 작업 전에 잠금을 잡고 복구를 시도합니다. `log`, `backfill`, `archive`, 훅 쓰기가 여기에 포함됩니다. `timeline` 같은 읽기 명령은 복구하지 않습니다.

아카이브만 중단되었고 파일을 수동으로 바꾸지 않았다면 백업을 보관하고 권한·저장 장치 등 원인을 해결한 뒤 원래 작업을 다시 실행하세요. `Recovered interrupted archive transaction.`이 표시될 수 있습니다. 새 작업 전에 대기 중인 파일 교체를 끝냅니다. hot 로그, 관련 월별 아카이브, digest, 완료 작업, 결정을 백업과 비교하여 검증하세요.

`Cannot recover archive: file changed outside the pending transaction`은 현재 파일이 기록된 **변경 전** 해시와 **변경 후** 해시 모두와 다르다는 뜻입니다. 예상 밖 수정을 보존하기 위해 복구를 멈춥니다. 잘못된 저널, 안전하지 않은 경로, 심볼릭 링크인 저널도 거부합니다. 강제로 재시도하려고 저널을 삭제하거나 수정하지 마세요. `recover`, `repair`, reset CLI 명령은 없습니다.

쓰기 작업을 멈추고 비공개 백업을 만든 뒤 다음 읽기 전용 진단으로 대기 중인 내용 대신 경로와 해시만 확인할 수 있습니다.

```bash
python3 - <<'PY'
import hashlib
import json
from pathlib import Path

root = Path("sample-context").resolve()
journal = root / "work-log/.ctx-archive-transaction.json"
if journal.is_symlink():
    raise SystemExit("Refusing to inspect a symlinked journal")
pending = json.loads(journal.read_text(encoding="utf-8"))
if not isinstance(pending, dict) or not isinstance(pending.get("writes"), list):
    raise SystemExit("Invalid journal structure")
print("version:", pending.get("version"), "records:", len(pending["writes"]))
for index, record in enumerate(pending["writes"], 1):
    if not isinstance(record, dict) or not isinstance(record.get("path"), str):
        print(index, "invalid path record")
        continue
    relative = Path(record["path"])
    target = root / relative
    try:
        target.resolve().relative_to(root)
    except ValueError:
        print(index, "path outside context; stop")
        continue
    if relative.is_absolute() or target.is_symlink():
        print(index, "unsafe path; stop")
        continue
    after = record.get("after")
    after_hash = hashlib.sha256(after.encode("utf-8")).hexdigest() if isinstance(after, str) else "invalid"
    current = hashlib.sha256(target.read_bytes()).hexdigest() if target.is_file() else None
    print(index, repr(record["path"]), "before:", record.get("before"),
          "current:", current, "after:", after_hash)
PY
```

충돌 시 데이터를 이해하는 사람과 백업, 외부 수정, 대기 트랜잭션을 로컬에서 대조하고 모든 버전을 보관하세요. 각 대상이 알려진 변경 전 상태나 의도한 변경 후 상태와 일치해야 재시도할 수 있습니다. 정상 사본을 복원하기 전에 외부 수정을 따로 보관하고, 복구 후 다시 반영하세요. 해시를 추측하거나 저널을 교체하거나 레코드를 지어내면 안전 검사를 무력화합니다.

`.ctx-write-*`는 원자적 파일 교체를 위한 내부 임시 파일이며 사용자 설정이 아닙니다. 정상 쓰기는 이를 정리하지만 갑작스러운 종료 후에는 남을 수 있습니다. 진단 중 보존하세요. CLI의 로컬 Git 커밋 헬퍼는 이 파일, 잠금, 저널을 제외하지만 수동 `git add`까지 막지는 않습니다. 두 저장소 모두에서 runtime 파일의 staging 여부를 확인하세요.

## `generate`가 실패하거나 `export`가 불완전할 때

| 증상 | 원인 | 조치와 검증 |
| --- | --- | --- |
| `No input files remain after excluding the output`와 종료 코드 1 | `collect`에서 일치한 파일 중 출력과 같은 실제 경로·inode의 별칭을 제외하니 남은 입력이 없습니다. 기존 출력은 보존하며, 출력이 없었다면 만들지 않습니다. | 프로젝트 기준 패턴에 출력 외의 의도한 입력이 하나 이상 포함되도록 고치고 `bash ctx.sh generate project`를 다시 실행한 뒤 섹션을 확인하세요. 실패 후 남은 기존 출력은 새로 생성된 번들이 아닙니다. |
| `Output must be a regular file, not a symlink or other file type` | `generate`는 끊어진 링크를 포함한 심볼릭 링크·디렉터리·FIFO 등 일반 파일이 아닌 출력을 거부하며, 항목과 연결 대상을 변경하지 않습니다. | 아래 진단으로 설정 경로를 확인하세요. 기존 항목을 보존하고 아직 사용하지 않는 출력 경로나 의도적으로 교체할 일반 파일을 선택하세요. |
| 입력 읽기·출력 쓰기·교체 실패 | 권한이나 I/O 오류로 교체하지 못했습니다. 이 실행은 출력을 변경하지 않고 자체 임시 파일을 정리합니다. | 오류에 나온 입력·출력 경로, 출력 디렉터리 권한, 남은 저장 공간을 확인하고 원인을 해결한 뒤 다시 실행하세요. 교체에는 출력 디렉터리 쓰기 권한이 필요합니다. 프로젝트 전체를 누구나 쓸 수 있게 바꾸지 마세요. |
| `Output changed during generation; preserving it` | 최초 확인 후 교체 직전까지 출력이 변경되어, 이 실행은 출력을 교체하지 않고 중단합니다. 다른 작성자의 동시 쓰기를 잠그지는 않습니다. | 현재 출력을 확인하고 보존한 뒤 다른 작성자의 쓰기를 마치거나 중단하고 다시 실행하세요. |
| 생성 결과에 예상 밖 데이터가 있음 | 파일 시스템 glob으로 찾은 파일을 이어 붙입니다. Git ignore 규칙이나 바이너리·비공개 파일 제외는 적용하지 않으며 출력과 그 별칭만 자동 제외합니다. | 검토한 명시적 `collect` 목록을 권장합니다. 수집 경로와 결과를 로컬에서 확인하고 외부 공유 전에 인증 정보, 비공개 컨텍스트, 대용량·바이너리 파일을 제외하세요. |
| `export --all`에 보관된 타임라인이 빠짐 | `--all`은 완료 작업과 폐기된 결정의 아카이브를 추가하지만 월별 `archive/timeline-*.jsonl`은 포함하지 않습니다. | 전체 이력이 필요하면 해당 파일을 따로 확인하세요. `timeline`도 hot 로그만 읽습니다. |
| export가 성공했지만 최근 작업이 빠짐 | export는 `timeline` 오류를 숨기고 해당 섹션이 실패해도 종료 코드 0을 반환할 수 있습니다. | `bash ctx.sh timeline --limit 20 --json`을 직접 실행하고 위 JSONL 진단으로 검증한 뒤 export를 신뢰하세요. |

프로젝트 루트에서 최종 심볼릭 링크를 따라가지 않고 `project`의 출력 설정을 확인합니다.

```bash
python3 - <<'PY'
import json
import os
import stat
from pathlib import Path

config = json.loads(Path("ctx.config.json").read_text(encoding="utf-8"))
output = Path(config["generate"]["project"]["output"])
print("output:", output)
print("parent:", output.parent)
if os.path.lexists(output):
    print("entry type and permissions:", stat.filemode(output.lstat().st_mode))
else:
    print("output does not exist")
PY
```

첫 글자는 일반 파일이면 `-`, 심볼릭 링크면 `l`, 디렉터리면 `d`, FIFO면 `p`입니다. 다른 타입을 진단할 때는 코드의 `project`를 바꾸세요. `scripts/ctx.sh` 설치라면 `bash scripts/ctx.sh generate project`로 다시 실행합니다.

생성·내보내기 결과에서 민감 정보가 자동 필터링된다고 생각하지 마세요. 외부 LLM에 붙여 넣기 전에 확인하세요.

## Windows 래퍼와 심볼릭 링크 오류

`ctx.cmd`를 `ctx.sh` **옆에** 복사하세요. 명령 프롬프트에서는 `ctx.cmd`, PowerShell에서는 `./ctx.cmd` 또는 `.\ctx.cmd`, Git Bash에서는 `bash ctx.sh`를 사용합니다. `scripts/` 설치라면 두 파일을 모두 그곳에 두고 PowerShell에서 `.\scripts\ctx.cmd`로 실행하세요. 설정은 상위 프로젝트 루트에 둡니다.

`[Error] Git Bash is required to run ctx on Windows.`는 래퍼가 확인하는 위치에서 Git Bash를 찾지 못했다는 뜻입니다. Git Bash와 적절한 Python 실행 파일을 다른 터미널뿐 아니라 래퍼가 실행하는 셸에서도 찾을 수 있어야 합니다. Git Bash에서 위 Python 진단을 실행하세요. CLI는 `python3`, `python`, `py -3` 순으로 검사하며 Python 3.7 이상을 실제로 실행하는 후보만 사용합니다. 설치에 맞게 `PATH`를 설정하세요. CLI는 개인 런타임 위치를 탐색하지 않습니다.

심볼릭 링크 생성에는 Windows 지원과 충분한 권한도 필요합니다. 보통 개발자 모드나 적절한 권한의 셸로 준비합니다. `ln -s`가 실패하면 이 환경을 먼저 확인하세요. 심볼릭 링크 지원을 끈 Git은 링크를 일반 텍스트 파일로 checkout할 수 있습니다. `sync`는 충돌하는 일반 파일을 보존하므로 실행 전에 실제 파일 유형과 내용을 확인하세요. 이는 호환성 요구 사항이며, 여기서 실제 Windows 전체 실행을 검증하지는 않았습니다.
