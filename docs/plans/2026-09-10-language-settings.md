# 语言设置与简体中文化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task after the user approves the proposed behavior.

**Goal:** 在“设置 → 通用”增加应用语言选择，提供跟随系统、简体中文和 English，并完成 Prowl 自有 GUI 的中英文支持。

**Architecture:** 沿用 `GlobalSettings` → `@Shared(.settingsFile)` → `SettingsFeature` 的现有配置链路。翻译资源是 Apple String Catalog（`.xcstrings` JSON），由实施者直接读写，不依赖 LocalizationPlanner / StringCatalogRead / StringCatalogContext / StringCatalogEdit。语言选择保存后于下一次启动统一生效；不重建终端状态，不自动结束应用。启动语言桥接先做实际应用验证，不假定修改 SwiftUI locale 或在 App.init 写偏好就能覆盖所有原生 UI。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TCA、Sharing、Xcode String Catalog（`.xcstrings`）、Swift Testing。

**Status:** 2026-09-15 按用户指示改为直接编辑 `.xcstrings`，取消原 G0 MCP 工具门槛。默认范围为简体中文，不包含完整繁体翻译、CLI 帮助翻译和整套文档翻译。

**已落地（不要重做）：**

| 项 | 证据 |
|---|---|
| Task 1.1–1.2 英文构建基线（Xcode 27） | `5b86e426` |
| Task 2 语言模型 / 持久化 / `AppleLanguages` 桥接 | `54b51e37`：`AppLanguage.swift`、`AppLanguageBridge.swift`、`GlobalSettings.appLanguage`、`SettingsFeature` 快照与保存失败回滚 |
| 工程语言与空 catalog | `knownRegions` 含 `zh-Hans`；`supacode/Localizable.xcstrings`、`supacode/InfoPlist.xcstrings` 已创建（`sourceLanguage: en`，`strings` 仍为空） |

`supacode/` 是 `PBXFileSystemSynchronizedRootGroup`，catalog 放在该目录即进 `supacode` target，不必再往 pbxproj 加文件引用。pbxproj 只需保留 `knownRegions` 的 `zh-Hans`。

下一步从 Task 1.3 / G1a 继续，不要重写 Task 2。

---

## 设计决策

### 设置交互

- 入口：`Settings → General`，在现有通用设置 Form 顶部增加语言 Section，不增加侧边栏页面。文件：`supacode/Features/Settings/Views/AppearanceSettingsView.swift`。
- 标签使用“语言 / Language”，便于误选语言后找回。
- 选项：跟随系统（System Default）、简体中文、English；语言名称使用本语言形式（已在 `AppLanguage.title`）。
- 新配置默认跟随系统；此处“系统”包括 macOS 为 Prowl 设置的单应用语言，其次才是系统全局首选语言。使用平台支持语言协商，没有兼容翻译时回退英文。
- 选择后保存，不立即改变当前进程的有效语言。提示“下次启动 Prowl 时生效；退出应用可能中断正在运行的终端任务”。
- 不添加自动重启、不强制退出，不承诺恢复仍在运行的进程。
- 运行期间区分“已保存的语言偏好”和“本次启动的有效语言”。待生效提示按解析后的语言比较，而不是比较设置枚举；例如跟随系统已显示中文，改成显式中文不应提示必须重启才能显示中文。`SettingsFeature.State.languageChangePending` 已实现该比较。
- 所有窗口使用同一本次启动语言；新开的设置、Diff、帮助及 Agent Island 窗口不能提前采用待生效语言。

### 方案比较

1. **推荐：应用内选择，下一次启动生效。** 覆盖 SwiftUI、AppKit 和启动时生成的文案更容易保持一致；代价是不能即时预览。
2. **不采用：完整运行时热切换。** 需要重建菜单、更新已存在的弹窗及缓存字符串，不能只在根视图设置 locale；增加终端状态被重建的风险。
3. **不采用：仅引导用户到 macOS 单应用语言设置。** 实现最少，但不能满足直接在 Prowl 设置里选择语言的目标。

### 持久化与系统边界

Task 2 已实现。合同如下，后续改动不得削弱：

