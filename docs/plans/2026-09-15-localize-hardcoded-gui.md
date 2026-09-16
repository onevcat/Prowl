# 剩余硬编码 GUI 简体中文化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task after the user approves the proposed behavior.

**Goal:** 把仍以普通 `String` 交给 UI、因而进不了现有 catalog 的 Prowl 自有 GUI 文案改为可提取 API，补进 `Localizable.xcstrings` 的 `zh-Hans`，使中文冷启动覆盖菜单、警告、Toast、设置枚举、命令面板和快捷键显示名。

**Architecture:** 不改启动语言桥接、不改 `AppLanguage` 持久化。显示边界一律 `String(localized:)` / `TextState(String(localized:))`；catalog 继续直接改 JSON，不走 LocalizationPlanner MCP。`CommandID`、Ghostty action 身份、CLI 英文、用户数据保持原样。语言仍是下次启动生效。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TCA `TextState`、Xcode String Catalog（`.xcstrings`）、Swift Testing。

**库存：** `docs/plans/2026-09-15-localization-hardcoded-remainder.md`  
**主计划合同：** `docs/plans/2026-09-10-language-settings.md`（术语、CLI 英文、帮助 chrome/prompt、下次启动生效）

**已落地，不要重做：**

| 项 | 证据 |
|---|---|
| 启动桥接 + 设置 Picker | `3128edbe` |
| catalog 891 keys / 883 zh-Hans | `f3872292` |
| InfoPlist 权限说明 | 同上 |

**并行：** Task 1 必须先做。之后 Task 2 / 3 / 4 / 5 文件几乎不重叠，可并行（同一文件禁止两人改）。Task 5 的 AppShortcuts 显示名应先于或并入 Task 6 的 `helpText(title:)`。Task 7 依赖 2–6 的新 key。Task 8 最后。

---

## 术语与禁区（全任务强制）

- 工作树 (Worktree)、工作区、仓库、分支、配置档案 (Profile)。Agent / Prowl / Ghostty / Claude / Codex / GitHub 保留英文，禁止译成「代理」。
- 保留 `%@`、`%lld`、`⌘↩`、Markdown 链接。
- **不译：** `ProwlCLI/`、`CLIService/Shared/`、Ghostty `action`/`title` 用作 ID、用户名/路径、git/gh `error.message`、Sparkle 标准 UI、`CommandID` raw value、产品名 Prowl。
- 命令面板：英文 keywords 保留，并加中文关键词；显示 title 可译。
- 帮助：chrome = 本次启动应用语言；prompt = 系统首选语言（`Locale.preferredLanguages`，去掉 Prowl 派生 `AppleLanguages`）。

提取后合并 `.stringsdata` 的方法（Task 7 用）：

```bash
# 构建后
python3 - <<'PY'
# 读取 DerivedData .../Objects-normal/arm64/*.stringsdata
# tables.Localizable[].key 并入 supacode/Localizable.xcstrings
# 已有 zh-Hans 的 key 不要覆盖
PY
```

新 key 写入：

```json
"English key": {
  "localizations": {
    "zh-Hans": {
      "stringUnit": { "state": "translated", "value": "中文" }
    }
  }
}
```

---

## Task 1: 删除 G1a DEBUG 探针

**Files:**

- Modify: `supacode/Features/Settings/Views/AppearanceSettingsView.swift`（`#if DEBUG` Section）
- Modify: `supacode/App/WindowTitle.swift`（`case nil` 探针）
- Modify: `supacode/Infrastructure/Ghostty/GhosttySurfaceView+Keyboard.swift`（菜单探针）
- Modify: `supacode/Features/Repositories/Views/CloneRepositoryView.swift`（`panel.message`）
- Modify: `supacode/Localizable.xcstrings`（删 4 个 `G1a * probe` key）
- Modify: `supacodeTests/WindowTitleTests.swift`（`computeUsesAppTitleWithoutSelection` 恢复期望 `"Prowl"`）

**步骤：**

1. 去掉全部 `#if DEBUG` 探针代码，无选中标题恢复 `return appName`。
2. 从 catalog 删除 4 个 G1a key。
3. 跑 `WindowTitleTests`：`computeUsesAppTitleWithoutSelection` 期望 `"Prowl"`。
4. Commit: `chore: remove disposable G1a localization probes`

---

## Task 2: AppKit 菜单、Alert、文件面板

**Files:**

