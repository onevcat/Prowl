# Workspace Setup, Agent Guide, and Editable Settings Plan

## Goal

把 Workspace 从“多仓库工作目录”推进到“可重复初始化、可给 agent 明确上下文、可持续维护配置”的形态。

这份方案覆盖三个后续功能：

- 每个 workspace child repository 在关联或新增时可以执行 bootstrap profile，用来同步 git ignored 文件、本机配置、agent 配置、证书占位文件等。
- Workspace root 可以生成 workspace 级别的 agent 指令文件，例如 `AGENTS.md` 或 `CLAUDE.md`，让 agent 知道每个 child repository 的职责和协作方式。
- Workspace 配置页从只读变为可编辑，但必须容纳上面两个能力，避免先做一版过窄的编辑 UI 后再重做。

## Current Model

当前 workspace 的核心 contract 是 workspace root 下的 `.prowl/workspace.json`。

已有 top-level 字段：

- `schema_version`
- `id`
- `title`
- `description`
- `task_links`
- `repositories`
- `created_at`
- `updated_at`

已有 repository entry 字段：

- `id`
- `name`
- `role`
- `path`
- `source_kind`
- `source_location`
- `branch_name`
- `base_ref`

后续设计应该扩展这份 metadata，而不是引入另一套 workspace 配置系统。Workspace root 仍然是 agent 的 cwd，`.prowl/workspace.json` 仍然是 workspace 的可持久化契约。

## Design Principles

- Workspace metadata 描述“这个 workspace 需要什么”，不要把所有本机实现细节都塞进去。
- 用户级 Prowl 配置描述“在这台机器上怎么做”，适合保存脚本正文、私有路径、本地 profile。
- 不自动执行 remote clone 里新出现的未信任脚本。
- 脚本执行状态、日志、最近一次结果属于 runtime state，不应该每次写回 `workspace.json`。
- Agent guide 应该可重复生成、可审阅、可手动编辑；Prowl 只更新自己管理的 block。
- Editable settings 必须保留 unknown fields，避免 UI 保存时破坏用户手写扩展或未来 schema。
- 用户级结构化配置应沿用现有手写 `SharedKey` + `SettingsFilePersistence` 模式，落在 `~/.prowl/*.json`；不要引入 `.fileStorage` 或 Application Support 存储路径。

## Feature 1: Child Repository Bootstrap Profiles

### Problem

创建 workspace 时，经常需要在每个 child repository 里补齐被 git ignore 的本机文件，例如：

- `.env.local`
- local config
- agent-specific config
- credentials placeholder
- symlink 到本地 shared config
- 子项目自己的 bootstrap 命令

这些步骤如果完全靠 agent 或用户手动做，会降低 workspace 的可重复性。

### Relationship to Existing Repository Scripts

Prowl already has repository-level `setupScript`, `archiveScript`, and `runScript` settings.

The existing `setupScript` is terminal-injected:

- It is stored in `RepositorySettings`.
- It is sent into a visible child worktree terminal tab.
- It naturally inherits the terminal/user environment.
- It does not provide a reliable exit-code contract, captured per-run log, timeout, or `required` failure semantics for workspace creation.

The workspace bootstrap capability in this plan should therefore be explicitly separate in V1:

- Use names such as `bootstrap profile`, `workspace bootstrap`, or `materialization hook`.
- Avoid adding another user-facing feature named `setup script`.
- Keep the old terminal-injected `setupScript` behavior unchanged.
- Revisit unification only if a later design can preserve both visible-terminal ergonomics and headless creation-time failure handling.

### Configuration Location Options

#### Option A: Source repository `.prowl`

例如从 source repository 读取：

```text
source-repo/
└─ .prowl/
   └─ workspace-setup.sh
```

优点：

- 离 repo 最近。
- 本地 repo 可以自己维护初始化逻辑。
- 对已有 local repository / existing path 很直观。

问题：