- `AppLanguage` 稳定存储值为 `system`、`zh-Hans`、`en`，显示文字不能作为存储值。
- `GlobalSettings.appLanguage` 为应用内配置的唯一事实来源。
- 缺失字段或不认识的语言代码回退 `system`，不因一个未知语言代码丢弃其他设置。
- 使用原有 `~/.prowl/settings.json`，不为这一项新建配置文件。
- 应用域 `AppleLanguages` 仅作为从配置派生的系统桥接值；不写全局域、不改变其他应用或终端环境变量。Debug/Release 域分别管理。
- 优先级固定为：显式命令行 `-AppleLanguages`（仅本次启动） > `GlobalSettings.appLanguage` 的显式选择 > 非 Prowl 管理的 macOS 单应用语言 > 系统全局首选语言 > 英文回退。命令行值不反写配置。
- `AppLanguageBridge` 记录原始非托管覆盖（含“原本不存在”）及最近一次 Prowl 写入值。回到跟随系统时，只有当前域值仍等于最近一次 Prowl 写入值才恢复/删除。外部改写不覆盖。读持久域，避免把命令行 `-AppleLanguages` 误当持久值。
- 配置先成功保存，才能更新派生桥接；失败回滚且不碰桥接。
- 外部编辑 settings.json 仅支持应用完全退出后的冷启动读取。不新增文件热重载。
- 不使用 Bundle method swizzling，不通过 `.id(language)` 重建整个应用，不以热改进程 locale 冒充完整本地化。

### 语言解析与启动快照合同

- `AppLanguage`（system/en/zh-Hans）与 `ResolvedAppLanguage`（en/zh-Hans）已区分。
- 解析走 `Bundle.preferredLocalizations(from:forPreferences:)`，不手写 “zh 前缀都算简体”。
- 启动桥接后、首次创建本地化菜单/状态前，从实际 Bundle 协商结果捕获不可变 `effectiveLanguageAtLaunch`；不能只把预期值当成实际结果。Task 3 负责把快照从 `supacodeApp` 传入 Settings。
- `.settingsLoaded` 只刷新持久字段，不能覆盖快照。所有 SwiftUI scene 及 AppKit 承载窗口使用同一快照。
- 语言设置只控制界面语言，不擅自改变用户地区、日历、时区、数值格式或子进程 LANG/LC_*。

### 翻译资源合同（替代原 G0）

汉化的唯一资源格式是 Apple String Catalog JSON：

- `supacode/Localizable.xcstrings`：应用自有 GUI。
- `supacode/InfoPlist.xcstrings`：`Info.plist` 权限用途说明等。

**直接读写这两个文件。** 禁止把 LocalizationPlanner、StringCatalogRead、StringCatalogContext、StringCatalogEdit、`translation-coordinator`、`translation` skill 当成实施门槛。那些 skill 要求 MCP 且禁止手写 catalog；本计划明确覆盖该禁令。没有 Xcode MCP 不得暂停。

提取与翻译流程：

1. 源码使用 `String(localized:)`、`Text("…")`、`LocalizedStringResource`、`String(localized:defaultValue:)` 等可提取 API。普通 `String`、`NSAlert`、`NSMenuItem`、`TextState` 在显示边界改成上述 API，才能进 catalog。
2. `SWIFT_EMIT_LOC_STRINGS = YES`、`LOCALIZATION_PREFERS_STRING_CATALOGS = YES` 已开。`make build-app` 后编译器把 key 写进 `.xcstrings`。
3. 构建后 `Read` catalog：每个用户可见 key 必须出现在 `strings` 下。空 `strings: {}` 表示尚未提取或源码仍是硬编码。
4. 对每个待译 key，在 `localizations["zh-Hans"]` 写入：

```json
"Some English key": {
  "localizations": {
    "zh-Hans": {
      "stringUnit": {
        "state": "translated",
        "value": "对应中文"
      }
    }
  }
}
```

5. 复数/变体按 catalog 已有 `variations` 结构补 `zh-Hans`，保留 `%@`、`%lld`、`%1$@` 等插值原样。
6. `state` 用 `translated`。不要留 `new` / `needs_review` / 空 `value`。明确不翻译的 key 标 `"shouldTranslate": false` 并写依据。
7. 源语言是英文：key 本身就是英文原文时不必再写 `en` localization。不要改 `sourceLanguage`。
8. 手写 JSON 必须仍是合法 xcstrings（`version` 保持 `"1.3"` 除非 Xcode 自己升版）。改完用 `python3 -m json.tool` 或等价检查解析。
9. 原型阶段可向 catalog 写入可丢弃 key；G1a 通过后删除这些 key，避免混进 Task 4。

Info.plist：权限键（`NSAppleEventsUsageDescription` 等）进 `InfoPlist.xcstrings`，不要复制进 `Localizable.xcstrings`。`SUFeedURL`、DSN、密钥、UTI identifier 不翻译。