- Modify: `supacode/Infrastructure/Ghostty/GhosttySurfaceView+Keyboard.swift`（Copy/Paste/Split */Reset Terminal/Change Title...）
- Modify: `supacode/Clients/Updates/UpdaterClient.swift:200-206`
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState+Surfaces.swift`（关闭确认 Cancel；改标题 alert）
- Modify: `supacode/Features/Repositories/Views/WorkspaceCreationPromptView.swift`（`prompt`/`message`）
- Modify: `supacode/Features/RepositorySettings/Views/RepositoryAppearancePickerView.swift:437-438`

**步骤：**

1. 每个用户可见字面量改为 `String(localized: "English key")`，key 与现有英文一致以便复用 catalog。
2. 关闭确认若 `messageText`/`confirmButtonTitle` 来自内部英文常量，那些常量改为 `String(localized:)`。
3. `make build-app`；把新 `.stringsdata` key 并入 catalog 并译 `zh-Hans`（本任务产生的 key 本任务译完）。
4. 抽查：中文冷启动右键菜单、更新确认（只展示取消）、Clone/选图标面板 message。
5. Commit: `feat: localize AppKit menus, alerts, and file panels`

可与 Task 3、4 并行。

---

## Task 3: TextState 警告与 Toast

**Files:**

- Modify: `supacode/Features/App/Reducer/AppFeature.swift`（退出确认 734–744；CLI/workflow/skill toast）
- Modify: `supacode/Features/App/Reducer/AppFeature+AgentProfiles.swift`
- Modify: `supacode/Features/App/Reducer/AppFeature+Handoff.swift`
- Modify: `supacode/Features/App/Reducer/AppFeature+TerminalEvents.swift`
- Modify: `supacode/Features/App/Reducer/AppFeature+WorkflowStart.swift`
- Modify: `supacode/Features/Settings/Reducer/SettingsFeature.swift`（CLI 安装 alert、通知权限 alert）
- Modify: `supacode/Features/Settings/Reducer/AgentProfileEditorFeature.swift`
- Modify: `supacode/Features/Settings/Reducer/AgentSkillsFeature.swift`
- Modify: `supacode/Features/Settings/Reducer/WorkflowSettingsDetailFeature.swift`
- Modify: `supacode/Features/Settings/Reducer/WorkflowsSettingsFeature.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature+RepositoryLoading.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature+RepositoryManagement.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorktreeLifecycle.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature+GithubIntegration.swift`
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature+WorkspaceCreation.swift`
- Test: 若现有测试断言英文 `TextState`/`toast` 原文，改为断言 localized 结果或稳定 ID，禁止把测试钉死在新中文上。

**步骤：**

1. 静态句：`TextState(String(localized: "Quit Prowl?"))`。插值：`String(localized: "The prowl command is now available at \(path)")`（编译器生成带 specifier 的 key）。
2. `showToast(.success(String(localized: "…")))` 同理。
3. `TextState(error.message)` / `showToast(.warning(message))` 若 message 来自 git/gh：**不要**包一层按英文匹配的翻译。
4. 先改计划验收三项：退出确认、Settings CLI alert、Updater（Updater 在 Task 2）。再铺开其余 `TextState("` grep 命中（库存约 50）和 toast（约 29）。
5. 跑 `SettingsFeatureTests`、相关 Repositories/AppFeature 测试；修被英文原文钉死的断言。
6. 构建、合并新 catalog key、译 `zh-Hans`。
7. Commit: `feat: localize alerts and toasts`

可与 Task 2、4 并行（不要和别人同时改 `SettingsFeature.swift`）。

---

## Task 4: 设置枚举与计算脚注

**Files:**

- Modify: `supacode/Features/Settings/Models/AppearanceMode.swift`
- Modify: `supacode/Features/Settings/Models/WindowTintMode.swift`
- Modify: `supacode/Features/Settings/Models/ShelfSpineTintFallback.swift`
- Modify: `supacode/Features/Settings/Models/DefaultViewMode.swift`
- Modify: `supacode/Features/Settings/Models/CanvasDefaultLayout.swift`
- Modify: `supacode/Features/Settings/Models/DockBounceMode.swift`
- Modify: `supacode/Features/Settings/Models/PullRequestMergeStrategy.swift`
- Modify: `supacode/Features/Settings/Models/MergedWorktreeAction.swift`
- Modify: `supacode/Features/Settings/Models/AutoDeletePeriod.swift`
- Modify: `supacode/Features/Settings/Models/NotificationSound.swift`（Never / Prowl Classic；系统音名不译）
- Modify: `supacode/Features/Settings/Models/UserRepositorySettings.swift`（execution/split 方向 title）
- Modify: `supacode/Features/Settings/Views/AppearanceSettingsView.swift`（`tintFootnote` / `shelfSpineTintFootnote`）
- Modify: `supacode/Domain/OpenWorktreeAction.swift`（`title`）
- Modify: `supacode/Domain/ExternalDiffTool.swift`（Built-in / Hunk；外部工具名不译）
- Modify: `supacode/Domain/RepositoryColorChoice.swift`
- Skip: `AppLanguage.title`（已是各语言本名）
- Skip: `DetectedAgent.displayName`、用户 Profile 名、仓库名

**步骤：**

1. `var title: String { "System" }` 改为 `String(localized: "System")`。说明句整句 localized，不要拼接英文片段。
2. 测试若比较 `"System"` 等显示名，改为比较 rawValue 或 localized 结果。
3. 构建、合并、翻译新 key。
4. Commit: `feat: localize settings enum titles`

可与 Task 2、3 并行。

---

## Task 5: AppShortcuts 显示名与命令面板

**Files:**