- remote clone 如果依赖本地 ignored `.prowl`，clone 后拿不到这份配置。
- remote clone 如果 `.prowl` 是 tracked 文件，自动执行等于自动执行远端代码，安全风险高。
- 同一个 repo 在不同用户机器上需要不同本地路径或 token 时，repo-local 配置不合适。

#### Option B: User-level Prowl config

脚本正文放在用户 Prowl 配置里，workspace metadata 只引用 profile。

例如：

```json
{
  "repositories": [
    {
      "name": "Prowl",
      "path": "Prowl",
      "bootstrap": {
        "script_kind": "user_profile",
        "script_id": "sync-prowl-local-config",
        "run_on": ["create", "manual"],
        "required": false
      }
    }
  ]
}
```

优点：

- remote clone、local repository、bare repository、existing path 都能使用同一能力。
- 私有路径、token、本机配置不会写进 workspace metadata。
- 安全边界清楚：用户自己创建的 profile 可以自动执行。
- 后续可以复用到多个 workspace。

问题：

- workspace metadata 不能单独表达完整执行逻辑，换机器后需要用户有对应 profile。
- 需要新增 user-level bootstrap profile 管理 UI 或配置文件。

### Recommended Model

采用混合模型，但 V1 以 user-level profile 为主。

Repository entry 新增可选字段：

```json
{
  "bootstrap": {
    "script_kind": "user_profile",
    "script_id": "sync-prowl-local-config",
    "run_on": ["create", "on_add", "manual"],
    "required": false
  }
}
```

预留 repo-local script：

```json
{
  "bootstrap": {
    "script_kind": "repo_local",
    "script_path": ".prowl/workspace-setup.sh",
    "run_on": ["manual"],
    "required": false
  }
}
```

V1 支持：

- `user_profile`
- `run_on: create`
- `run_on: manual`
- bootstrap logs
- bootstrap success/failure state

V1 不默认自动执行：

- remote clone 后出现的 repo-local script
- symlink child repository
- 每次 workspace open
- 每次 repository refresh

### Link Checkout Safety

`existingPath` / `localRepository` with link checkout materializes the child as a symlink into the user's real checkout.

That means a bootstrap script whose cwd is the child root will write through the symlink and mutate the original source repository. This directly conflicts with common bootstrap tasks such as writing `.env.local`, credentials placeholders, or local config symlinks.

V1 policy:

- Automatic `create` / `on_add` bootstrap is skipped for symlink children.
- Manual bootstrap on a symlink child requires an explicit warning that writes affect the original checkout.
- Bootstrap profiles are primarily intended for remote clones and git worktree materializations, where the child has an isolated filesystem target.
- UI copy should make "link checkout" and "run bootstrap" feel mutually risky, not casually combinable.

### Trust Policy

User-level profile：

- 用户在 Prowl 里创建或导入。
- 可以自动在 `create` 时执行。
- 可以手动执行。

Repo-local script：

- 默认只能手动执行。
- 如果未来要支持自动执行，必须加入 trust gate。
- trust key 建议包含：
  - repository source URL or normalized local source path
  - script relative path
  - script content hash

只要 hash 变化，就需要重新确认。

### Execution Timing

推荐支持三种时机：

- `create`: repository materialize 成功后立即执行。
- `on_add`: editable settings 新增 repository 后执行。
- `manual`: 用户在 settings 或 child row menu 手动执行。

不建议 V1 支持 `on_open`。原因：

- 打开 workspace 应该快而稳定。
- 自动访问 Documents 或私有目录可能再次触发 TCC。
- 网络、SSH、Homebrew PATH、权限问题会让 app 启动体验变差。

### Execution Environment

每个 bootstrap script 的 cwd 应该是 child repository root。

执行方式：

- 使用 login shell，复用 workspace git command 的 PATH 修复思路。
- 超时默认建议 5 分钟，后续可让 profile 配置。
- 一次只跑一个 repository 的 bootstrap，V1 避免并发导致日志和权限问题复杂化。
- Headless execution needs a real environment injection seam in `ShellClient`.
- Any `process.environment` implementation must merge with `ProcessInfo.processInfo.environment`; replacing it would drop inherited values such as `PATH` and undermine the login-shell fix.
- Timeout should be implemented as a clock-driven race so reducer/client tests can use `TestClock` rather than `Task.sleep`.
- Treat the profile `shell` field as an explicit implementation decision: either ignore it and always use the user's login shell, or define it as the inner shell invoked by that login shell. Do not leave it as decorative metadata.

