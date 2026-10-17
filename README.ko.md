# ctx-kit

> 모든 AI 에이전트에게 동일한 프로젝트 컨텍스트를 제공하는 경량 CLI.

여러 AI 에이전트(Claude Code, Codex, Antigravity, Cursor 등)와 함께 작업할 때, 각 에이전트는 어떤 결정이 있었는지, 무엇이 이미 만들어졌는지, 현재 우선순위가 무엇인지 모른 채 세션을 시작합니다.

```
문제: 모든 에이전트가 백지 상태로 시작 → 반복 설명, 잊혀지는 결정, 일관되지 않은 방향
해결: AGENT_RULES.md 하나를 단일 진실 공급원으로 두고, 각 에이전트의 룰 파일을 심볼릭 링크로 연결
```

> 🇺🇸 English version: [README.md](README.md)

---

## 빠른 시작

```bash
# 1. 레포 클론
git clone https://github.com/nemory-dev/ctx-kit.git

# 2. 프로젝트 루트로 복사
cp ctx-kit/ctx.sh /your/project/
cp ctx-kit/ctx.config.json /your/project/

# 3. 초기화 (프로젝트당 1회)
cd /your/project
bash ctx.sh init

# 4. 상태 확인
bash ctx.sh status
```

`scripts/` 하위 디렉터리를 선호한다면:

```bash
cp ctx-kit/ctx.sh /your/project/scripts/
cp ctx-kit/ctx.config.json /your/project/

cd /your/project
bash scripts/ctx.sh init
```

---

## 동작 원리

```
ctx.config.json            ← 에이전트 경로 레지스트리 (에이전트 추가 시 여기만 수정)
        ↓  ctx sync
CLAUDE.md ──┐
AGENTS.md ──┼──→ sample-context/AGENT_RULES.md  (단일 진실 공급원)
GEMINI.md ──┘
```

`ctx.config.json`에 에이전트 룰 파일 경로를 등록한 뒤 `ctx sync`를 실행하면, 모든 룰 파일이 `AGENT_RULES.md`를 가리키는 심볼릭 링크가 됩니다. 그 파일 하나만 수정하면 모든 에이전트가 즉시 변경사항을 반영합니다.

`ctx.config.json`은 `source` 필드로 컨텍스트 디렉터리도 정의합니다. 기본값은 `sample-context/AGENT_RULES.md`지만, `docs/context/AGENT_RULES.md`처럼 다른 디렉터리로 지정할 수 있습니다. `status`, `sync`, `export`, `generate`, `log`, `timeline` 모두 이 컨텍스트 디렉터리를 따라갑니다.

---

## 커맨드

| 커맨드 | 설명 |
|--------|------|
| `bash ctx.sh init` | 새 프로젝트의 컨텍스트 파일 + 심볼릭 링크 초기화 |
| `bash ctx.sh status` | 심볼릭 링크 상태 + MASTER_PLAN 요약 표시 |
| `bash ctx.sh sync` | 심볼릭 링크 재구성 + Last Updated 날짜 자동 갱신 |
| `bash ctx.sh export` | 웹 LLM(Claude.ai, ChatGPT 등)에 붙여넣을 전체 컨텍스트 출력 |
| `bash ctx.sh generate <type>` | 설정된 소스 파일들을 묶어 컨텍스트 번들 생성 |
| `bash ctx.sh log --summary "..."` | 커밋/작업단위 요약을 `<context>/work-log/timeline.jsonl`에 기록 |
| `bash ctx.sh timeline --limit 20` | 최근 work-log 엔트리 표시 |
| `bash ctx.sh backfill [--limit N]` | 과거 Git 커밋 내역을 timeline.jsonl로 복원 |
| `bash ctx.sh archive [--keep N]` | 완료된 태스크, 오래된 로그 및 폐기/대체된 ADR 아카이브 분리 |
| `bash ctx.sh hook install` | Git pre-commit 훅 설치 (로컬 자동 동기화 & auto-log) |
| `bash ctx.sh hook uninstall` | Git pre-commit 훅 제거 |
| `bash ctx.sh hook status` | Git 연동 및 컨텍스트 로컬 저장소 상태 확인 |
| `bash ctx.sh list` | 등록된 에이전트와 활성 상태 목록 |
| `bash ctx.sh enable <n>` | 특정 에이전트 활성화 |
| `bash ctx.sh disable <n>` | 특정 에이전트 비활성화 |
| `bash ctx.sh help` | 전체 도움말 표시 |

