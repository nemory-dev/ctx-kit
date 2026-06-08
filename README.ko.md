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
| `bash ctx.sh list` | 등록된 에이전트와 활성 상태 목록 |
| `bash ctx.sh enable <n>` | 특정 에이전트 활성화 |
| `bash ctx.sh disable <n>` | 특정 에이전트 비활성화 |
| `bash ctx.sh help` | 전체 도움말 표시 |

---

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

- **세션 시작 프로토콜** — 에이전트가 작업 시작 전 컨텍스트 파일을 강제로 읽도록 함
- **자동 감지 + 기록 프로토콜** — 결정, 상태 변경, 백로그 항목을 발생 시점에 기록하도록 유도
- **세션 종료 프로토콜** — 에이전트가 변경사항 요약을 출력
- **절대 규칙** — 프로젝트 고유 제약

`## 5. Project Context` 섹션을 프로젝트 이름, 기술 스택, 현재 단계에 맞춰 편집하세요.

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

## 라이선스

MIT