注入环境变量：

```text
PROWL_WORKSPACE_ROOT
PROWL_REPOSITORY_ROOT
PROWL_REPOSITORY_ID
PROWL_REPOSITORY_NAME
PROWL_REPOSITORY_PATH
PROWL_SOURCE_KIND
PROWL_SOURCE_LOCATION
PROWL_BRANCH_NAME
PROWL_BASE_REF
```

### Logs and Runtime State

不要把每次执行结果写回 `workspace.json`。

建议放在 workspace `.prowl` runtime 文件里：

```text
.prowl/
├─ workspace.json
├─ bootstrap-state.json
└─ bootstrap-runs/
   ├─ Prowl-2026-06-16T10-15-00Z.log
   └─ Zeus-2026-06-16T10-16-00Z.log
```

`bootstrap-state.json` 示例：

```json
{
  "repositories": {
    "Prowl": {
      "last_run_at": "2026-06-16T10:15:00Z",
      "last_status": "succeeded",
      "last_script_id": "sync-prowl-local-config",
      "last_log_path": ".prowl/bootstrap-runs/Prowl-2026-06-16T10-15-00Z.log"
    }
  }
}
```

Logs may contain secrets printed by scripts. V1 should make this explicit:

- Store logs locally under the workspace `.prowl` runtime directory only.
- Do not include logs in generated agent guides.
- Add a clear "Open logs folder" / "Clear logs" path before encouraging repeated use.
- Do not attempt automatic redaction in V1 unless there is a well-defined secret pattern source.

Rollback boundary:

- A required bootstrap failure can fail workspace creation and roll back Prowl-created filesystem entries and git worktree registrations.
- Rollback cannot undo arbitrary script side effects such as files written outside tracked ledger paths, Homebrew installs, network calls, or modifications to a linked source checkout.
- Bootstrap profiles should be documented as idempotent and responsible for their own cleanup.

### UI

Creation prompt V1：

- Repository row 增加 bootstrap profile 选择。
- 默认 `No bootstrap`。
- 选择 profile 后显示一句说明和 `Run on create` toggle。
- Link checkout rows show that automatic bootstrap is disabled.

Workspace settings V1：

- 每个 child repository 显示 bootstrap profile。
- 支持 `Run Now`。
- 显示 last status / last run time。
- 打开最近一次 log。

Child row context menu 可选：

- `Run Bootstrap`
- `Open Bootstrap Log`

## Feature 2: Workspace Agent Guide

### Problem

Workspace root 是 agent cwd，但 agent 不一定知道：

- 每个 child repository 是什么。
- 哪些目录属于任务范围。
- 多 repo 之间怎么分工。
- 应该如何运行 git 命令。
- child repository 自己已有的 `AGENTS.md` / `CLAUDE.md` 是否存在。

这会导致 agent 先花时间探索，或者错误地把 workspace root 当成一个普通 git repository。

### Possible Generation Strategies

#### Strategy A: Metadata-only deterministic generation

只从 `.prowl/workspace.json` 和可检测文件存在性生成。

优点：

- 稳定、可测试、可重复。
- 不依赖网络或 LLM。
- 不会编造项目职责。
- 适合 first version。

缺点：

- 内容质量取决于用户填写的 `description`、`role`、`agent_notes`。

#### Strategy B: Include child instruction files

扫描每个 child repository 的常见 agent 文件：

- `AGENTS.md`
- `CLAUDE.md`
- `.cursor/rules`
- `.github/copilot-instructions.md`

在 workspace guide 里引用它们。

不建议默认全文拼接。理由：

- 多个文件可能互相冲突。
- 文件可能很长。
- 更新其中一个 child 文件后，workspace guide 容易过期。