> **Windows 사용자**: 명령 프롬프트(CMD) 또는 PowerShell에서 `ctx.cmd`를 직접 실행할 수 있습니다 (예: `ctx status`, `ctx log`, `ctx hook install`, `ctx archive`).

---

## 3단계 계층형 컨텍스트 & 아카이빙 (컨텍스트 비대화 방지)

프로젝트가 장기화되면서 완료된 작업과 수백 개의 커밋 로그가 누적되면 **컨텍스트 윈도우 낭비, 토큰 비용 증가, AI 주의 분산(Lost in the middle)**이 발생합니다. `ctx-kit`은 **3단계 계층형 컨텍스트 아키텍처**를 제공합니다:

```text
your-project/
└── .ctx-local/ (또는 sample-context/)
    ├── AGENT_RULES.md         ← [Hot] 매 세션 필독 규칙 (단일 진실 공급원)
    ├── MASTER_PLAN.md         ← [Hot] 현재 진행 중인 태스크 + 다음 액션만 유지
    ├── decisions.md           ← [Hot] 현재 유효한 아키텍처 결정(ADR)
    ├── backlog.md             ← [Hot] 아이디어 및 열린 질문
    ├── work-log/
    │   ├── timeline.jsonl     ← [Hot] 최근 20~30개 작업 단위 타임라인
    │   └── timeline-digest.md ← [Warm] 과거 작업 로그의 압축 마일스톤 요약
    └── archive/               ← [Cold] AI 기본 로딩에서 제외! (토큰 절약)
        ├── completed-tasks.md ← MASTER_PLAN에서 완료된 [x] 태스크 모음
        ├── decisions-deprecated.md ← decisions.md에서 폐기/대체된 ADR 모음
        └── timeline-YYYY-MM.jsonl ← 월별 분할 보관된 과거 타임라인 원본
```

### 명령어 하나로 원클릭 아카이빙
```bash
bash ctx.sh archive            # 최근 30개 로그 유지, 완료 태스크 & 폐기 ADR 아카이브
bash ctx.sh archive --keep 20  # 최근 20개 로그 유지
bash ctx.sh archive --no-decisions # 태스크와 로그만 아카이브 (결정 제외)
```

- **태스크 분리**: `MASTER_PLAN.md`에서 완료된 `- [x]` 항목들을 날짜 헤더와 함께 `archive/completed-tasks.md`로 이동시켜 현재 계획 문서를 슬림하게 유지합니다.
- **결정 아카이빙**: `decisions.md`에서 폐기되거나 대체된 ADR(`상태: 폐기됨 / 대체됨` 또는 `Status: Deprecated / Superseded` 등)을 `archive/decisions-deprecated.md`로 분리하여 활성 결정 문서를 간결하게 유지합니다.
- **타임라인 분할**: `timeline.jsonl`의 오래된 로그들을 월별로 `archive/timeline-YYYY-MM.jsonl`에 분할 보관합니다.
- **마일스톤 다이제스트**: 과거 이력들의 핵심 제목을 모아 `work-log/timeline-digest.md` 압축 요약본을 자동 생성하여 AI가 과거 맥락을 단숨에 파악할 수 있게 합니다.
- **토큰 최적화 내보내기**: `ctx export` 실행 시 `archive/` 폴더는 자동으로 제외하여 토큰을 70~80% 절약합니다 (`ctx export --all` 시 전체 포함).
- **로컬 Git 자동 커밋**: 아카이빙된 파일들도 로컬 전용 컨텍스트 Git에 자동으로 안전하게 커밋됩니다.

---

## Git 연동 & 자동 요약 로그 (로컬 비공개 버전 관리)

팀 공용 원격 저장소(GitHub 등)에 개인 메모나 AI 컨텍스트를 유출하지 않고 안전하게 로컬 버전 관리합니다:

1. **원격 푸시 원천 차단**: 컨텍스트 폴더(예: `.ctx-local/` 또는 `sample-context/`)는 메인 프로젝트의 `.gitignore`에 자동 등록되어 `git push` 시 절대 업로드되지 않습니다.
2. **독립 로컬 Git 추적**: `ctx hook install`을 실행하면 컨텍스트 폴더 내부에 별도의 로컬 Git 저장소가 생성되고, `pre-commit` 훅이 연동됩니다.
3. **커밋 직전 자동 요약 (auto_log)**: `ctx.config.json`에서 `auto_log: true`로 설정하면, 메인 코드 커밋 직전에 변경 파일 및 diff 통계를 자동으로 요약하여 `timeline.jsonl`에 선행 기록한 뒤 로컬 Git에 커밋합니다.
4. **기존 프로젝트 과거 이력 복원 (backfill)**: 이미 진행 중이던 프로젝트에 `ctx-kit`을 중간 도입한 경우, `bash ctx.sh backfill --limit 30`을 실행하여 이전 Git 커밋들을 `timeline.jsonl`로 한 번에 가져올 수 있습니다.

```json
// ctx.config.json
{
  "source": ".ctx-local/AGENT_RULES.md",
  "git_sync": {
    "enabled": true,
    "auto_log": true
  }
}
```

## 파일 구조

```
your-project/
├── ctx.config.json              ← 에이전트 경로 설정
├── CLAUDE.md                    → symlink → sample-context/AGENT_RULES.md
├── AGENTS.md                    → symlink → sample-context/AGENT_RULES.md
└── sample-context/
    ├── AGENT_RULES.md           ← 에이전트 동작 규칙 (이 파일만 수정)
    ├── MASTER_PLAN.md           ← 현재 상태 + 다음 액션
    ├── decisions.md             ← 아키텍처 결정 기록 (ADR)
    ├── backlog.md               ← 아이디어 + 미래 작업
    ├── generated/                ← ctx generate 결과물
    ├── work-log/
    │   └── timeline.jsonl        ← append-only 작업 단위 타임라인
    └── visuals/                 ← Mermaid 다이어그램 등
```

---

## 에이전트 추가

`ctx.config.json`의 `agent_rules`에 항목을 추가합니다:

```json
{
  "source": "sample-context/AGENT_RULES.md",
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/**/*.md",
        "src/**/*"
      ]
    }
  },
  "agent_rules": [
    { "name": "Claude",      "path": "CLAUDE.md",                "enabled": true,  "_note": "Claude Code" },
    { "name": "Codex",       "path": "AGENTS.md",                "enabled": true,  "_note": "OpenAI Codex (AGENTS.md 스펙)" },
    { "name": "Antigravity", "path": "AGENTS.md",                "enabled": true,  "_note": "Google Antigravity (Codex와 AGENTS.md 공유)" },
    { "name": "Cursor",      "path": ".cursor/rules/context.mdc", "enabled": true,  "_note": "Cursor IDE" },
    { "name": "MyAgent",     "path": "MY_AGENT.md",              "enabled": false }
  ]
}
```

그 후 실행:

```bash
bash ctx.sh sync
```

파일을 직접 수정하지 않고 활성/비활성을 토글하려면:

```bash
bash ctx.sh enable Cursor
bash ctx.sh disable Antigravity
```

`name`은 `enable`/`disable` 인자로 쓰이므로 짧게 유지하세요. 긴 도구 설명은 `_note`에 적습니다.

두 에이전트가 같은 룰 파일을 공유하는 경우(예: Codex와 Antigravity는 모두 AGENTS.md 스펙을 따름), 같은 `path`를 가리키는 별도 행으로 등록하세요. `sync`는 둘 중 하나라도 enabled면 심볼릭 링크를 유지합니다.

프로젝트 고유 파일을 더 수집하려면 `generate.project.collect`를 확장하세요:

```json
{
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/**/*.md",
        "src/**/*",
        "app/**/*",
        "server/**/*",
        "web/src/**/*"
      ]
    }
  }
}
```

---

## AGENT_RULES.md 커스터마이징