---

## Task 1: 建立构建基线并验证启动语言机制

**涉及文件与入口：**

- `Makefile`（使用现有构建目标）。
- `supacode/App/supacodeApp.swift`。
- `supacode/Localizable.xcstrings`（可丢弃原型 key）。
- `supacode.xcodeproj/project.pbxproj`（已含 `zh-Hans`，不要无关重排）。

**步骤：**

1. ~~初始化子模块 / GhosttyKit。~~ 已完成。
2. ~~`make build-app` 英文基线。~~ 已完成（`5b86e426`，Xcode 27）。
3. 向 `Localizable.xcstrings` 写入 4 个可丢弃原型 key（SwiftUI 标签、AppKit 菜单、动态标题、文件面板按钮），补 `zh-Hans` 译文。源码用 `String(localized:)` 引用这些 key。`make build-app`。
4. 分别用英文 / 简体中文冷启动 Debug 应用（命令行 `-AppleLanguages (en)` 与 `-AppleLanguages (zh-Hans)`，或隔离的应用域）。确认四类文案随启动语言变化，且只需一次正常冷启动。
5. 不能假定 `App.init` 早于 Foundation/AppKit 语言缓存。若现有入口过晚，设计最小启动引导入口（Task 3 落地），验证一次启动即生效。Debug/Release 域隔离，不改用户全局域。
6. G1a：早期桥接 / 参数域 / 实际 Bundle 协商、仅一次正常冷启动。覆盖手工 `NSHostingWindow`、新窗口、启动缓存标题。局部 SwiftUI 生效不算通过，不得自动重启补救。

**验收：** 下一次启动的应用自有文案语言一致；没有修改系统全局语言，也没有自动退出或重建正在运行的终端。系统权限弹窗和第三方框架语言单独记录，不承诺全部强制控制。G1a 通过后删掉原型 key 与临时源码。

G1a 通过后进入 Task 3（Task 2 已完成）。真实设置切换、持久化、所有权恢复、保存失败在 Task 3 的 G1b 验收。

## Task 2: 增加语言设置模型及持久化

**状态：已完成（`54b51e37`）。不要重做。**

已有文件：

- `supacode/Features/Settings/Models/AppLanguage.swift`
- `supacode/Features/Settings/BusinessLogic/AppLanguageBridge.swift`
- `supacode/Features/Settings/Models/GlobalSettings.swift`
- `supacode/Features/Settings/Reducer/SettingsFeature.swift`
- `supacodeTests/AppLanguageTests.swift`
- `supacodeTests/SettingsFilePersistenceTests.swift`
- `supacodeTests/SettingsFeatureTests.swift`

若后续改这些文件，保持所有权 / 保存失败顺序 / 启动快照不被 `.settingsLoaded` 覆盖。针对性测试：`AppLanguageTests`、`SettingsFilePersistenceTests`、`SettingsFeatureTests`，拒绝零匹配。

## Task 3: 在通用设置增加语言控件并接入启动

**文件：**

- 修改 `supacode/Features/Settings/Views/AppearanceSettingsView.swift`（General Form 顶部加语言 Section）。
- 修改 `supacode/Features/Settings/Reducer/SettingsFeature.swift`（若启动接入还缺动作）。
- 修改 `supacode/App/supacodeApp.swift`：启动时同步桥接、捕获 `effectiveLanguageAtLaunch`、传入 Settings。
- 仅当 Task 1 证明需要把桥接从 App.init 再提前时，新增 `supacode/Features/Settings/BusinessLogic/AppLanguageBootstrap.swift`；只承载语言解析/系统桥接。

**步骤：**

1. Form 顶部标准 `Picker`，标签 “语言 / Language”，选项用 `AppLanguage.title`。脚注说明下次启动生效、退出可能中断终端任务。沿用 `.formStyle(.grouped)`。
2. 按 G1a 验证过的机制在创建菜单 / 快捷键标题 / 缓存文案之前应用启动语言。
3. 跟随系统时用去掉 Prowl 派生覆盖后的平台语言列表协商。
4. UI 保持本次运行语言，显示已保存选项和 `languageChangePending` 提示；不提供自动重启按钮。
5. 检查设置窗口关闭重开、多窗口、新建原生弹窗。

**验收（G1b）：** 真实设置链路：改设置不终止任务、保存失败不误报成功、仅一次正常冷启动生效、恢复系统条件还原原覆盖、命令行临时覆盖不反写、完全退出后外改 JSON 正确读取。必须通过 G1b 才进入 Task 4。