推荐做法是列链接和提醒：

```md
Additional repo-local instructions:
- `Prowl/AGENTS.md`
- `Zeus/CLAUDE.md`
```

#### Strategy C: LLM-assisted summary

让 Prowl 调用 agent 或外部 LLM 读取 child docs，生成 workspace 级总结。

优点：

- 内容可能更丰富。

问题：

- 需要模型、权限、成本和隐私设计。
- 输出不可完全 deterministic。
- 修改 review 和测试复杂。

不建议 V1 做。

### Recommended V1

采用 metadata-only deterministic generation，加上 child instruction file discovery。

Top-level workspace metadata 新增：

```json
{
  "agent_guide": {
    "enabled": true,
    "outputs": ["AGENTS.md"],
    "include_child_instruction_files": true,
    "extra_notes": ""
  }
}
```

Repository entry 新增：

```json
{
  "name": "Prowl",
  "role": "macOS app and workspace orchestration UI",
  "path": "Prowl",
  "agent_notes": "Use Swift/TCA conventions. Validate with make build-app."
}
```

生成内容示例：

```md
# Workspace Guide

<!-- prowl:workspace-agent-guide:start -->

## Task

Update app UI, API contract, and shared package together.

## Repositories

- `Prowl/`: macOS app and workspace orchestration UI
- `Zeus/`: backend service

## Workflow

- The workspace root is not a git repository.
- Run git commands with `git -C <repository-path> ...`.
- Only modify repositories listed in this guide unless explicitly instructed.

## Repository Notes

### Prowl

Path: `Prowl/`
Role: macOS app and workspace orchestration UI
Notes: Use Swift/TCA conventions. Validate with make build-app.

Additional repo-local instructions:

- `Prowl/AGENTS.md`

<!-- prowl:workspace-agent-guide:end -->
```

### Output Files

Default output:

- `AGENTS.md`

Optional output:

- `CLAUDE.md`

Supporting both matters because different agents look for different filenames. But V1 should default to `AGENTS.md` only unless the user enables `CLAUDE.md`.

### File Update Policy

Prowl should own only a managed block:

```md
<!-- prowl:workspace-agent-guide:start -->
...
<!-- prowl:workspace-agent-guide:end -->
```

Rules:

- If output file does not exist, create it.
- If output file exists with managed block, replace only the block.
- If output file exists without managed block, ask before inserting.
- Never delete user content outside the managed block.

### Regeneration Timing

Supported:

- when workspace is created
- when user clicks `Regenerate`
- after settings save if agent guide fields changed

Not recommended:

- every app launch
- every repository refresh

### Relationship to Bootstrap Profiles

Bootstrap profiles prepare local files.
Agent guide explains workspace structure to agents.

They should be connected but separate:

- Agent guide can mention bootstrap state, for example `Bootstrap: last succeeded`.
- Bootstrap scripts should not modify generated guide directly.
- Regenerating guide should not rerun bootstrap scripts.

## Feature 3: Editable Workspace Settings

### Why Settings Should Wait

onevcat's follow-up request is to make workspace metadata editable.

That should happen after bootstrap profiles and agent guide schema are decided, because settings UI needs to edit:

- title
- description
- task links
- repository role
- repository path
- bootstrap profile
- bootstrap run policy
- agent notes
- agent guide outputs
- add/remove repositories

If settings is built only around the current read-only metadata fields, it will need significant reshaping immediately.

### Settings UI Structure

Recommended tabs or sections:

#### Overview

- Title
- Description
- Task links
- Agent guide enabled
- Agent guide outputs
- Preview generated guide
- Regenerate guide

#### Repositories

For each repository:

- Name
- Role
- Path inside workspace
- Source kind / source location as read-only provenance unless changing source is explicitly supported
- Branch/base ref as read-only provenance unless rematerialization is supported
- Agent notes
- Bootstrap profile
- Run bootstrap on create / on add
- Last bootstrap status
- Run bootstrap now

#### Advanced

