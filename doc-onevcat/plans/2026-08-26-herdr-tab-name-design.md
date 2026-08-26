# Herdr Tab Name 设计与实施方案

**状态：** 待实现

**目标：** 让 Herdr 和 Prowl Clean Mode 使用同一套 tab 命名语义：未手动命名时显示当前目录名，手动命名后保持手动名称，用户明确清空后恢复当前目录名。Goto/Navigator、mobile switcher、terminal attach、window title、Herdr API 和 Prowl native tab bar 不再各自显示不同名称。

## 一、现状与问题

### 1. Herdr 当前行为

Herdr 原本已经有 tab 的手动命名状态。未手动命名时，Herdr 使用 tab 的序号作为显示名称，例如 `1`、`2`。它没有把当前 pane 的 cwd 作为 tab 名称，也没有把“自动名称”和“手动名称”作为两条统一的跨客户端契约。

Herdr 的 pane 已经持续维护当前 cwd，cwd 也已经通过现有的 terminal event 更新到内存状态。这个状态可以作为自动 tab 名称的来源，不需要引入新的 shell 插件、后台进程或额外的 cwd 采集机制。

### 2. 当前分支的过渡改动

上一轮为支持 Prowl native tab bar，增加了 `custom_label`/`customLabel` 协议字段，并让 `tab.rename` 支持 `null` 清空。这解决了 Prowl 暂时区分手动名和自动名的问题，但字段命名没有与 Herdr 已有的 `custom_name` 对齐，也造成 Prowl 开始自行推断自动名、处理 legacy label，并在缺少 worktree provenance 时启动 Git 子进程探测。

这些过渡改动尚未形成稳定的跨仓契约，应在正式实现前收敛，而不是继续叠加字段。

### 3. 需要解决的分歧

- Herdr 的序号不能继续作为未命名 tab 的正常名称。
- Prowl 不能把自己的 process、agent icon 或 linked-worktree 装饰当成 Herdr 的 tab 名称。
- 手动名称即使恰好等于当前目录名，也必须保持手动状态，不能通过字符串比较猜测来源。
- 清空必须是明确交互，而不是依靠输入一个特殊字符串或隐式推断。
- 不能为了名称展示增加可感知的性能成本。

## 二、统一定义

### 1. Canonical label

`canonical label` 不是一个新增字段，而是 Herdr 对外提供的“当前 tab 最终名称”。所有需要显示 tab 名称的 Herdr 入口和 Prowl，都应读取这个结果。

它只有两种来源：

1. tab 有手动名称时，canonical label 就是手动名称；
2. tab 没有手动名称时，canonical label 是当前 focused pane 的 cwd 最后一级目录名。

没有有效 cwd 时使用稳定的非数字 fallback，例如 `Terminal`。数字序号只保留为 tab 的稳定身份/排序信息，不再作为名称 fallback。

### 2. `custom_name`

`custom_name` 是 Herdr 已有的内部状态，表示用户是否设置了手动 tab 名称，以及该手动名称的内容。

它不是视觉装饰，也不是自动名称缓存。它的作用是保存来源语义：

- 有值：cwd 变化不会覆盖当前 tab 名称；
- 无值：tab 名称跟随当前 focused pane 的 cwd。

### 3. `label`

`label` 是现有 `TabInfo` 对外字段，继续作为客户端读取的最终 tab 名称。它由 Herdr 根据 `custom_name` 和当前 pane cwd 计算后输出，不在 `Tab` 中再保存一份自动名称状态。

本文后续提到的“label 变化”，均指同一个 tab 在一次状态变更前后计算出的 canonical label 不同，不表示 Herdr 需要持久化旧 label。

### 4. Prowl 装饰

Prowl 的 native tab bar 在 canonical label 外可以增加独立的视觉信息：

- agent icon；
- foreground process title；
- linked-worktree 的 repo/check-out 表现；
- zoom 标记。

这些内容属于 Prowl chrome decoration，不改变 Herdr 的 canonical label，也不参与判断 tab 是否手动命名。

## 三、需求

### 1. 自动目录名

新建、恢复或切换到未手动命名的 tab 时，tab 名称应显示当前 focused pane 的目录名。执行 `cd` 后，名称应在已有 cwd 状态更新后跟随变化。无论 tab 创建顺序如何，名称都不能显示为 `1`、`2`。

### 2. 手动名称保持