## Task 4: 接入翻译资源并迁移所有应用自有 GUI 文案

**工程资源（已存在，补内容，不重建文件）：**

- `supacode/Localizable.xcstrings`
- `supacode/InfoPlist.xcstrings`
- `supacode.xcodeproj/project.pbxproj` 的 `knownRegions` 已含 `zh-Hans`

直接编辑上述 `.xcstrings`。不要调用 LocalizationPlanner / StringCatalog\* / translation-coordinator。

**代码范围：**

- `supacode/Features/Settings/`、`supacode/Features/Repositories/`。
- `supacode/Commands/`、整个 `supacode/App/`、`supacode/Features/App/`；显式包含 `ContentView.swift` 的 Run Script 弹窗和 `AppFeature.swift` 的退出确认。
- `supacode/Features/CommandPalette/`。
- `supacode/Features/Terminal/`、`supacode/Infrastructure/Ghostty/` 的 Prowl 自有菜单和提示。
- `supacode/Features/Workflow/`、`ActiveAgents/`、`Canvas/`、`Shelf/`、`DiffView/`、`HandoffHud/`、`Help/`。
- `supacode/Info.plist` 权限用途说明，以及 Clients/Domain/Support 中所有最终显示到 GUI 的 Prowl 自有文案；显式包含 `Clients/Updates/UpdaterClient.swift` 的安装并重启 NSAlert。排除日志、协议和外部输出。
- 上述目录是实施分组，不是范围白名单：构建提取后对整个 `supacode/` 用户可达文案补漏，分类为本地化、用户数据、协议/代码示例、第三方原始输出或仅调试，并记录依据。

**步骤：**

1. 把硬编码用户可见字符串改为可提取 API，然后 `make build-app`，让编译器填充 catalog。统计以构建后 catalog 的 key 为准，不以事先 UI 调用次数为准。遗漏扫描覆盖普通 `String`、`TextState`、`NSAlert`、`NSMenuItem`、格式化及无障碍文案。
2. 术语表（全表强制）：工作树 = Worktree 可保留或译“工作树”（UI 首次出现可“工作树 (Worktree)”）；工作区 = Workspace；仓库；分支；智能体 = Agent（产品语境可保留 Agent）；配置档案 = Profile。产品名 Prowl 和工具名（Ghostty、Sparkle、Claude 等）保留原文。
3. SwiftUI 静态字面量用标准本地化；普通 String、动态插值、AppKit 标题在显示边界显式 `String(localized:)`。
4. 翻译完整句子，保留插值、快捷键、Markdown 链接、路径。数量用 catalog 复数变体，避免英文片段拼接。
5. 命令面板增加中文关键词并保留英文词；Ghostty 原始 action/title 仍是命令身份，翻译只用于显示，不能改变命令 ID。
6. `ProwlCLI/` 和 `supacode/CLIService/Shared/` 的 CLI help / plain-text error / summary 保持英文。JSON 字段、错误码、配置键、工作流字段、用户自定义名称不变。GUI 使用共享值时，在 app 侧按稳定 ID/类型映射到 `Localizable.xcstrings`，不改共享 `displayName` 或 `validationErrorMessage`。不要用匹配英文错误文本来分支翻译。
7. 帮助双语言合同：`AskAgentHelpView` 的标题、说明、按钮用本次启动应用语言；显示和复制的 prompt 保留系统首选语言（不受 Prowl 派生 `AppleLanguages` 或命令行调试覆盖污染）。将 chrome 与 prompt 生成输入拆开；LSP references 后清洁迁移，不留旧单 locale 接口。
8. Ghostty 运行时命令标题/描述与 Sparkle UI 列入边界清单；不修改第三方动作标识，不承诺翻译外部程序输出。
9. 按 catalog key 清单翻译，写入 `zh-Hans`。可分批（每批 ≤30 key）并行，但每批必须直接改 `.xcstrings` 并保持 JSON 合法。全部写完后 Recheck：每个应译 key 的 `zh-Hans.stringUnit.state == translated` 且 `value` 非空；插值占位符与英文 key 一致。再做真实 UI 补漏。覆盖表追加在本计划文末执行记录，不另建报告文件。

**验收：** 范围内应用自有 GUI 文案均已资源化并有简体中文，含工具提示、无障碍标签、错误和确认窗口；无原始 key 泄漏到 UI；英文版保留。第三方/系统文案逐项说明边界。