- Modify: `supacode/App/AppShortcuts.swift`（~75 个 `title:` 的**显示**路径；`id:` 不动）
- Modify: `supacode/Features/CommandPalette/Reducer/CommandPaletteFeature.swift`
- Modify: `supacode/Features/CommandPalette/Views/CommandPaletteOverlayView.swift`（`Recent` / `Suggested`）
- Modify: `supacode/Features/CommandPalette/Reducer/CommandPaletteSupport.swift`（Ghostty 行：显示 localized，`id` 仍用原始 action|title）

**步骤：**

1. 增加显示用 API，例如 `var localizedTitle: String { String(localized: String.LocalizationValue(title)) }`，设置页和面板走它；存储/ID 仍用英文 `title` 字段（若该字段参与 identity，保持英文）。
2. 命令面板硬编码 `"Open Settings"` 等改为 `String(localized: "Open Settings")`。
3. keywords：保留英文，追加中文（设置、工作树、仓库、命令面板等）。
4. Ghostty：`CommandPaletteItem.title` 可译；`CommandPaletteItemID.ghosttyCommand` 继续用未译 identity。
5. 自定义命令 `resolvedTitle` 不译。
6. 跑命令面板测试；不要把 CLI 输出改成中文。
7. 构建、合并、翻译。
8. Commit: `feat: localize command palette and shortcut titles`

在 Task 6 之前完成，或与 Task 6 同一人做。

---

## Task 6: helpText 与 WindowTitle

**Files:**

- Modify: `supacode/App/WindowTitle.swift`（`archivedWorktreesTitle`、`canvasTitle`；`appName` 保持 `"Prowl"`）
- Test: `supacodeTests/WindowTitleTests.swift`（Canvas/Archive 期望改为 localized）
- Modify: `supacode/App/supacodeApp.swift` `helpText(title:commandID:)`
- Modify: `supacode/Commands/SidebarCommands.swift`、`WorktreeCommands.swift`、`UpdateCommands.swift` 的 `helpText`
- Modify: `supacode/App/AppShortcuts.swift` `helpText(title:commandID:in:)` 若存在

**步骤：**

1. `helpText` 在拼接快捷键前对 `title` 做 `String(localized: String.LocalizationValue(title))`，这样调用处已有的英文 title 字面量会提取。
2. `Button("Toggle Left Sidebar")` 已提取则不动；只修 `.help(helpText(title: "…"))` 这条 String 路径。
3. WindowTitle 两常量 localized；`format` 里的 ` · ` 可保持。
4. 测试更新后跑 `WindowTitleTests`。
5. Commit: `feat: localize window titles and menu help`

---

## Task 7: Ask Agent Help 双语言合同

**Files:**

- Modify: `supacode/Features/Help/AskAgentHelpPrompt.swift`
- Modify: `supacode/Features/Help/AskAgentHelpView.swift` 及全部调用方（LSP `references`）
- Modify: `WorkflowAuthoringPrompt.swift` 若同源
- 不留旧的单 locale 接口。

**步骤：**

1. 拆两个 locale：`appLocale`（Bundle/启动快照）生成 chrome；`systemLocale`（`Locale.preferredLanguages` 去掉 Prowl 派生 AppleLanguages）生成 prompt。
2. 调用方传入启动快照对应 locale，禁止再用已被桥接污染的 `Locale.current` 生成 prompt。
3. 已有简中/繁中/日文 prompt 模板保留；chrome 走 catalog 亦可。
4. 测试：英文应用 + 中文系统 → 标题英文、prompt 中文；反向亦然。
5. Commit: `feat: split Ask Agent Help chrome and prompt locales`

---

## Task 8: 再提取、补译、验收、文档

**Files:**

- Modify: `supacode/Localizable.xcstrings`
- Modify: `docs/components/settings.md`
- Modify: `docs/reference/settings-fields.md`
- Modify: `CHANGELOG.md`

**步骤：**

1. `make build-app`，合并全部新 `.stringsdata` key；已有 `zh-Hans` 不覆盖。
2. 未译 key 分批（≤30）译完；`python3 -m json.tool` 校验；插值与英文 key 一致。
3. 针对性测试：

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination 'platform=macOS' \
  -only-testing:supacodeTests/AppLanguageTests \
  -only-testing:supacodeTests/SettingsFilePersistenceTests \
  -only-testing:supacodeTests/SettingsFeatureTests \
  -only-testing:supacodeTests/WindowTitleTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  -skipMacroValidation
```

检查实际执行数，拒绝零匹配。动过 CLI 再跑 `make build-cli` / `make test-cli-smoke`。

4. 中文冷启动抽查：设置枚举、退出确认、终端右键、命令面板、更新确认（只取消）。
5. 文档：语言入口、下次启动、`appLanguage` 字段、CHANGELOG。
6. Commit: `feat: finish remaining GUI Chinese translations` 与 `docs: document app language setting`

---

## 完成定义

中文冷启动下，Prowl 自有菜单、警告、Toast、设置选项、命令面板显示名、快捷键 help 为简体中文；英文回退仍在；CLI / 命令 ID / 用户数据 / 第三方输出仍为原文；帮助 prompt 跟系统语言不跟应用语言。不能只凭 catalog 行数宣称完成。