用户手动重命名后，名称必须保持不变，直到用户明确清空。这个规则不受 cwd 变化影响，也不受 process title、agent 状态或 linked worktree 变化影响。

用户把 tab 手动改成与当前目录同名时，仍然视为手动命名。之后目录发生变化，名称仍保持该手动值。

### 3. 明确清空

用户必须有明确的恢复自动名称入口：

- tab context menu 中的 **Use Automatic Directory Name**；
- rename sheet 中的 **Use Automatic Name**。

清空后，tab 回到当前 focused pane 的目录名。重复清空是幂等操作，不产生错误。

### 4. 所有入口一致

以下入口必须显示同一个 Herdr canonical label：

- Herdr 自己的 tab bar；
- Goto/Navigator；
- mobile switcher；
- window title；
- terminal attach 看到的当前 session；
- `session.snapshot`；
- `tab.list` 和 `tab.get`；
- Prowl Clean native tab bar。

### 5. 装饰独立

手动名称只覆盖目录段，不隐藏或替换 process title 和 agent icon。

自动状态下，如果 Herdr snapshot 已提供 linked-worktree provenance，Prowl 可以把目录段表现为 `repo ↳ checkout`；手动状态下，手动目录名优先。没有 server provenance 时，Prowl 直接使用 canonical label，不自行启动 Git 探测来猜测 worktree。

### 6. 性能约束

任何可能造成可感知性能劣化的改动，都必须在实现前说明并得到确认。本需求本身不得新增：

- shell 插件、辅助进程或后台守护进程；
- cwd polling；
- tab render 阶段的 Git 查询或文件系统访问；
- 额外 socket 写入循环；
- 额外 session persistence 线程。

自动名称只使用 Herdr 已有的内存 cwd 和 focus 状态。Prowl 的装饰只在已有 snapshot/process 信息上做内存计算。

## 四、字段取舍

### 保留并使用

| 名称 | 所在层 | 语义 | 用途 |
| --- | --- | --- | --- |
| `Tab.custom_name` | Herdr 内部 | 用户手动名称和来源标记 | 判断 cwd 变化是否可以更新 tab 名称 |
| `TabInfo.label` | Herdr API/event | canonical label，最终当前名称 | 所有客户端和 Prowl 的统一显示来源 |
| pane `cwd` | Herdr runtime/API | 当前 pane 的工作目录 | 自动 label 的唯一来源 |
| workspace worktree provenance | Herdr API | server 已知的 worktree 关系 | Prowl 的可选 linked-worktree 装饰 |

### 不新增

| 名称 | 原因 |
| --- | --- |
| `automatic_name` | 自动名称可以从现有 cwd 即时计算，不需要第二份可失效缓存 |
| `automatic_label` | canonical label 已经是 API 输出语义，不需要再暴露一份自动值 |
| 第二个 custom 状态 | 现有 `custom_name` 已能准确表示手动来源 |

### 废弃并清理

| 名称 | 处理 |
| --- | --- |
| Herdr `custom_label` | 删除，改为对齐已有语义的 `custom_name` |
| Prowl `customLabel` | 删除，改为解码 server 的 `custom_name` 为 Swift `customName` |
| Prowl `hasCustomLabelField` | 删除，不再根据字段是否存在做 legacy 推断 |
| `resolvedCustomLabel` | 删除，不再通过 label、数字或 cwd 相等关系猜测手动状态 |
| `automaticDirectoryName` | 删除，不再在 Prowl 中缓存一条与 server label 平行的自动名称链 |
| tab projection 内 Git `Process` 探测 | 删除；没有 server provenance 时直接使用 server label |

当前 Herdr WIP 中出现过的 `automatic_name` 必须整体删除，不能通过补齐构造参数把它保留下来。清理范围包括：

- `Tab.automatic_name`；
- 读取该字段的 `Tab::display_name`；
- `Tab::new_with_runtime`、`Tab::from_existing_pane` 中的初始化；
- session restore 的 `Tab { ... }` 构造；
- `Workspace::test_new`、`test_add_tab` 等测试构造；
- 为 `automatic_name` 或 `Tab::display_name` 添加的测试和其他引用。

清理完成的静态条件是：Herdr 源码与测试中不存在 `automatic_name` 或用于 tab 名称的 `Tab::display_name` 引用；两仓中不存在 `custom_label`/`customLabel`、`hasCustomLabelField`、`resolvedCustomLabel` 或 `automaticDirectoryName` 引用。