- Open `.prowl/workspace.json`
- Validate metadata
- Repair/regenerate agent guide
- Show bootstrap logs folder

### Add/Remove Repository

Adding a repository from settings should reuse the existing creation materialization path as much as possible.

This is heavier than an ordinary settings edit. Today workspace creation writes `workspace.json` once, and no runtime path patches it later. `ProjectWorkspace.materialize` is private and tied to creation-time ledger/rollback. Supporting add/remove after creation needs a new reusable materialization service plus a metadata patch writer.

Flow:

1. User adds a repository row.
2. Prowl validates source/path/checkout.
3. Prowl materializes it into the existing workspace root.
4. Prowl patches `workspace.json`.
5. If configured, Prowl runs bootstrap with `run_on: on_add`.
6. If agent guide is enabled, Prowl regenerates the guide.
7. Repositories reload and child rows refresh.

Removing a repository:

1. Show whether the child is a symlink, remote clone, or git worktree.
2. Ask whether to remove files/worktree registration.
3. Patch `workspace.json`.
4. Regenerate agent guide if enabled.

Minimum repository count:

- Creation should keep the current `>= 2 repositories` validation.
- Editable settings should not allow saving a workspace with fewer than 2 child repositories until there is a separate "convert workspace to plain repository" or "archive workspace" flow.
- Removing the second-to-last child should be disabled or require removing the whole workspace.

### Persistence Requirement: Preserve Unknown Fields

Once UI can save `workspace.json`, a plain `Codable` round trip can accidentally delete unknown fields.

That is acceptable for initial creation, but risky for editing.

Recommended approach:

- Keep domain model Codable for load and validation.
- Add a metadata patch writer for settings saves.
- Patch only fields Prowl owns.
- Preserve unknown top-level and repository-level keys.

This matters because:

- users may hand-edit fields before UI supports them
- future versions may add fields
- workspace metadata should be resilient across branch versions

## Proposed Schema Additions

### Top-level

```json
{
  "agent_guide": {
    "enabled": true,
    "outputs": ["AGENTS.md"],
    "include_child_instruction_files": true,
    "extra_notes": ""
  }
}
```

### Repository Entry

```json
{
  "agent_notes": "Main macOS app and workspace orchestration UI.",
  "bootstrap": {
    "script_kind": "user_profile",
    "script_id": "sync-prowl-local-config",
    "run_on": ["create", "on_add", "manual"],
    "required": false
  }
}
```

Adding optional `agent_guide`, `agent_notes`, and `bootstrap` fields is additive and should keep `schema_version` at `prowl.workspace.v1`.

### User-level Bootstrap Profile

Storage should follow existing Prowl app storage conventions:

- Add a dedicated handwritten `SharedKey`.
- Persist to a user-level JSON file under `~/.prowl/`, for example `~/.prowl/bootstrap-profiles.json`.
- Reuse `SettingsFilePersistence` style dependencies for testable load/save behavior.

Conceptually:

```json
{
  "id": "sync-prowl-local-config",
  "name": "Sync Prowl Local Config",
  "description": "Copies local ignored config files into a materialized Prowl checkout.",
  "shell": "/bin/zsh",
  "script": "cp \"$HOME/.config/prowl/local.env\" \"$PROWL_REPOSITORY_ROOT/.env.local\"",
  "timeout_seconds": 300
}
```

The profile is user-owned local state, not workspace metadata.

## Implementation Order

### PR 1: Bootstrap Foundation

Scope:

- Add bootstrap schema to repository entry.
- Add user-level bootstrap profile model and `~/.prowl/bootstrap-profiles.json` persistence.
- Add a `ShellClient` execution path that can inject merged environment variables.
- Add a clock-driven timeout wrapper for headless bootstrap execution.
- Execute bootstrap after repository materialization for `run_on: create`.
- Skip automatic bootstrap for symlink children.
- Add manual run entry point.
- Write bootstrap logs and bootstrap state.
- Add focused tests for execution order, failure handling, env, timeout, symlink skip, and log/state behavior.

