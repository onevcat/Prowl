# 053 — Agent Profiles: Plan

| | |
| --- | --- |
| **Status** | Implemented(见 [001-action.md](001-action.md)) |
| **Anchor date** | 2026-07-29 |
| **Primary PRs** | [#620](https://github.com/onevcat/Prowl/pull/620) |
| **Related** | [047 cross-agent handoff](../047-cross-agent-handoff/000-plan.md), [048 agent runtime adapters](../048-agent-runtime-adapters/000-plan.md), [049 Agents toolbar entry](../049-agents-toolbar-entry/000-plan.md), closed prototype [#617](https://github.com/onevcat/Prowl/pull/617) |

## 背景

Prowl 目前只能安全启动 Claude Code 和 Codex 两种已验证的 runtime。adapter 层
(`AgentRuntimeAdapter`) 已经拥有结构化的 model / execution-mode argv 渲染,工具栏 Agents
capsule 的无 agent 形态被预留给快速启动入口。尚不存在持久化的 profile、面向用户的启动器,
或账号选择能力。

已关闭的原型 [#617](https://github.com/onevcat/Prowl/pull/617) 验证了 `CLAUDE_CONFIG_DIR` 与
`CODEX_HOME` 可以让两份登录并存,同时也暴露了关键约束:这两个环境变量搬走的是 runtime 的
**整个 home**——skills、全局指令文件(`CLAUDE.md` / `AGENTS.md`)、session 历史、settings
全部跟随,而不仅仅是凭据。

### 本次重写的动因

本计划的初稿把"每个 profile 无条件派生一个私有 runtime home"作为核心机制。讨论后确认这
混淆了两根正交的轴:

| 轴 | 机制 | 副作用 |
| --- | --- | --- |
| **Preset 轴**:model、reasoning effort、execution mode | 纯 argv,adapter 已支持 | 零副作用,天然共享 skills / 全局指令 / session 历史 |
| **Account 轴**:独立登录与用量 | 只能搬 home(#617 唯一验证过的机制) | 把 skills、指令、历史全部拖入隔离 |

Profile 的本体是 **preset**(对已知 runtime 的一组命名预置配置);账号隔离是一个**可选的、
按 runtime 能力位门控的绑定**,用户显式选择并知情承担隔离代价。用量跟随 OAuth 登录,
"只分用量不分登录"不存在中间路线。

## 目标

- 为两种已验证 runtime(Claude Code、Codex)定义命名 profile;同一 runtime 可有多个
  profile,profile 不等于品牌。
- 从 Agents 菜单选择 profile 后,在当前 worktree 新建并选中一个 surface(按 placement
  为 tab 或 split),以交互模式启动 agent,无初始 prompt。
- 每个 profile 持久化可选 model、可选 reasoning effort、显式 execution mode,全部以 argv
  渲染。
- **默认形态(纯 preset)**:profile 运行在共享的默认 home,不设置任何环境变量;skills、
  全局指令、session 历史与 `--resume` 列表保持统一。
- **可选账号绑定(opt-in)**:profile 显式绑定独立账号时,才派生私有 runtime home,用于
  独立登录与独立用量;仅此时出现 profile 文件管理控件。
- Agents capsule 永远是菜单:列出推荐与已启用的 profile、不可用项及原因、管理入口;有
  运行中 agent 时附带现有 Active Agents 内容。
- 以"指定 > 记忆 > 兜底"三层规则为每个 worktree 选出菜单里的 Recommended profile。
- Profile UUID 保持稳定,使未来的 handoff 集成可以引用 profile 而非裸 agent token。

### 非目标

- 不改动现有 Hand Off UI、`prowl handoff` 契约或继承配置行为。
- 不把 API key、OAuth token、`auth.json` 内容放进 Prowl JSON、日志、分析或 SwiftUI 状态;
  V1 只使用 CLI 自管认证。裸 API key 输入(需 Keychain 引用 + agent-only 启动边界)整体
  推迟。(2026-07-31 显式放宽:env overrides 的值可含 API key、明文存储,配套 0600 与
  预览脱敏,见 [004](004-environment-overrides.md)。)
- 不接受任意可执行文件路径或 shell 片段。自定义附加参数(Advanced)是**字面 argv
  token**:按 shell-words 规则切分后逐个追加,永不经过 shell 解释(无变量展开、命令
  替换或重定向)。
- 不在 profile 或推荐指定变化时修改运行中的 pane,不拦截用户在既有 shell 中手动输入的
  `claude` / `codex`。
- 不支持检测到但未验证的 runtime。
- 不做任何形式的共享配置 symlink——既不自动做(#617 教训),也不作为 follow-up 提供
  子目录级共享开关。想在绑定 profile 间共享 skills 等目录的高级用户,经
  "Reveal Profile Files" 自行 symlink 即可;这个决策与其风险留给用户,Prowl 不代管。
- 不做 per-profile 指令/skill 注入:绑定 profile 的专属指令由 home 内原生指令文件
  (`CLAUDE.md` / `AGENTS.md`)覆盖,无需注入;纯 preset 的注入通道(Claude Code 有
  `--append-system-prompt`,Codex 交互式 TUI 无已验证等价物)不再规划,能力位仅作预留。
- 不做 profile 导入/导出或 skills / 指令文件的可视化编辑器。
- 不新增任何 profile 相关的 analytics 事件;profile 名称、UUID 与绑定状态一律不进入
  PostHog / Sentry。

## 产品形态

### Profile 与 Settings

Settings 新增独立的 **Agents** tab(`SettingsSection` 新 case,与 Custom Commands
平级;命名取 Agents 而非 Agent Profiles,与工具栏 Agents capsule 的入口层级一致,并为
未来 agent 相关设置留出空间)。tab 内容为可排序的 profile 列表(顺序即推荐兜底的优先
级)与选中 profile 的编辑器;per-repo 的 Default Agent Profile 选择器在既有的
repository section 中。profile 集合(连同播种 flag)有序存放于 `UserGlobalSettings`
(`~/.prowl/global.onevcat.json`):账号与 agent 偏好是本地用户的私有配置,不得成为
仓库配置。per-repo 的 Default Agent
Profile 指定与上次启动记忆存于 `UserRepositorySettings`(本地文件
`~/.prowl/repo/<name>/prowl.onevcat.json`,同样不进仓库)。

一个 profile 包含:稳定 UUID、显示名、启用状态、runtime、可选 model、可选 reasoning
effort、既有的显式 execution mode、启动位置(placement)、可选的自定义附加参数
(Advanced),以及**可选的账号绑定**。
model 与 reasoning effort 均存为自由字符串,`nil` 表示 runtime 默认;编辑器按 runtime
展示 adapter 自带的建议列表(effort 如两家共有的 low/medium/high 及 Codex 的
`minimal` / `xhigh` 等扩展档位),同时允许直接填写任意值。自定义值只作为**单一参数值**渲染进类型化参数——Claude Code 的
`--effort`、Codex 的 `model_reasoning_effort` config override——走既有的安全 argv 渲染,
不经过 shell 解释;未知档位由 CLI 启动时自行报错,在新 surface 内直接可见,Prowl 不做预校验。
`.unrestricted` 保留但视觉上标记为危险,保存时需要显式确认;绝不从其他 profile 或来源
pane 推断。

编辑器含 **Advanced 面板**(与账号绑定同区):**自定义附加参数**字段,按 shell-words
规则切分为字面 argv token(支持引号包裹含空格值),追加在 adapter 生成参数之后
(last-wins,用户可覆盖预置值),永不经 shell 解释。编辑器底部实时显示**启动预览**:
最终的完整启动形态,绑定 profile 含环境前缀(如
`CODEX_HOME=~/.prowl/agent-profiles/<uuid> codex --yolo`)——launch spec 是纯函数,
预览与实际启动共用同一渲染,兼作附加参数切分的自查。

**初始播种(seeding)**:首次启用本功能时,为每个已安装的已验证 CLI 播种一个裸
preset(显示名即 runtime 名,无 model/effort、standard 模式、New Tab、不绑定账号),
行为等同用户手动敲 `claude` / `codex`。播种一次性(记录 flag),用户删除后不复活;
两家 CLI 均未安装时,菜单显示灰色说明与 "Manage Agent Profiles…" 空态。

**未绑定账号的 profile(默认)**:不派生目录、不设置环境变量、不显示登录控件;状态栏
说明其使用系统默认登录。

**绑定账号的 profile**:编辑器只提供 **Reveal Profile Files** 与一行被动状态(home
尚未初始化 / 已初始化,纯文件系统检查,绝不调用 CLI)。没有 Sign In 按钮、没有登录
状态探测:**首次启动即登录时刻**——未登录的绑定 profile 启动后,agent TUI 走自己的
原生登录流程,该 surface 的环境已挂好,凭证自然落入 profile home;确认登录身份用
agent 内的 `/status`。绑定开关旁必须写明隔离代价:该 profile 将拥有独立的 skills、
全局指令与 session 历史。

### 启动与 Agents 菜单

Agents capsule 不再因无运行中 agent 而禁用,而是**永远作为菜单**存在:

- 无 agent 时:当前 worktree 的 **Recommended** profile 排最前,其后是全部已启用
  profile;不可用项(CLI 未安装、profile 被禁用)灰显并展示原因;底部提供
  "Manage Agent Profiles…" 直达 Settings。
- 有运行中 agent 时:保留现有 Active Agents / Hand Off 内容,并附带上述启动项。

选择 profile 即在该 worktree 新建一个 surface 并以交互模式启动 runtime,无初始 prompt。
启动位置由 profile 的 placement 决定:**New Tab**(默认)或 **New Split**(带方向,复用
custom command 既有的 `UserCustomSplitDirection`)。split 同样是全新 surface,身份记录与
结构化启动规则完全一致;当该 worktree 尚无可分割的 surface 时,split 退化为新 tab。绝不
向既有 shell 注入文本:Prowl 无法证明那个 shell 处于空闲、可安全接管的状态。

Command Palette 提供第二入口:为每个已启用 profile 动态生成 "Launch Agent: <名称>"
条目(当前 worktree 的推荐排前),派发与菜单**完全同一个** profile-launch action——
palette 是入口而非第二条启动路径,placement、身份记录与环境 patch 全走同一条缝。

Prowl 启动的 surface 在创建时记录 profile UUID;检测到但非 Prowl 启动的 agent 只显示
"检测到 Codex"这类事实,绝不猜测其归属的 profile 或账号。身份的 UI 露出:有 profile
记录的 surface 在 Active Agents 列表与 capsule 中显示 profile 显示名(必要时附 runtime
图标消歧义),仅检测的维持 runtime 名;tab 标题不在本波范围内,维持既有逻辑。

### 推荐(Recommended)

菜单里 Recommended 的解析是三层回退,心智模型为**指定 > 记忆 > 兜底**:

1. **指定**:该 repo 在 Repository Settings 中选定的 Default Agent Profile。
2. **记忆**:未指定时,使用**该 repo 内上一次显式启动的 profile**(per-repo 记录一个
   UUID,该 repo 任一 worktree 从菜单启动 profile 时更新;点击推荐项同样算显式启动)。
   记忆比显式指定弱一级,但构成"这个 repo 就该用这个 profile"的隐式默认。
3. **兜底**:从未在该 repo 启动过任何 profile 时,取有序 profile 列表中第一个已启用的。

每一层只解析到存在且已启用的 profile;悬空(已删除)或被禁用的引用直接落到下一层,
normalization 时清理悬空的 per-repo 指定。runtime CLI 是否可用不参与解析:推荐位照常
给出,CLI 缺失时灰显并写明原因——让问题可见,绝不静默改推其他 profile。解析是只读的,不创建任何目录。推荐只决定
菜单排序——显式选择其他 profile 永远优先。profile 在启动时记录到新 surface 上,之后的
指定或记忆变化绝不重新标记或修改活跃 pane。

### 账号绑定与 runtime home(opt-in)

账号绑定由 adapter 能力位(`supportsAccountIsolation`)门控;两家已验证 runtime 均通过
`CLAUDE_CONFIG_DIR` / `CODEX_HOME` 支持。

绑定 profile 的 home 从其 UUID 派生:**`~/.prowl/agent-profiles/<uuid>/`**
(`SupacodePaths.baseDirectory` 之下),环境变量直接指向该目录,不加中间层。绝不来自
显示名或用户提供的路径。选 `~/.prowl` 而非 Application Support 的技术理由:后者路径
含空格,第三方 CLI 及其子进程的引号处理是真实风险面;且与 repo 设置同根、对
"Reveal Profile Files" 直观。启动准备阶段先创建 runtime 目录(Codex 拒绝不存在的 `CODEX_HOME`)、校验
解析后的路径仍在 profile-home 基目录内,并施加 owner-only 权限。

home 对 Prowl 是不透明的:对应环境变量只附加到新终端 surface——Claude Code 用
`CLAUDE_CONFIG_DIR`,Codex 用 `CODEX_HOME`——使启动的 agent 及其子进程看到选定上下文。
环境 patch 是**叠加而非替换**:新 surface 是全新的 login shell,照常继承 rc 文件构建的
常规环境(PATH、用户自行 export 的变量等),Prowl 只追加变量、不做环境清洗;其他 tab
中手动 export 的会话状态不会传入。

全新 home 意味着 agent 首次启动即未登录;用户在首次启动的 surface 内完成 CLI 原生
登录后,凭证落在该 home 中(Codex 为 `auth.json`,Claude 的凭证存储同样以 config dir
为界,#617 实测互不串号)。`$CLAUDE_CONFIG_DIR/CLAUDE.md` 与 `$CODEX_HOME/AGENTS.md` 是两家 CLI
全局指令文件的原生位置,搬迁后自动从新位置读取——绑定 profile 的专属指令与 skills
直接放进 home 即可,无需任何注入机制。Prowl 不解析、不复制、不展示凭据文件;项目内的
指令文件仍归项目所有。

**删除绑定 profile** 弹出确认对话框,写明登录凭证与文件仍在磁盘上:默认只删 profile
条目、保留目录;提供显式的 "Move Profile Files to Trash" 选项(NSWorkspace 移入废纸篓,
可找回,绝不 `rm`)。硬性不变量:删除的文件操作只作用于从该 profile UUID 派生、且通过
profile-home 基目录包含校验的路径——与启动时同一道闸;纯 preset 没有 home 引用,删除
时执行零文件操作;任何指向基目录之外(含 `~/.claude` / `~/.codex` 真实 agent home)的
路径直接拒绝。

Prowl 不提供任何目录共享功能(V1 及以后均然)。希望在绑定 profile 与默认 home 之间
共享 skills 等目录的高级用户,可经 "Reveal Profile Files" 自行创建 symlink;文档应
提示:会被 CLI 原子重写的文件(`settings.json`、`config.toml`、`auth.json`)绝不可
链接,#617 实测重写会替换 symlink 导致静默分叉。

## 实现方式

1. 引入 Codable 的 `AgentProfile` domain model(preset 字段 + placement + 可选账号绑定)
   与三层推荐 resolver 及 normalization 测试。runtime enum 限定为 Claude Code 与 Codex,
   校验非空显示名与 UUID 唯一性,normalization 时清理悬空的 profile 引用。扩展
   `supacode/Features/Settings/Models/UserGlobalSettings.swift`(profile 集合)与
   `UserRepositorySettings`(Default Agent Profile 指定 + per-repo 上次启动记忆)及其
   shared key,兼容缺少新字段的既有 JSON。
2. 在 `supacode/Domain/AgentRuntime/AgentRuntimeAdapter.swift` 中把启动意图类型化为
   `.interactive` / `.prompt(String)` / `.headless(String)`,禁止空 prompt 哨兵。
   `.headless` 渲染为各家的一次性执行模式(Claude Code print 模式、`codex exec`,与
   handoff resume 同一条已验证通道),在 domain 与 adapter 层完整实现并测试;V1 不为
   其提供任何 UI 消费者——输出捕获、退出语义、surface 去留是留给 CLI/handoff 后续
   波次的产品决策。带 JSON Schema 的结构化输出继续推迟。`AgentLaunchConfiguration`
   增加可选 reasoning effort,由各 adapter 自行完成 argv/config 映射与校验。为 adapter
   增加能力位:V1 实际使用 `supportsAccountIsolation`,为 handoff 与指令注入预留位置,
   取代散落的品牌硬编码判断。
3. 把 profile 解析为单一 launch specification:profile UUID、类型化启动请求、argv
   (adapter 生成 + 附加参数 token 追加,shell-words 切分器为带测试的纯函数)、
   placement,以及**仅账号绑定时非空**的环境 patch。启动预览与实际启动共用该解析。扩展
   `supacode/Clients/Terminal/TerminalClient.swift` 与
   `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` 的 surface 创建路径,
   使新 tab 与新 split 均经 `GhosttySurfaceView(environment:)` 接收 patch;不得把环境
   变量赋值拼进 shell 输入。在既有检测状态旁记录每个 surface 的启动 profile。
4. 打通账号绑定 surface 的 session 检测与恢复。`AgentSessionResolver` 目前把
   `FileManager.default.homeDirectoryForCurrentUser` 传入声明式布局
   `AgentSessionProfile`,Claude/Codex 的 candidateRoots 与 parsePath 以
   `~/.claude` / `~/.codex` 为根,对搬迁后的 home 全部失效。把这两家的布局从
   "用户 home + 固定点目录"推广为 **config root** 参数:默认即 `~/.claude` /
   `~/.codex`;Prowl 启动且绑定账号的 surface 以记录的 profile 推导 root(env 是
   Prowl 自己设置的,root 是已知量,无需探测)。parsePath 的全局子串 marker 改为按
   已知 root 前缀匹配。绑定 source surface 的 resume invocation 仍需携带同一环境 patch,
   否则 CLI 会在默认 home 中查找 session;该 resume env 缝未在 V1 实现,且 053.007
   只配置 handoff receiver,因此继续延期。进程分类(argv)、OSC working/idle、
   child-env session id 证据与其余 runtime 均不受影响。用户手动携带自定义
   `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 启动的 agent 维持现状(agent 本体可检测、
   session 身份不可得);读取 TUI 进程 env 反推 root 列为 follow-up。
5. 新增小型 Settings reducer/view:`SettingsSection` 加 `agents` case 及对应 tab,
   承载 profile 列表/编辑(绑定分支仅 Reveal Profile Files 与被动 home 状态,无任何
   后台 CLI 调用);在 Repository Settings 中加入 Default Agent Profile 选择器。文件
   操作全部藏在注入的 profile-home dependency 之后,测试绝不触碰真实登录目录。
6. 扩展 `supacode/Features/Repositories/Views/AgentsToolbarButton.swift` 及其在
   `supacode/Features/Repositories/Views/WorktreeDetailView.swift` 中的接线:改为永远是
   菜单;检测态保留现有 Hand Off 动作,启动项经 `AppFeature` 派发单一 profile-launch
   action。`CommandPaletteFeature` 按已启用 profile 动态生成 Launch Agent 条目,复用
   同一 action(参照既有 handoff 条目工厂的模式)。
7. 实现完成后,更新对应的现状文档,并以实际 PR 与测试证据撰写 `001-action.md`。

## 从 #617 带入的经验

| 发现 | Profile 决策 |
| --- | --- |
| Per-surface 环境变量可隔离两份 CLI 登录。 | 环境变量只在新 surface 启动边界施加,且仅限账号绑定 profile。 |
| `CODEX_HOME` 必须在 Codex 启动前存在。 | 启动前先创建派生 home。 |
| 搬迁后的 home 包含 settings 与 skills,不止认证文件。 | 隔离是全有或全无的账号轴代价,因此 preset 为默认、绑定为 opt-in。 |
| 共享配置的 symlink 会在 CLI 重写文件时静默分叉。 | Prowl 不做任何 link;高级用户自行 symlink,文档警示被重写文件不可链接。 |
| 账号/推荐变化不得影响活跃 pane。 | surface 创建时记录 profile ID;推荐解析只影响后续启动。 |
| 认证状态输出对流与退出码敏感。 | V1 不做状态探测;登录与身份确认交给 CLI TUI 原生流程。 |

## Handoff 边界

Profile 是 V1 的**启动**特性,与 049 划定的边界一致。把 handoff 迁移到 profile 路径是
**确定的后续方向**——只是不与本波同行;profile 的稳定 ID 与解析后的 launch
specification 从第一天起就按可被 handoff 引用设计。V1 的 handoff 目标列表维持现有
agent 列表不变。

未来的 handoff 集成必须让选定 profile 同时贯穿两条路径:HUD 的注入请求与 CLI/fallback
处理器。只更新 `supacode/Features/HandoffHud/Reducer/HandoffHudFeature.swift` 会让 fallback
静默丢失 profile,因为 `supacode/CLIService/HandoffCommandHandler.swift` 目前会重建继承
配置。该阶段应扩展结构化的 handoff request/registry 边界;绝不能在请求开始后读取
ambient "当前/推荐 profile" 来改变目标。后续 053.007 绑定稳定 UUID,并允许在执行时
按该 UUID 读取最新持久化配置;这不是重新选择目标。

## 验证

- Domain 测试:profile normalization、UUID 稳定性、三层推荐回退链(指定 > 记忆 > 兜底,
  含悬空/禁用引用逐层跳过)、旧版 JSON 解码、无任何持久化的敏感材料;纯 preset profile
  必须产生空环境 patch。
- Adapter 测试(`supacodeTests/AgentRuntimeAdapterTests.swift`):无 prompt 的交互式
  argv、`.headless` 的一次性执行 argv、model/effort 映射(含自定义 effort 值的安全
  渲染)、标准与危险模式、shell 转义、能力位取值;shell-words 切分器(引号、转义、
  空输入)、附加参数追加顺序、预览与实际渲染一致。
- Settings 与 profile-home 测试:保存/重载、绑定 profile 的派生目录 owner-only 权限、
  home 初始化状态的被动判定(纯文件系统,不调 CLI)、绝不访问真实凭据;删除路径的
  包含校验(基目录外一律拒绝)、纯 preset 删除零文件操作、Trash 而非删除。
- Reducer/终端测试:菜单各可用性状态、palette 条目生成与共享 action 派发、正确的
  worktree/cwd/环境 patch、每次选择恰好新建
  一个 surface(tab 或按 placement 的 split,空 worktree 时 split 退化为 tab)、推荐
  变化后 surface 的 profile 身份保持稳定、纯 preset 启动不设任何环境变量。
- Session 检测测试:`AgentSessionResolver` 以注入的 config root 在 profile home 布局下
  解析出 Claude/Codex session;默认 root 行为不变。绑定 source surface 的 resume argv
  环境传播未在 V1 实现,且 053.007 只配置 handoff receiver;该 source-side 缺口继续延期。
- 手动验证:(a) 同一 runtime 的两个纯 preset(不同 model/effort)并排启动,确认共享同一
  登录且 `--resume` 历史统一;(b) 两个账号绑定 profile 分别登录不同账号并排运行,确认
  各 CLI 报告自己的身份;(c) 修改 repo 指定或启动其他 profile 后,确认只有后续启动的
  推荐受影响。

## 备选与决策

- **Preset 优先,而非 home 优先。** 初稿把私有 home 当作 profile 本体,把账号轴的隔离
  代价强加给所有 profile;重写后 preset 是默认形态,绝大多数用例零副作用。
- **隔离 opt-in,而非无条件。** 用户显式勾选账号绑定并知情承担 skills/历史隔离的代价;
  UI 必须写明该代价。
- **能力位,而非品牌硬编码。** `supportsAccountIsolation` 等 adapter 能力位使 V1 仍只
  发货两家 runtime,但结构上为后续 runtime 留门。
- **Profile home 优于裸凭据。** 保留 CLI 支持的认证流程,避免 Prowl 变成密钥管理器;
  Keychain 引用只对未来的裸 API key 场景有意义,整体推迟。
- **新 tab 优于向当前 shell 注入。** 保护进行中的 shell 工作,并让 agent 从进程启动起
  就拥有一致环境。
- **三层推荐优于路径前缀 route 表。** 初稿设计了"路径前缀 → profile"的全局映射表
  (最长目录边界匹配 + per-runtime 默认)。讨论后以"指定 > 记忆 > 兜底"取代:表达力
  略低,但心智模型简单得多,且免去 route 编辑器与边界匹配的全部复杂度;per-repo 指定
  存于本地的 `UserRepositorySettings` 文件,本地身份依然不进入仓库配置。
- **目录共享完全不做,而非推迟。** 便利是真实的,但提供共享开关意味着 Prowl 永久背上
  "哪些子目录对哪个 runtime 安全"的验证与维护责任;高级用户一条 symlink 即可自助,
  不替他们做决策。
- **指令/skill 注入不做,而非推迟。** 绑定 profile 的专属指令由 home 内原生文件覆盖,
  注入需求已消失;Codex 侧亦无已验证注入机制。`supportsInstructionInjection` 能力位
  仅作预留,不再规划实现波次。
- **Handoff 后续跟进,而非部分集成。** Profile-aware 的 handoff 必须在正常与 fallback
  两条执行路径上同时正确;推迟比让两者不一致更安全。

## 后续方向(非 V1 承诺)

- **Handoff 迁移到 profile 路径**:确定愿景,单独波次;必须同时贯穿 HUD 与 CLI/fallback
  两条执行路径(见「Handoff 边界」)。
- **Headless 产品化**:输出捕获、退出语义、surface 去留,以及两家 print/exec 模式
  flag 面(含 JSON Schema 结构化输出)的调研与实验;domain/adapter 缝已在本波就绪。
- **更多 runtime 接入**:逐家 spike 验证(启动语义、账号隔离机制、effort/headless
  支持度)后,由各自 adapter 声明能力位接入;domain 与 UI 无需再改判断逻辑。
- **手动自定义 home 的 session 检测**:读取 TUI 进程 env 反推有效 config root。
- **`prowl` CLI 的 profile 感知**:等 profile 特性定型后再研究;profile 的 CLI 引用
  方式(名称/UUID)与 handoff 迁移波次的结构化请求一起定,避免过早固化 CLI 契约。

## Amendments

- Updated 2026-08-01: implemented Profile-aware handoff across HUD, CLI, request ownership, and the
  shared Profile launch boundary, while retaining Runtime Default compatibility and keeping native
  Codex profile selection in Extra Arguments — design in
  [007-profile-aware-handoff.md](007-profile-aware-handoff.md), result in
  [008-profile-aware-handoff-action.md](008-profile-aware-handoff-action.md).

- Updated 2026-07-31: **环境补丁语义从 surface-scoped 改为 launch-scoped** — onevcat
  定位出"Agents 启动 → agent 退出 → 手动 codex 继承 profile env"的串号链,环境补丁
  改为随 `env` 前缀只作用于 launched 进程(home 内联、override 值经 `PROWL_ENV_*`
  carrier 引用,不进 history),launch identity 随 launched 进程退出而清除;本文
  「账号绑定与 runtime home」节的 surface 附加语义由此作废 — see
  [006-launch-scoped-environment.md](006-launch-scoped-environment.md).

- Updated 2026-07-31: V1 综合审计(双评审交叉核对)与首轮边界补强 — see
  [005-v1-audit.md](005-v1-audit.md)。修复:`HOME` 入 env 保留名单、launch 结果
  事件化(记忆后置 + 失败 toast)、profile 名按 runtime 门控、可用性判定共享且
  不阻断、settings 权限加载迁移与 0600 temp。

- Updated 2026-07-31: 新增用户可配置的 per-profile 环境变量覆盖(base url / api key
  临时改写,如 "Codex but using DeepSeek")— see
  [004-environment-overrides.md](004-environment-overrides.md).

- Updated 2026-07-31: profile launcher 图标的持久化、fallback 与 surface 范围决策 — see
  [003-profile-icons.md](003-profile-icons.md).

- 2026-07-30 — Review 四轮(P2):palette 的 Launch Agent 条目工厂改用与 launch
  action 相同的 action-target 解析(selectedTerminalWorktree ?? Canvas 聚焦卡),
  Canvas 模式下条目不再缺席;补 Canvas 聚焦卡回归测试。
- 2026-07-30 — Review 五轮(P2)+ 治本重构:plain-folder 聚焦卡的 ID 是 repository
  ID,工厂用 `worktree(for:)` 解析不到(第三次同族偏差)。新增单一 resolver
  `RepositoriesFeature.State.actionTargetTerminalWorktree(explicitTargetID:)`
  (选中 terminal worktree ?? 显式 target 经 `terminalWorktree(for:)` 完整解析,
  含 plain-folder 合成),palette 工厂与 `AppFeature.actionTargetWorktree` 均改为
  调用它——生成端与执行端从此共享同一份目标解析,无法再各漏半步;配语义锁定
  测试与 plain-folder 回归测试。
- 2026-07-30 — Review 三轮(P2/P3):(a) surface 的 launch 身份增加 runtime,config
  root 只对**同 runtime 的检测**生效——bound pane 内手动启动其他 agent 时不再张冠
  李戴、也不再压制默认布局扫描;(b) 删除确认的判断从"当前 bindsDedicatedHome 意愿"
  改为"意愿 ∨ 磁盘上 home 实际存在"——bind→launch→unbind→delete 不再静默遗留凭据
  目录;(c) Reveal 后回发 homeStatusRefreshed,被动状态行即时更新。
- 2026-07-30 — Review 修正(PR #620):(a) extra args 中的 bypass flag **尊重不拦截**,
  但 domain 提供 `effectiveExecutionMode`(复用 adapter `observe` 的识别),编辑器
  据此显示 unrestricted 警示——显示永不谎报 Standard;二轮追审后改为**三态**:
  识别出 bypass → 红色 unrestricted;存在任何未识别的 extra args(含
  `--sandbox` / `--ask-for-approval` / `-c` 覆盖)→ 中性"遵循命令行参数",不再
  声称 Standard——识别清单不可穷尽,诚实的方式是不认识就不承诺;(b) profile home 的包含校验
  升级为物理校验:拒绝 symlink leaf,并以"解析后的父目录 + 叶名"对"解析后的 base"
  做 canonical containment(symlink 的 base 本身仍合法,如同步盘场景),
  provision/reveal/trash 共用此闸;(c) Settings 快照回写不再冲掉外部写入的
  launch 记忆;空名不再静默删除 profile(持久化边界回退旧名)。

- 2026-07-29 — 依据与 onevcat 的设计讨论全文重写并改用中文:profile 从"私有 runtime
  home"重新定义为"preset + 可选账号绑定";新增 adapter 能力位与永远是菜单的 Agents
  capsule;指令/skill 注入与子目录共享明确列为 follow-up;handoff 边界维持不变。
- 2026-07-29 — reasoning effort 从固定三档改为"per-runtime 建议档位 + 自由填值":档位
  集合随模型演进,硬编码枚举会过时;自定义值仅作为类型化参数的单一值渲染,不构成自由
  格式 flag。execution mode 维持既有 `standard` / `unrestricted` 两档不变。
- 2026-07-29 — profile 新增 per-profile 启动位置(placement):New Tab(默认)或
  New Split(方向复用 custom command 的 `UserCustomSplitDirection`);无可分割 surface
  时退化为新 tab。粒度与 custom command 的 per-command 先例一致。
- 2026-07-29 — 推荐机制从路径前缀 route 表简化为三层回退"指定 > 记忆 > 兜底":
  Repository Settings 的 Default Agent Profile > 该 repo 内上一次显式启动的 profile >
  有序列表中第一个已启用的。记忆按 repo 记录而非全局:它弱于显式指定,但构成该 repo
  的隐式默认。删除 route resolver、最长边界匹配与 route 编辑 UI;为守住简单心智模型,
  不引入"全局最近使用"层。
- 2026-07-29 — 子目录级共享从 follow-up 降级为"完全不做":高级用户经 Reveal Profile
  Files 自行 symlink,Prowl 不代管该决策及其风险;文档警示可被 CLI 重写的文件不可链接。
- 2026-07-29 — 讨论中发现账号绑定会使既有 session 检测失效:`AgentSessionResolver` 与
  Claude/Codex 的 `AgentSessionProfile` 布局以 `~/.claude` / `~/.codex` 为根,搬迁后的
  home 无法命中。新增实现步骤 4:布局参数化为 config root(绑定 surface 从记录的
  profile 推导,无需探测),parsePath 改按 root 前缀匹配,resume 携带同一环境 patch;
  手动自定义 home 的 agent 维持"本体可检测、session 不可得",env 反推列为 follow-up。
- 2026-07-29 — Settings 采用独立的 Agents tab(`SettingsSection` 新 case,与 Custom
  Commands 平级);per-repo Default Agent Profile 选择器进既有 repository section。
- 2026-07-29 — 启动意图 enum 在本波补全为 `.interactive` / `.prompt` / `.headless`:
  headless argv 与 handoff resume 同通道、零增量风险,一次迁移优于二次;V1 只做
  domain/adapter 层,不提供 UI 消费者,JSON Schema 结构化输出继续推迟。
- 2026-07-29 — 边界讨论定稿:handoff 迁移升格为确定的后续方向;确认绑定 profile 的
  专属指令走 home 内原生文件(`CLAUDE.md` / `AGENTS.md`),注入需求消失、不再规划;
  明确环境 patch 为叠加语义(继承 login shell 环境,不清洗、不继承他 tab 会话状态);
  新增「后续方向」一节。
- 2026-07-29 — HOME path spike 完成([002-home-spike.md](002-home-spike.md)):账号
  绑定的全部关键假设实测证实(home 预创建、rollout/transcript 跟随新根、指令文件与
  skills 原生拾取、凭证落点、并行登录无串号、真实 home 零污染),无需修改计划。
- 2026-07-29 — 新增 Advanced 自定义附加参数与启动预览:附加参数为字面 argv token
  (shell-words 切分、追加在预置参数后、永不经 shell 解释),相应收窄"自由格式 flag"
  非目标;预览与实际启动共用 launch spec 渲染。
- 2026-07-29 — Grill 环节定案:为已安装 CLI 一次性播种裸 preset;删除绑定 profile 走
  "确认 + 默认保留 + 可选 Trash",文件操作硬性限定在 UUID 派生且通过包含校验的路径
  (纯 preset 零文件操作,绝不触碰真实 agent home);Prowl 启动的 surface 在 Active
  Agents/capsule 显示 profile 名(tab 标题不动);删除 Sign In 与登录状态探测——首次
  启动即登录时刻,编辑器仅保留 Reveal 与被动 home 状态;Command Palette 加共享同一
  action 的 Launch Agent 条目;`prowl` CLI 的 profile 感知缓行;model 与 effort 同构
  为自由字符串 + 建议列表;推荐解析不考虑 CLI 可用性(灰显示因,不静默改推);不新增
  profile 相关 analytics。