`sample-context/AGENT_RULES.md`는 에이전트가 어떻게 동작할지를 정의합니다. 기본 템플릿에는 다음이 포함됩니다:

- **세션 시작 프로토콜** — 현재 상태, 결정, 선택적 마일스톤 요약, 백로그를 읽도록 안내
- **자동 감지 + 기록 프로토콜** — 새로운 결정·범위·우선순위 변경은 확인하고, 승인된 작업의 사실적 진행 상태는 바로 기록
- **세션 종료 프로토콜** — 변경 검증, 관련 컨텍스트 갱신, `ctx log` 기록과 재조회를 거쳐 마감 결과를 보고
- **절대 규칙** — 프로젝트 고유 제약

`## 5. Project Context` 섹션을 프로젝트 이름, 기술 스택, 현재 단계에 맞춰 편집하세요.

### 작업 단위 마감

문서를 포함해 프로젝트 파일을 변경한 작업은 다음 순서로 마감합니다.

1. 실제 변경을 확인하고 관련 검증을 실행합니다. 구현·검증·커밋·병합 상태를 구분해서 보고합니다.
2. 현재 상태나 다음 행동이 바뀐 경우에만 `MASTER_PLAN.md`를 갱신합니다. 결정·백로그 변경은 해당 승인을 따르며, 바뀌지 않은 파일은 수정하지 않습니다.
3. `ctx log`의 종료 상태를 확인하고 `ctx timeline`으로 해당 기록을 재조회합니다. 요약에 검증 결과와 남은 문제를 포함하고, 관련 파일을 명시합니다.

```bash
bash ctx.sh log --summary "문서 수정; 검증 통과; 미결 없음" --files "README.md" --type docs
bash ctx.sh timeline --limit 1 --json
```

다른 작성자가 더 최신 기록을 추가했다면 조회 개수를 늘려 자신의 요약·파일을 확인합니다. 기록이나 재조회 실패 시 원인과 실패·미검증 상태를 보고합니다. 재시도 전 기존 기록 여부를 확인하고, 허용된 복구·승인 경로만 사용합니다. `timeline.jsonl`을 직접 수정해 CLI를 우회하지 않습니다.

읽기 전용 분석·리뷰에는 컨텍스트 수정이나 로그 기록이 필요하지 않습니다. 파일 변경 범위·기록 금지 같은 명시적 제한을 우선하고, 생략한 절차를 보고합니다. 파일·CLI 접근이 없는 에이전트는 적용할 수정안과 명령어를 제시하고 미적용 상태로 표시합니다. 이 규칙은 에이전트 지침이며 CLI가 자동 강제하지 않습니다. Git 훅도 이 마감 절차를 대신하지 않습니다.

### 템플릿 경로와 기존 설치 업데이트

`init`은 `ctx.config.json`의 컨텍스트 디렉터리와 실제 스크립트 위치를 생성 문서에 반영합니다. 예를 들어 `source: "docs/context/AGENT_RULES.md"`와 `scripts/ctx.sh`를 사용하면 `docs/context/MASTER_PLAN.md`, `bash scripts/ctx.sh` 형태로 안내합니다. 문서 경로는 프로젝트 루트 기준이며, 명령어도 프로젝트 루트에서 실행합니다.

`init`은 기존 규칙 파일을 건너뛰며, `sync`는 내용 업데이트 대신 링크를 재구성합니다(`MASTER_PLAN`의 `Last Updated` 날짜도 갱신). 기존 프로젝트에는 다음 절차로 적용하세요.

1. `ctx.config.json`의 `source`가 가리키는 파일을 백업합니다.
2. 이 저장소의 `AGENT_RULES.md`와 비교해 세션 시작·승인·마감·CLI 안내를 병합합니다. 프로젝트 고유 지침과 Project Context는 보존합니다.
3. 문서·명령어 경로를 설치 위치에 맞춘 뒤 `bash ctx.sh status` 또는 `bash scripts/ctx.sh status`로 소스와 활성 링크를 확인합니다. 다음으로 승인된 쓰기 작업을 수행할 때 마감 절차를 확인합니다.

업데이트를 위해 컨텍스트 디렉터리를 삭제하거나 커스텀 규칙 전체를 덮어쓰지 마세요.