Important behavior:

- A required bootstrap failure should fail workspace creation and trigger rollback of Prowl-created materialization artifacts only.
- A non-required bootstrap failure should keep workspace creation successful but surface a warning.
- Bootstrap execution must not dirty `workspace.json` with runtime result data.
- Existing terminal-injected `RepositorySettings.setupScript` remains separate.

### PR 2: Agent Guide Generation

Scope:

- Add `agent_guide` schema.
- Add repository `agent_notes`.
- Generate `AGENTS.md` with managed block.
- Discover child instruction files and reference them.
- Regenerate on creation and manual command.
- Add tests for deterministic output and managed block replacement.

### PR 3: Editable Workspace Metadata

Scope:

- Make current read-only workspace settings editable.
- Support overview fields, repository role/agent notes/bootstrap fields, and agent guide controls.
- Use patch writer that preserves unknown metadata fields.
- Regenerate agent guide after relevant settings changes.
- Decide whether `RepositorySettingsView` becomes the editor and `WorkspaceDetailView` remains a read-only overview, or whether both route to the same editor.

### PR 4: Add/Remove Workspace Repositories

Scope:

- Extract creation-time materialization into a reusable add-one-repository path with ledger/rollback.
- Patch `workspace.json` after successful add/remove while preserving unknown fields.
- Enforce the minimum child repository count.
- Trigger bootstrap for newly added repositories when configured.
- Regenerate agent guide after repository list changes.

## Validation Plan

Bootstrap profiles:

- Unit test schema decoding with old metadata missing bootstrap fields.
- Unit test user profile resolution.
- Unit test `required: true` failure rolls back Prowl-created materialization artifacts.
- Unit test `required: false` failure records warning and keeps workspace.
- Integration-style test that script cwd and env are correct.
- Unit test timeout using `TestClock`.
- Unit test automatic bootstrap is skipped for symlink children.

Agent guide:

- Unit test generated Markdown from fixed metadata.
- Unit test existing file with managed block is updated in place.
- Unit test existing file without block requires confirmation path.
- Unit test child instruction file discovery.

Editable settings:

- Unit test patch writer preserves unknown keys.
- Reducer test for editing title/description/task links.
- Reducer test for editing repository role/agent notes/bootstrap fields.

Add/remove repositories:

- Reducer test for adding a repository and running bootstrap.
- Reducer test for removing a repository and regenerating guide.
- Unit test removing repositories cannot reduce a workspace below 2 children.

Manual checks:

- Create workspace with local repository bootstrap profile.
- Create workspace with remote clone and user profile bootstrap.
- Create workspace with link checkout and confirm automatic bootstrap is skipped.
- Confirm repo-local script is not automatically executed without trust.
- Regenerate `AGENTS.md` and verify user content outside managed block is preserved.

## Open Questions

- Should Prowl support importing/exporting bootstrap profiles so a workspace can be shared across machines more easily?
- Should bootstrap profiles support file copy templates directly, or only arbitrary shell scripts?
- Should `CLAUDE.md` be generated by default for Claude-heavy workflows, or remain opt-in?
- Should bootstrap state live in workspace `.prowl` only, or also be surfaced in app storage for faster sidebar/status display?
- Should editable settings allow changing source/checkout fields after materialization, or should those remain read-only until a rematerialization flow exists?
- Should headless bootstrap eventually converge with the visible terminal-injected `setupScript`, or should the product keep them as separate workflows?

## Recommendation

Proceed in this order:

1. Add bootstrap profile support using user-level scripts as the primary path.
2. Add deterministic workspace agent guide generation.
3. Build editable workspace metadata on top of the finalized bootstrap and agent guide schema.
4. Add repository add/remove flows as their own PR after the metadata patch writer and reusable materialization path exist.

This keeps the current workspace model intact while adding the two missing layers:

- reproducible local preparation for each child repository
- explicit workspace-level context for agents

It also avoids putting private machine-specific scripts into shared workspace metadata, while still leaving room for trusted repo-local scripts later.