## 五、方案如何满足需求

### 1. Herdr canonical label helper

canonical label helper 由 `AppState` 所有，而不是由缺少 terminal 状态的 `Workspace` 或 `Tab` 所有。原因是正确计算自动名称必须同时读取 tab 布局焦点和 server 内存中的 `TerminalState.cwd`。

helper 的逻辑输入固定为：

- workspace 和 tab identity；
- tab 当前 focused pane；
- focused pane 关联的 terminal identity；
- server 内存中的 `TerminalState.cwd`；
- tab 已有的 `custom_name`。

helper 的输出是一个 canonical label。计算顺序固定为：先使用非空 `custom_name`，否则使用 focused pane 的 in-memory cwd basename，最后才使用 `Terminal`。helper 不读取 Git、不读取文件系统、不查询进程树，也不读取 Prowl decoration。

现有无 `TerminalState` 上下文的 `Workspace::tab_display_name` 不能继续作为生产名称入口，更不能继续返回 tab 序号。它应删除或退出所有生产调用路径。以下生产 projection 必须全部迁移到 `AppState` 的同一个 helper：

- Herdr desktop tab bar 的文字和宽度计算；
- Goto/Navigator 的 row、search text 和 detail；
- mobile header 与 tab switcher；
- window title 的 tab token；
- `TabInfo`，进而覆盖 `session.snapshot`、`tab.list`、`tab.get` 和 create/focus response；
- plugin context 和 pane detail 中的 tab label；
- notification/toast context；
- rename dialog 的当前值和其他会展示 tab 名称的生产路径。

测试 helper 可以直接构造 `AppState`、workspace、tab 和 `TerminalState`，不应为测试保留一个生产环境不可用的数字 fallback。

### 2. Herdr rename contract

`tab.rename` 对输入进行 trim 和校验，server 行为固定如下：

- `label: null`：明确清空 `custom_name`，canonical label 立即恢复为当前 cwd basename；
- `label: ""` 或只有空白：返回 `invalid_params`，不修改状态；
- 其他字符串：trim 后写入已有 `custom_name`；
- server 任何路径都不能保存 `Some("")` 或纯空白名称。

CLI 的明确清空入口继续映射为 `label: null`。Prowl 的 reset 交互也只发送 `null`，不发送空字符串作为清空 sentinel。

`TabRenamed` 事件维持最小 payload：携带 `tab_id`、`workspace_id` 和变更后的最终 `label`，不重复携带 `custom_name`。因此该事件同时承担 snapshot invalidation：Prowl 收到任意 `tab.renamed` 后必须进入现有 100ms debounce refresh，重新请求 `session.snapshot`，从 snapshot 同时取得最终 `label` 和 `custom_name`。Prowl 不直接用事件 payload 拼本地 tab 状态。

### 3. 名称变化事件闭环

Herdr 在会改变 tab canonical label 的状态变更前后各计算一次目标 tab 的 label；仅在结果真实不同时发送 `tab.renamed`。事件中的 `label` 必须是状态变更完成后的最终值。

具体闭环如下：

| 触发 | Herdr 行为 | 事件 | Prowl 行为 |
| --- | --- | --- | --- |
| focused pane 的 cwd report | 先保留旧 cwd 计算旧 label，再更新 `TerminalState.cwd` 并计算新 label | 自动 tab 且 label 变化时发送 `tab.renamed` | 收到事件后 debounce 并 refresh snapshot |
| 非 focused pane 的 cwd report | 更新 pane cwd；该 cwd 不参与当前 label | 不发送 `tab.renamed` | 不因该 cwd 单独刷新 tab 名称 |
| pane focus 在同一 tab 内变化 | 用旧 focused pane 计算旧 label，完成 focus 后用新 focused pane 计算新 label | 自动 tab 且 label 变化时发送 `tab.renamed`；无变化不发送 | `pane.focused` 用于更新 selection，并触发 snapshot refresh；`tab.renamed` 保证名称变化闭环 |
| tab focus | 切换 active tab，但不改变各 tab 内部 focused pane | 单纯 tab focus 不发送 `tab.renamed` | `tab.focused` 必须 refresh snapshot 以同步 selection；目标 tab label 由 snapshot 的 canonical label 给出 |
| workspace focus | 切换 active workspace，不改变 tab 内部 focused pane | 单纯 workspace focus 不发送 `tab.renamed` | `workspace.focused` 必须 refresh snapshot 以同步 selection |
| focus 操作同时修正 pane focus | 按 pane focus 规则比较受影响 tab 的前后 label | 只对实际变化的 tab 发送 `tab.renamed` | focus event 更新 selection，rename event invalidates label snapshot |
| 手动 rename 或 clear | 更新 `custom_name` 后计算最终 label | 始终发送一次 `tab.renamed` | refresh snapshot，取得 `label + custom_name` |