## Task 5: 行为测试与真实界面验收

**自动验证：**

- 持久化旧配置和未知语言值回退。
- 系统语言协商、显式覆盖、恢复系统、重启前有效语言不变。
- 语言切换不改变命令身份；命令面板可用中文和英文检索相同行为。
- CLI 英文输出边界：app 显式中文/英文时，CLI help / 可重复错误 / summary 仍为英文。比较受控字段，不用 UUID/路径/终端原始输出。
- 持久桥接：原值不存在 / 已有覆盖 / 外部改写 / 恢复系统、配置保存失败、命令行临时覆盖不反写、退出后编辑配置。
- 只保留能防止具体回归的测试，不用源码文本匹配或大批英文文案快照。

**命令（项目根目录）：**

```bash
make build-app
xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination 'platform=macOS' \
  -only-testing:supacodeTests/AppLanguageTests \
  -only-testing:supacodeTests/SettingsFilePersistenceTests \
  -only-testing:supacodeTests/SettingsFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  -skipMacroValidation
make check
```

Swift Testing 的 `-only-testing` 标识符必须带 `()`。检查实际执行数量，不能接受零匹配。触及 CLI 则额外 `make build-cli`、`make test-cli-smoke`；改了 CLI 或共享模块再跑 `make test-cli-unit`、`make test-cli-integration`。不要为 GUI 翻译改 CLI 预期英文文本。

**实际应用检查矩阵：**

- 英文系统 + 跟随系统；中文系统 + 跟随系统；不兼容语言回退英文。
- 英文系统显式中文；中文系统显式英文；二者恢复跟随系统。
- 同一进程多次改变选择，已打开与新打开窗口保持本次启动语言。
- 重启后设置、菜单栏、终端上下文菜单、命令面板、Diff、Agent Island、确认弹窗、权限用途说明。
- 英文应用 + 中文系统：帮助对话框标题/按钮英文，prompt 显示与剪贴板中文；中文应用 + 英文系统则相反。AskAgentHelp 和 WorkflowAuthoring 都验证。
- Run Script、退出确认、安装更新确认必须逐一打开；更新确认只验证展示/取消。
- 中文长说明/混排/缩小窗口无关键截断，快捷键不变。
- 拼音输入、中文路径、终端双宽字符。
- 变更语言时运行中的 agent/终端不被重建。

**通过条件：** 构建与针对性测试通过；实际应用截图/操作记录证明语言切换和主要界面覆盖。静态扫描或编译通过不算视觉验证。

## Task 6: 文档与交付

**文件：**

- `docs/components/settings.md`：入口、选项、下次启动生效、任务中断提示、系统语言优先级。
- `docs/reference/settings-fields.md`：`appLanguage` 字段、稳定值和默认行为。
- `CHANGELOG.md`：新增语言设置和简体中文 GUI。

**步骤：**

1. 真实应用验证通过后清理验证脚本和临时 catalog key，更新上述文档。
2. 列出翻译范围、测试结果及系统/第三方文案边界。
3. 本计划不包含发布、改签名、推送或 PR。若另行发布中文化分支，必须处理当前指向 onevcat/Prowl 的更新源，避免更新覆盖中文化版本。

## 完成定义

不是只有一个语言下拉框，而是“可保存的语言选择 + 下次启动完整生效 + 简体中文 GUI + 英文回退 + 不改变终端/CLI 协议 + 实际界面验证”。

顺序：Task 1/G1a（用现有 `.xcstrings` 做原型）→ Task 3/G1b → Task 4 直接编辑 `.xcstrings` → Task 5 → Task 6。Task 2 已完成。不要先铺开全量翻译再发现启动切换盖不住 AppKit。

## 独立审核处理记录

两名 reviewer 初审后的架构结论仍然有效（所有权、命令行优先级、启动快照、外部 JSON、弹窗覆盖、帮助 chrome/prompt、CLI 英文边界）。

2026-09-15 用户指示变更：汉化改为直接使用 `.xcstrings`，取消“必须挂载 LocalizationPlanner / StringCatalog\* 才能继续”的 G0。原 LocalizationCoverageReview 的“目录工具合法执行路径”被本修订替代为：catalog 文件已在工程中，构建提取 + 直接编辑 JSON。

当前剩余验证：Task 1 G1a 的早期语言桥接、单次冷启动、原生界面一致性；Task 3 UI 与启动接入；Task 4 全量翻译。不能把计划修订当成这些已经通过。