---

## 컨텍스트 파일

### MASTER_PLAN.md
모든 세션의 출발점. 완료된 것, 다음 작업, 열린 질문을 추적합니다. `Last Updated` 날짜는 `ctx sync` 실행 시 자동 갱신됩니다.

### decisions.md
기술적 결정을 ADR(Architecture Decision Record) 형식으로 기록 — 무엇을, 왜 결정했고, 무엇을 포기했는지. 새 에이전트 세션마다 같은 결정을 다시 논의하는 걸 방지합니다.

### backlog.md
당장 급하진 않지만 잃어버리면 안 되는 아이디어, 미래 기능, 열린 질문을 모아둡니다.

### generated/
`ctx generate <type>`로 만들어진 소스 번들이 저장됩니다. 각 타입은 `ctx.config.json`의 `generate` 섹션에서 설정합니다.

### work-log/
`ctx log`로 만들어진 append-only `timeline.jsonl`이 들어있습니다. 특정 AI 세션 히스토리에 의존하지 않고 커밋/작업 단위 요약을 추적할 수 있습니다.

```bash
bash ctx.sh log --summary "피드백 MVP 구현" --type work
bash ctx.sh log --commit abc1234 --summary "릴리스 정리" --type release
bash ctx.sh timeline --limit 10
bash ctx.sh timeline --json
```

---

## 웹 기반 LLM (Claude.ai, ChatGPT, Gemini)

웹 LLM은 파일을 직접 읽을 수 없습니다. `ctx export`로 전체 컨텍스트를 텍스트로 출력한 뒤 채팅창에 붙여넣으세요:

```bash
bash ctx.sh export
# 출력 복사 → Claude.ai / ChatGPT에 붙여넣기
```

웹 LLM에서 작업할 때, 에이전트는 다음 형식으로 파일 변경사항을 출력하므로 직접 적용하면 됩니다:

```
📝 File update needed
Add to sample-context/decisions.md:
---
### ADR-NNN: ...
...
---
```

---

## 지원 에이전트

기본 설정에 포함된 에이전트:

| 에이전트 | 룰 파일 | 기본값 |
|----------|---------|--------|
| Claude (Claude Code) | `CLAUDE.md` | ✅ 활성화 |
| Codex (OpenAI Codex) | `AGENTS.md` | ✅ 활성화 |
| Antigravity (Google) | `AGENTS.md` (Codex와 공유) | ✅ 활성화 |
| Cursor | `.cursor/rules/context.mdc` | ✅ 활성화 |

고정된 경로에서 룰 파일을 읽는 모든 에이전트를 추가할 수 있습니다.

---

## 요구사항

- bash (macOS / Linux)
- python3 (JSON 파싱용)

---

## 여러 프로젝트에서 재사용

```bash
# 한 번만 클론
git clone https://github.com/nemory-dev/ctx-kit.git ~/ctx-kit

# 새 프로젝트마다
cp ~/ctx-kit/ctx.sh /new/project/
cp ~/ctx-kit/ctx.config.json /new/project/
cd /new/project && bash ctx.sh init
```

또는 alias를 추가:

```bash
# ~/.zshrc 또는 ~/.bashrc에 추가
alias ctx-setup='cp ~/ctx-kit/ctx.sh . && cp ~/ctx-kit/ctx.config.json . && bash ctx.sh init'
```

---

## 개발 검증

추가 테스트 의존성 없이 실행합니다.

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

테스트는 임시 프로젝트에서 단독·기본 초기화, 사용자 지정 경로, `scripts/` 명령어, 기존 컨텍스트 보존, 로그 기록 성공·실패를 확인합니다. AI 모델을 실행하거나 에이전트의 지침 준수율을 검증하는 테스트는 아닙니다.

루트 `AGENT_RULES.md`를 수정할 때는 `ctx.sh`의 `cmd_init`에 내장된 규칙도 함께 맞춥니다. 내장본은 `ctx.sh`와 설정만 복사하는 기존 설치 방식을 유지하기 위한 것이며, 테스트가 생성된 규칙과 루트 템플릿을 비교해 불일치를 감지합니다.

---

## 라이선스

MIT