cwd/focus 的底层状态如果本来就需要持久化，继续沿用已有 session dirty 和 debounced save；canonical label 是派生结果，不单独增加持久化字段、save 线程或写盘频率。

### 4. Move contract

`tab.move` 只是同一 workspace 内的 tab 纯重排。tab identity、focused pane、cwd 和 `custom_name` 都不改变，因此它只发送既有 `tab.moved`，不发送 `tab.renamed`。Prowl 收到 `tab.moved` 后 refresh snapshot 以同步顺序。

`pane.move` 可能改变 source tab 或 target tab 的 focused pane，因此必须在移动前记录两侧 canonical label，在移动和 focus settle 完成后重新计算：

- source tab 仍存在且 label 变化：只为 source tab 发送一次 `tab.renamed`；
- target tab 已存在且 label 变化：只为 target tab 发送一次 `tab.renamed`；
- source/target label 未变化：不发送 rename；
- source tab 被关闭：由 `tab.closed` 表达，不再为已关闭 tab 发送 rename；
- move 创建新 tab：`tab.created` 中的 `TabInfo.label` 必须已经是最终 canonical label，不额外发送重复 rename；后续 focus settle 若再次真实改变 label，才发送 rename；
- 同一个 tab 同时是 source 和 target 时去重，最多发送一次 rename。

Prowl 对 `pane.moved`、`tab.created`、`tab.closed` 和 `tab.renamed` 都沿用 snapshot refresh；不得在本地模拟移动后的 label。

### 5. Restore contract

session restore 必须先完成 tab layout、focused pane、terminal 映射、恢复的 `TerminalState.cwd` 和 `custom_name`，再对外提供首个 `session.snapshot` 或允许 attach client 渲染。

首个 snapshot 的 `TabInfo.label` 必须满足：有 `custom_name` 时使用手动名称；否则使用 restore 后 resolved focused pane 的 cwd basename；cwd 无效或缺失时使用 `Terminal`。不能先发数字 label，再等待 cwd event 修正。

如果 imported/restored runtime 在首个 snapshot 之后报告了更新的 cwd，则按 cwd report 闭环比较前后 label：真实变化时发送最终 label 的 `tab.renamed`，Prowl 随后 refresh snapshot。这样首帧和后续 runtime 校正都使用同一套规则。

### 6. Prowl 侧

Prowl 的 wire model 只解码 server 返回的 `label` 和 `custom_name`。Prowl 不再从 pane cwd 反推 Herdr 的自动名，也不把 process cwd 当成 tab 的 canonical label。

native tab bar 的目录段规则如下：

- 有 `customName`：使用 server label，linked-worktree 不覆盖；
- 无 `customName`：默认使用 server label；有 server worktree provenance 时，可以在显示层增加 linked-worktree rich presentation；
- process title 和 agent icon 始终作为独立装饰保留。

清空菜单只在 server 返回 `customName` 时显示。点击后发送 `tab.rename(label: null)`，等待 Herdr 的 event 或 snapshot 确认，不在本地伪造最终状态。

### 7. 兼容和边界

`custom_name` 是新增的对外可选字段，但语义来自 Herdr 已有内部状态；`label` 本身保持现有字段名。旧 snapshot 没有 `custom_name` 时按未手动命名处理。

此前只在本地开发分支中引入的 `custom_label` 不作为迁移字段保留。它没有稳定的持久化契约，清理代码、schema、文档和测试即可。

## 六、实现步骤

### Herdr

1. 删除当前 WIP 的 `automatic_name`、`Tab::display_name` 及全部构造、restore 和测试引用。
2. 在 `AppState` 集中实现 canonical label helper，迁移所有生产 projection，并移除 `Workspace::tab_display_name` 的数字生产路径。
3. 将 tab API 字段从 `custom_label` 对齐为 `custom_name`；实现 rename trim、空白拒绝和 `null` 清空契约。
4. 按本文事件表接入 cwd、pane focus、tab/workspace focus、pane move 和 tab move，不增加 polling、进程或新持久化字段。
5. 保证 restore 完成状态解析后才生成首个 snapshot/attach label。
6. 更新 Herdr tab bar、Navigator、mobile、window title、snapshot、move、rename 和 restore 的行为测试。
7. 清理 `custom_label` 的 schema、next docs、changelog 和测试数据，并以全仓搜索确认废弃标识归零。

### Prowl

1. 将 `HerdrTab` 解码字段改为 `customName`，移除 custom label compatibility inference。
2. 让 tab directory segment 以 server label 为来源，process title、agent icon、linked-worktree 只做 decoration。
3. 删除 tab projection 内的 Git subprocess、worktree path polling 和 `automaticDirectoryName` 计算。
4. 保留 context menu、rename sheet 和 nullable reset request；将 `tab.renamed`、`pane.focused`、`tab.focused`、`workspace.focused`、`pane.moved`、`tab.moved`、`tab.created` 和 `tab.closed` 明确接入 snapshot refresh。
5. 更新 `HerdrTabBarViewTests` 和 chrome reducer tests，覆盖手动名、同 cwd 手动名、clear、focus/move event refresh、process、agent icon 和 linked-worktree decoration。
6. 同步更新 Clean Mode 文档和现有 native chrome 设计文档。

## 七、验收标准

### Herdr

- 未命名 tab 显示 cwd basename，不显示数字序号；
- cwd 变化和 pane focus 变化能更新自动 label；
- 手动名称在 cwd、process、agent、worktree 变化后保持；
- 手动名与 cwd 相同时仍保持手动状态；
- clear 后恢复当前 cwd basename；
- Goto、mobile、window title、attach、snapshot、tab API 的 label 一致；
- focused cwd、pane focus 和 pane move 只为实际 label 变化的 tab 发送最终 `tab.renamed`；
- tab focus/workspace focus 会刷新 selection snapshot，但单纯 focus 不发送 rename；
- `tab.move` 纯重排不发送 rename，`pane.move` 正确处理 source/target/create/close；
- 空字符串或纯空白 rename 被拒绝，状态中不存在空 `custom_name`；
- restore 后首个 snapshot/attach 已经使用 restored focus cwd 的 canonical label；
- restore/create/move 路径不引入第二份自动名称状态；
- 没有新增进程、polling 或 Git 查询。

### Prowl

- `customName` 存在时使用 server label 并显示 reset 入口；
- `customName` 为空时使用 server label，不进行 legacy 字符串推断；
- clear 后以 server event/snapshot 为准恢复自动名称；
- `tab.renamed` 必然触发 snapshot refresh，并从 snapshot 同步 `label + customName`；
- pane/tab/workspace focus 和 move lifecycle 按事件契约刷新 snapshot；
- process title 和 agent icon 与目录段独立；
- linked-worktree 只使用 server provenance，不能覆盖手动目录段；
- decoration 变化不会触发 Herdr rename；
- tab projection 不启动 Git 子进程或 cwd polling。

## 八、验证

实现后按仓库规则执行 focused tests、Herdr `just check`、Prowl `make check` 和相关测试。Prowl app-side 验证必须执行 `make install-dev-build`，不能只停留在编译产物。

Herdr binary 替换后还要验证新进程的 executable path/inode、PID 以及既有 panes/sessions 是否保留。安装 Prowl Debug app 后，必须在实际运行环境逐项验证：

- Clean Mode 未命名 tab 显示 cwd basename；
- 在 pane 中 `cd` 后 Clean native tab bar、Herdr attach 和 Goto/Navigator 显示一致；
- pane focus 和 tab focus 后名称与 selection 一致；
- `tab.move` 只改变顺序，`pane.move` 只更新实际受影响的 label；
- 手动重命名后 process title 和 agent icon 仍保留；
- 手动名称与 cwd 相同时仍显示 reset 入口并保持手动状态；
- **Use Automatic Directory Name** 和 rename sheet 的 **Use Automatic Name** 都能恢复当前 cwd；
- linked-worktree 有 server provenance 时正确装饰，无 provenance 时不启动 Git 探测；
- 重启/restore 后首个 snapshot、attach、Goto 和 native tab bar 不短暂显示数字名称。

本文件只描述最终需求和实施边界，不修改 Herdr 的 `agent session title` 文档，也不把 tab name 逻辑混入 agent session title 功能。
