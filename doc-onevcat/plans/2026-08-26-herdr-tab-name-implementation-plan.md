# Herdr Tab Name Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立唯一的 Herdr canonical tab label 契约，使自动目录名、手动名称保持、明确 reset，以及 Prowl native tab decoration 在所有 Herdr/Prowl 入口保持一致。

**Architecture:** Herdr `AppState` 持有唯一的 canonical label helper；输入固定为 workspace/tab、focused pane、内存中的 `TerminalState.cwd` 和已有 `Tab.custom_name`。`TabInfo.label` 是 helper 计算后的 server 输出，不是第二份持久化字段；Herdr 在 cwd/focus/move/rename 生命周期中发送最终 label 事件，Prowl 将事件作为 snapshot invalidation，并仅在 server label 外叠加 process、agent icon 和 server worktree provenance。

**Tech Stack:** Rust、Tokio、Serde、schemars、Ratatui、Herdr JSON socket API、Swift 6.2、SwiftUI、The Composable Architecture、Swift Testing、`xcodebuild`、`make install-dev-build`。

**Spec:** `doc-onevcat/plans/2026-08-26-herdr-tab-name-design.md`

## Global Constraints

- 不新增 `automatic_name`、`automatic_label` 或第二个 custom-name 状态。
- 复用已有 `Tab.custom_name`；API 对外字段固定为 `custom_name`，Swift 解码名固定为 `customName`。
- `TabInfo.label` 是 canonical current label；任何生产 `Workspace::tab_display_name` 路径都不能继续返回 tab index。
- canonical label 只使用内存状态：tab layout focus、terminal identity、`TerminalState.cwd` 和 `custom_name`；禁止直接复用 `src/workspace/git/discovery.rs::fallback_label_from_cwd`，因为 tab label 必须有自己的纯内存 basename/fallback 规则。
- tab cwd 规则固定为：有效 UTF-8、非空 cwd 的原始 basename（保留 basename 开头或结尾的空格）；根目录、空字符串、非 UTF-8、无 basename 或其他无效 cwd 一律显示非数字的 `Terminal`。`HOME` 没有特殊别名，按其原始 basename 处理。任何分支都不得返回空字符串或 tab 序号。
- 不新增 shell plugin、辅助进程、cwd polling、render-time Git/文件系统 I/O、socket 写循环或 persistence 线程。
- `tab.rename` 仅用 `null` 表达 clear；空字符串或纯空白返回 `invalid_params`，不得保存 `Some("")`。
- `TabRenamed` 携带最终 `label`；Prowl 收到后 refresh `session.snapshot`，不在本地拼装最终 tab state。
- `custom_label` -> `custom_name` 是 additive JSON API contract：Herdr `PROTOCOL_VERSION` 保持 21，Prowl 只支持 protocol 21；19/20 和未来 protocol 22 在 snapshot/render 前拒绝，不得静默显示数字或丢失手动名。
- `tab.move` 是纯重排，不发送 `tab.renamed`；`pane.move` 只对实际变化的 source/target tab 发送 rename。
- restore 后首个 snapshot 必须已经使用 resolved focused-pane cwd，不能短暂暴露数字 label。
- 任何可测量或用户可感知的性能回退，都必须在实现前停止并请求确认。
- Herdr 使用 `just test-one`/`just check`；`just test-one` 的 positional filter 只使用合法的完整 test name，不使用 regex wildcard；Prowl 使用仓库内 `xcodebuild test`、`make check` 和 `make test`。
- Prowl app-side 验证必须运行 `make install-dev-build`；仅编译成功不构成交付证据。
- 保留无关 working-copy 内容，尤其是 Herdr 的 `2026-08-25-agent-session-title-plan.md` 和 `2026-08-25-agent-session-title-spec.md`。

---

## 文件职责

### Herdr

- `src/workspace.rs`：删除 numeric production label 入口；workspace identity 继续与 tab label 分离。
- `src/workspace/tab.rs`：只保留 `custom_name`；清理 `automatic_name`、`Tab::display_name` 及构造引用。
- `src/app/actions.rs`：实现 `AppState` canonical label helper、AppState-owned pane detail projection 和 focused tests。
- `src/app/api.rs`：在 cwd/focus mutation 前后比较 label，并发送最终 `tab.renamed`。
- `src/app/creation.rs`：所有 `TabInfo` 从 canonical helper 生成，并返回 `custom_name`。
- `src/app/api/tabs.rs`：rename normalization、nullable clear、final-label event 和 tab.move 语义。
- `src/app/api/panes.rs`：pane.move 前后比较 source/target label，只发真实变化。
- `src/api/schema/tabs.rs`、`src/api/schema/tests.rs`：稳定 `label + custom_name` wire contract。
- `src/protocol/wire.rs`：保持 `PROTOCOL_VERSION` 为 21；19/20 按现有 mismatch path 拒绝，protocol 21 保持兼容。
- `src/persist/restore.rs`、`src/persist/snapshot.rs`：仅持久化 `custom_name`，首个 snapshot 使用 restored focus cwd。
- `src/workspace/aggregate.rs`、`src/ui.rs`、`src/ui/*.rs`、`src/app/input/*.rs`、`src/app/window_title.rs`、`src/app/api/plugins/context.rs`：迁移所有 production projection。
- `src/server/notifications.rs`、`src/server/headless.rs`、`src/app/api.rs`：迁移 notification/toast caller；`notification_context` 接收 `&AppState`，通过 `state.tab_canonical_label(ws_idx, tab_idx)` 读取 tab label，不再从 `Workspace` 读取。
- `docs/next/api/herdr-api.schema.json`、`docs/next/website/src/content/docs/socket-api.mdx`、`docs/next/CHANGELOG.md`：清理 `custom_label` 并记录最终契约。

### Prowl

- `supacode/Infrastructure/Herdr/HerdrWireModels.swift`：解码 `custom_name` 为 `customName`，删除 compatibility inference 字段。
- `supacodeTests/HerdrInputContextTests.swift`、`supacodeTests/CleanAppFeatureTests.swift`：验证 Prowl 只支持 protocol 21，19/20/22 被拒绝并隐藏 native chrome。
- `supacode/Infrastructure/Herdr/HerdrSocketClient.swift`：保持 terminal chrome lifecycle subscription 完整，不加 polling。
- `supacode/Features/Clean/HerdrTerminalChromeFeature.swift`：rename/focus/move/create/close event 都进入 snapshot refresh。
- `supacode/Features/Clean/HerdrTabBarView.swift`：server label 是 directory segment 来源，decorations 独立，删除 Git subprocess fallback。
- `supacodeTests/HerdrTerminalChromeTests.swift`：覆盖 event-to-snapshot、generation 和 reset lifecycle。
- `supacodeTests/HerdrTabBarViewTests.swift`：覆盖 `customName`、server label precedence 和 decorations。
- `docs/components/clean-mode.md`：同步用户行为与 no-extra-cost 原则。

## Task 1: 清理 WIP 状态并建立 AppState canonical helper

**Files:**
- Modify: `/Users/yam/Developer/herdr/src/workspace/tab.rs`
- Modify: `/Users/yam/Developer/herdr/src/workspace.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/actions.rs`
- Test: `/Users/yam/Developer/herdr/src/app/actions.rs`

**Interfaces:**
- Consumes: `Workspace.tabs`、`Tab.layout.focused()`、`Tab.terminal_id()`、`AppState.terminals`、`TerminalState.cwd`、`Tab.custom_name`。
- Produces:

```rust
pub(crate) fn tab_canonical_label(&self, ws_idx: usize, tab_idx: usize) -> Option<String>;
pub(crate) fn tab_canonical_label_for_pane(
    &self,
    ws_idx: usize,
    tab_idx: usize,
    pane_id: PaneId,
) -> Option<String>;

fn tab_cwd_label_from_cwd(cwd: &std::path::Path) -> String;
```

- [ ] **Step 1: 先写 canonical label failing tests**

在 `src/app/actions.rs` 的 module scope（与现有 `#[cfg(test)] mod tests` 同级）添加一个由测试全程持有的真实目录 fixture；fixture 创建并持有 `root/Prowl`、`root/Backend`、`root/Old`、`root/New`，测试结束时由 guard 清理。所有 cwd 写入都必须使用 fixture 中已创建的路径，不能使用硬编码的未创建目录。

```rust
#[cfg(test)]
pub(crate) mod test_support {
pub(crate) struct CwdFixture {
    pub(crate) root: std::path::PathBuf,
    pub(crate) prowl: std::path::PathBuf,
    pub(crate) backend: std::path::PathBuf,
    pub(crate) old: std::path::PathBuf,
    pub(crate) new: std::path::PathBuf,
    pub(crate) corrected: std::path::PathBuf,
    pub(crate) other: std::path::PathBuf,
    pub(crate) trailing_space: std::path::PathBuf,
}

impl Drop for CwdFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub(crate) fn cwd_fixture() -> CwdFixture {
    let root = std::env::temp_dir().join(format!(
        "herdr-tab-label-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let fixture = CwdFixture {
        prowl: root.join("Prowl"),
        backend: root.join("Backend"),
        old: root.join("Old"),
        new: root.join("New"),
        corrected: root.join("Corrected"),
        other: root.join("Other"),
        trailing_space: root.join("Trailing Space "),
        root,
    };
    std::fs::create_dir_all(&fixture.prowl).unwrap();
    std::fs::create_dir_all(&fixture.backend).unwrap();
    std::fs::create_dir_all(&fixture.old).unwrap();
    std::fs::create_dir_all(&fixture.new).unwrap();
    std::fs::create_dir_all(&fixture.corrected).unwrap();
    std::fs::create_dir_all(&fixture.other).unwrap();
    std::fs::create_dir_all(&fixture.trailing_space).unwrap();
    fixture
}
}
```

`test_support::CwdFixture`、所有字段和 `cwd_fixture()` 都是 `pub(crate)`；`Drop` 实现保持在该 module 内。`src/app/actions.rs`、`src/app/api/tabs.rs`、`src/app/api.rs`、`src/app/api/session.rs` 和各 projection test module 都通过 `crate::app::actions::test_support::{cwd_fixture, CwdFixture}` 复用该 fixture，不得各自改回字符串 cwd；返回的 guard 必须一直存活到对应 assertion 完成。

然后在当前 test module 添加：

```rust
#[test]
fn tab_canonical_label_uses_focused_terminal_cwd() {
    let fixture = cwd_fixture();
    let mut state = AppState::test_new();
    state.workspaces = vec![Workspace::test_new("workspace")];
    state.ensure_test_terminals();
    let pane_id = state.workspaces[0].tabs[0].layout.focused();
    let terminal_id = state.workspaces[0].terminal_id(pane_id).unwrap().clone();
    state.terminals.get_mut(&terminal_id).unwrap().cwd = fixture.prowl.clone();

    assert_eq!(state.tab_canonical_label(0, 0).as_deref(), Some("Prowl"));
}

#[test]
fn tab_canonical_label_preserves_manual_name_equal_to_cwd() {
    let fixture = cwd_fixture();
    let mut state = AppState::test_new();
    state.workspaces = vec![Workspace::test_new("workspace")];
    state.ensure_test_terminals();
    let pane_id = state.workspaces[0].tabs[0].layout.focused();
    let terminal_id = state.workspaces[0].terminal_id(pane_id).unwrap().clone();
    state.terminals.get_mut(&terminal_id).unwrap().cwd = fixture.prowl.clone();
    state.workspaces[0].tabs[0].set_custom_name("Prowl".into());

    assert_eq!(state.tab_canonical_label(0, 0).as_deref(), Some("Prowl"));
    assert_eq!(state.workspaces[0].tabs[0].custom_name.as_deref(), Some("Prowl"));
}

#[test]
fn tab_canonical_label_uses_terminal_fallback_without_terminal_state() {
    let mut state = AppState::test_new();
    state.workspaces = vec![Workspace::test_new("workspace")];

    assert_eq!(state.tab_canonical_label(0, 0).as_deref(), Some("Terminal"));
}

#[test]
fn tab_cwd_label_handles_home_root_empty_and_invalid_cwd_without_numeric_or_empty_label() {
    let fixture = cwd_fixture();
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    if let Some(home) = home {
        let expected = home.file_name().and_then(|name| name.to_str()).unwrap_or("Terminal");
        assert_eq!(tab_cwd_label_from_cwd(&home), expected);
    }
    assert_eq!(tab_cwd_label_from_cwd(std::path::Path::new("/")), "Terminal");
    assert_eq!(tab_cwd_label_from_cwd(std::path::Path::new("")), "Terminal");
    assert_eq!(tab_cwd_label_from_cwd(std::path::Path::new("bad\0cwd")), "Terminal");
    assert_eq!(tab_cwd_label_from_cwd(&fixture.prowl), "Prowl");
    assert_eq!(tab_cwd_label_from_cwd(&fixture.trailing_space), "Trailing Space ");
    assert_ne!(tab_cwd_label_from_cwd(&fixture.prowl), "1");
    assert!(!tab_cwd_label_from_cwd(&fixture.prowl).is_empty());
}
```

- [ ] **Step 2: 运行 tests，确认因为 helper 不存在而失败**

```bash
cd /Users/yam/Developer/herdr
just test-one tab_canonical_label_uses_focused_terminal_cwd
just test-one tab_cwd_label_handles_home_root_empty_and_invalid_cwd_without_numeric_or_empty_label
```

Expected: compile/test FAIL，失败原因是 `tab_canonical_label` 尚不存在；不能先写 production code 再补测试。

- [ ] **Step 3: 清理完整的 WIP automatic state**

先执行：

```bash
cd /Users/yam/Developer/herdr
rg -n "automatic_name|Tab::display_name|Workspace::tab_display_name|active_tab_display_name|\.tab_display_name\(" src tests
```

删除 `Tab.automatic_name`、tab naming 用的 `Tab::display_name`、`Tab::new_with_runtime`/`Tab::from_existing_pane` 初始化、restore/test 中各处 `Tab` 结构体字面量里的该字段，以及只服务这些 WIP 字段的测试。不得用另一个 stored automatic field 替换。

- [ ] **Step 4: 在 AppState 中实现唯一 helper**

在 `src/app/actions.rs` 的 `impl AppState` 中实现，并在同一模块内定义纯内存 `tab_cwd_label_from_cwd`；这个函数只读取传入的 `Path`，不调用 `canonicalize`、`metadata`、Git、runtime cwd、`HOME` alias 或进程树：

```rust
pub(crate) fn tab_canonical_label(&self, ws_idx: usize, tab_idx: usize) -> Option<String> {
    let workspace = self.workspaces.get(ws_idx)?;
    let tab = workspace.tabs.get(tab_idx)?;
    self.tab_canonical_label_for_pane(ws_idx, tab_idx, tab.layout.focused())
}

pub(crate) fn tab_canonical_label_for_pane(
    &self,
    ws_idx: usize,
    tab_idx: usize,
    pane_id: PaneId,
) -> Option<String> {
    let workspace = self.workspaces.get(ws_idx)?;
    let tab = workspace.tabs.get(tab_idx)?;
    if !tab.panes.contains_key(&pane_id) {
        return None;
    }
    if let Some(custom_name) = tab
        .custom_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
    {
        return Some(custom_name.to_string());
    }
    let cwd = tab
        .terminal_id(pane_id)
        .and_then(|terminal_id| self.terminals.get(terminal_id))
        .map(|terminal| terminal.cwd.as_path());
    Some(cwd.map(tab_cwd_label_from_cwd).unwrap_or_else(|| "Terminal".into()))
}

fn tab_cwd_label_from_cwd(cwd: &std::path::Path) -> String {
    let Some(raw) = cwd.to_str().filter(|raw| !raw.is_empty()) else {
        return "Terminal".into();
    };
    if raw.contains('\0') {
        return "Terminal".into();
    }
    let path = std::path::Path::new(raw);
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty() && *name != "." && *name != "..")
        .map(str::to_string)
        .unwrap_or_else(|| "Terminal".into())
}
```

helper 不得读取 Git、文件系统、runtime cwd、process tree 或 Prowl decoration。

- [ ] **Step 5: 运行 focused tests**

```bash
cd /Users/yam/Developer/herdr
just test-one tab_canonical_label_uses_focused_terminal_cwd
just test-one tab_canonical_label_preserves_manual_name_equal_to_cwd
just test-one tab_canonical_label_uses_terminal_fallback_without_terminal_state
just test-one tab_cwd_label_handles_home_root_empty_and_invalid_cwd_without_numeric_or_empty_label
```

Expected: 四个测试 PASS；`rg` 不再发现 tab naming WIP `automatic_name`/`Tab::display_name`。

- [ ] **Step 6: 经 review 后提交 Task 1**

先向维护者提出 commit message：`feat: add canonical tab label resolution`。确认后只提交本 Task 的 Herdr 文件。

## Task 2: 将所有 Herdr production projection 迁移到 AppState label

**Files:**
- Modify: `/Users/yam/Developer/herdr/src/app/actions.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/creation.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/session.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/plugins/context.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/window_title.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/input/modal.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/input/navigate.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/input/sidebar.rs`
- Modify: `/Users/yam/Developer/herdr/src/workspace/aggregate.rs`
- Modify: `/Users/yam/Developer/herdr/src/ui.rs`
- Modify: `/Users/yam/Developer/herdr/src/ui/tabs.rs`
- Modify: `/Users/yam/Developer/herdr/src/ui/navigator.rs`
- Modify: `/Users/yam/Developer/herdr/src/ui/mobile.rs`
- Modify: `/Users/yam/Developer/herdr/src/ui/sidebar.rs`
- Modify: `/Users/yam/Developer/herdr/src/server/notifications.rs`
- Modify: `/Users/yam/Developer/herdr/src/server/headless.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api.rs`
- Test: 上述文件中的 inline test modules

**Interfaces:**
- Consumes: Task 1 `AppState::tab_canonical_label`。
- Produces:

```rust
pub(crate) fn pane_details_for_workspace(&self, ws_idx: usize) -> Vec<PaneDetail>;

#[derive(Clone)]
pub(crate) struct TabBarProjection {
    pub(crate) items: Vec<TabBarItemProjection>,
    pub(crate) hit_areas: Vec<Rect>,
}

pub(crate) fn compute_tab_bar_projection(
    app: &AppState,
    ws_idx: usize,
) -> TabBarProjection;

pub(super) fn render_tab_bar(
    app: &AppState,
    projection: &TabBarProjection,
    frame: &mut Frame,
    area: Rect,
);
```

以及所有 production surface 的统一 label。

- [ ] **Step 1: 为 production projections 写 failing characterization tests**

在各自 test module 加入由 Task 1 同样规则创建并持有的真实临时目录 projection assertions；fixture 的 `Prowl` 目录必须在写入 `TerminalState.cwd` 前创建，测试结束后再清理。Navigator 示例：

```rust
#[test]
fn navigator_rows_use_canonical_tab_label() {
    let fixture = cwd_fixture();
    let mut state = AppState::test_new();
    state.workspaces = vec![Workspace::test_new("workspace")];
    state.ensure_test_terminals();
    let pane_id = state.workspaces[0].tabs[0].layout.focused();
    let terminal_id = state.workspaces[0].terminal_id(pane_id).unwrap().clone();
    state.terminals.get_mut(&terminal_id).unwrap().cwd = fixture.prowl.clone();

    let rows = state.navigator_rows();

    assert!(rows.iter().any(|row| row.is_tab && row.label == "Prowl"));
    assert!(!rows.iter().any(|row| row.is_tab && row.label == "1"));
}
```

分别增加这些明确断言：

- `src/ui/tabs.rs`：rendered tab row 包含 `Prowl`，且 width 根据 `Prowl` 计算；
- `src/ui/mobile.rs`：header/switcher 包含 `Prowl`，不含 `tab 1`；
- `src/app/window_title.rs`：tab token 输出 `Prowl`；
- `src/app/api/plugins/context.rs`：`PluginInvocationContext.tab_label == Some("Prowl")`；
- `src/app/api/session.rs`：首个 `TabInfo.label == "Prowl"`；
- `src/ui/sidebar.rs`：`PaneDetail.tab_label` 和 grouped agent label 使用 `Prowl`。

对应 test names 固定为 `tab_bar_renders_canonical_cwd_label_and_width`、`mobile_switcher_renders_canonical_cwd_label`、`window_title_uses_canonical_tab_label`、`session_snapshot_uses_canonical_tab_label`、`plugin_context_uses_canonical_tab_label` 和 `agent_panel_uses_canonical_tab_label`，后续 `just test-one` 逐一使用这些完整名称。

notification/toast caller 必须保持 workspace context 的现有格式，但把 tab label 的读取入口收敛到 AppState：

```rust
pub fn notification_context(
    state: &AppState,
    workspace_label: &str,
    ws_idx: usize,
    pane_id: PaneId,
) -> String {
    let mut context = format!("{} · {}", workspace_label, ws_idx + 1);
    let Some(workspace) = state.workspaces.get(ws_idx) else { return context };
    if workspace.tabs.len() > 1 {
        if let Some(tab_idx) = workspace.find_tab_index_for_pane(pane_id) {
            if let Some(label) = state.tab_canonical_label(ws_idx, tab_idx) {
                context.push_str(&format!(" · {label}"));
            }
        }
    }
    context
}
```

`src/server/notifications.rs`、`src/server/headless.rs`、`src/app/api.rs` 和 `src/app/actions.rs` 的所有 caller 都传 `&AppState`（`self.state` 或 `&self.app.state`）；`workspace_label` 仍由现有 workspace projection 提供，不能把 runtime cwd 作为 tab label 传入。

- [ ] **Step 2: 运行 projection tests，确认 numeric production path 使其失败**

```bash
cd /Users/yam/Developer/herdr
just test-one navigator_rows_use_canonical_tab_label
just test-one tab_bar_renders_canonical_cwd_label_and_width
just test-one mobile_switcher_renders_canonical_cwd_label
just test-one window_title_uses_canonical_tab_label
just test-one session_snapshot_uses_canonical_tab_label
just test-one plugin_context_uses_canonical_tab_label
```

Expected: 自动 tab 的 production projection 仍读取 `Workspace::tab_display_name`，因此至少对应 tests FAIL。

- [ ] **Step 3: 固定 tab bar layout API 为 AppState owner**

将 `compute_tab_bar_view`、`layout_tab_hit_areas`、`tab_width`、`tab_chrome_label` 的生产签名改为接收 `&AppState` 与 `ws_idx`：

```rust
pub(crate) fn compute_tab_bar_view(
    app: &AppState,
    ws_idx: usize,
    area: Rect,
    current_scroll: usize,
    follow_active: bool,
    mouse_chrome: bool,
) -> TabBarView;
```

`refresh_tab_bar_view` 和 `src/ui.rs::compute_view` 两个 production caller 都传 `self/app + ws_idx`。`compute_view` 只调用一次 `compute_tab_bar_projection`，把返回的 projection 和 `hit_areas` 放入 `ViewState.tab_bar_projection`/`ViewState.tab_hit_areas`；`render_tab_bar` 只接收并消费这份 projection，不能在 render 期间重新解析 label。geometry/render 只能消费 helper 返回的数据，不能自行查询 runtime、Git 或文件系统。

- [ ] **Step 3a: 固定一次 tab projection 的 no-extra-cost gate**

在 `src/ui/tabs.rs` 定义 `TabBarProjection { items, hit_areas }`，一次计算每个 tab 的 canonical label、display width 和 hit-area 所需数据；`src/ui.rs::compute_view` 将它传入 `render_tab_bar`，并将同一 `hit_areas` 写入 `ViewState`，render 与 hit-area layout 共同消费同一份 `items`，不能各自再次调用 helper。增加仅在 `#[cfg(test)]` 生效的 counter，并让测试走真实 `compute_view -> render_tab_bar` production path：

```rust
#[test]
fn tab_bar_projection_resolves_each_tab_once() {
    let fixture = cwd_fixture();
    let mut app = AppState::test_new();
    app.workspaces = vec![Workspace::test_new("workspace")];
    app.ensure_test_terminals();
    let pane_id = app.workspaces[0].tabs[0].layout.focused();
    let terminal_id = app.workspaces[0].terminal_id(pane_id).unwrap().clone();
    app.terminals.get_mut(&terminal_id).unwrap().cwd = fixture.prowl.clone();
    compute_view(&mut app, Rect::new(0, 0, 120, 24));
    let projection = app.view.tab_bar_projection.clone();
    let tab_count = app.workspaces[0].tabs.len();
    let backend = TestBackend::new(120, 24);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|frame| render_tab_bar(&app, &projection, frame, app.view.tab_bar_rect))
        .unwrap();
    assert_eq!(app.view.canonical_label_calls, tab_count);
    assert_eq!(app.view.tab_hit_areas, projection.hit_areas);
    assert!(projection.items.iter().all(|item| !item.label.is_empty()));
}
```

`compute_view` 沿用现有 `compute_view(&mut AppState, Rect)` 签名；在 `ViewState` 增加共享的 `tab_bar_projection`，并让 `compute_view_internal` 将同一 projection 传给 `render_tab_bar`、同时把其 `hit_areas` 存入 `ViewState.tab_hit_areas`。`canonical_label_calls` 仅在 `#[cfg(test)]` 记录真实 production projection 次数，不得新增独立 test-only projection helper。运行 `just test-one tab_bar_projection_resolves_each_tab_once`，以真实一次 projection/每 tab 一次 label resolution 作为 no-extra-cost gate。

按 `herdr/AGENTS.md` 的 multiplicative performance 规则，在固定 geometry 下记录现有 benchmark 的 1、15、50 cardinality before/after 报告，覆盖 background workspace 与 active pane；执行：

```bash
cd /Users/yam/Developer/herdr
just bench-render-scale | tee /tmp/herdr-tab-name-render-scale.txt
```

该 recipe 的真实输出只有两组 `background-workspace resize/layout (one pane each)` 与 `active panes (one workspace)`，每组 cardinality `1/15/50` 和字段 `median_us`、`p95_us`、`max_us`、`median_vs_1x`、`p95_vs_1x`。将 before/after 原样保存，并报告 15/1、50/1 的 median 与 p95 ratio；不要声称该命令提供 projection/render 分离或 allocation/CPU 指标。production canonical-label counter 由 `tab_bar_projection_resolves_each_tab_once` 单独证明。

- [ ] **Step 4: 固定 agent/sidebar detail API 为 AppState owner**

将 `Tab::pane_details` 在 `src/workspace/aggregate.rs` 中改为 `pub(crate)`，保留其 terminal metadata assembly。删除 `Workspace::pane_details` 中自行计算 tab label 的逻辑，并在 `impl AppState` 添加：

```rust
pub(crate) fn pane_details_for_workspace(&self, ws_idx: usize) -> Vec<PaneDetail> {
    let Some(workspace) = self.workspaces.get(ws_idx) else { return Vec::new() };
    let multi_tab = workspace.tabs.len() > 1;
    workspace
        .tabs
        .iter()
        .enumerate()
        .flat_map(|(tab_idx, tab)| {
            let label = self
                .tab_canonical_label(ws_idx, tab_idx)
                .unwrap_or_else(|| "Terminal".into());
            tab.pane_details(&self.terminals, tab_idx, &label)
        })
        .map(|mut detail| {
            if multi_tab {
                detail.label = format!("{}·{}", detail.tab_label, detail.agent_label);
            }
            detail
        })
        .collect()
}
```

更新 `src/ui/sidebar.rs` 和相关 tests 使用该 AppState API。

- [ ] **Step 5: 迁移全部 remaining callers 并删除数字 fallback**

在文件职责中列出的 production caller 统一调用 `tab_canonical_label` 或 `pane_details_for_workspace`。删除所有把 `(tab_idx + 1).to_string()` 用作 visible label 的表达式；仅在 stable identity、order 或 count 场景保留 number/index。

完成后运行：

```bash
cd /Users/yam/Developer/herdr
rg -n "tab_display_name|active_tab_display_name|\(tab_idx \+ 1\)\.to_string\(\)" src
```

Expected: 不存在 production visible-label numeric path；若保留 test-only helper，必须不被 production caller 引用。

`src/ui.rs` 的 `compute_view`、`src/server/notifications.rs`、`src/server/headless.rs`、`src/app/api.rs` 的 notification/toast 路径必须在本步完成迁移；`notification_context` 内只允许调用 `AppState::tab_canonical_label`，不得重新实现 basename 或 fallback。

`src/ui/mobile.rs` 必须删除 `mobile_tab_status(&Workspace)` 对 `ws.active_tab`、`tab_display_name` 和 `(ws.active_tab + 1).to_string()` 的 visible-label fallback；改为接收 `&AppState + ws_idx`，用 `tab_canonical_label(ws_idx, active_tab)` 生成 tab 名称。mobile switcher 的每个 item 同样直接读取 canonical label，不能用 `(idx + 1).to_string()` 补 label；若保留数字，只能作为明确的顺序/count decoration，不能在自动 tab 名缺失时显示。

在删除 fallback 后运行实际形式的静态 gate：

```bash
cd /Users/yam/Developer/herdr
rg -n "ws\.active_tab\s*\+\s*1|active_tab\s*\+\s*1|\bidx\s*\+\s*1|\btab_idx\s*\+\s*1|tab_display_name\(|active_tab_display_name\(|unwrap_or_else\(\|\|.*to_string" \
  src/ui/mobile.rs src/ui/tabs.rs src/ui.rs
```

Expected: no match in a visible tab-label fallback branch；任何保留的 `+ 1` 都必须位于明确的顺序/count decoration，并由对应 test 证明不是 canonical label fallback。

`src/app/input/modal.rs` 的 `Mode::RenameTab` 同步改为：输入 trim 后只要 nonblank，就无条件写入 `tab.custom_name`，即使输入与当前 canonical cwd label 相同；删除 `keep_auto_name` 这种 label/cwd 相等推断。新增 `rename_tab_same_as_cwd_saves_custom_name` TUI test，使用真实 fixture cwd=`Prowl`、输入 `Prowl`，断言 `custom_name == Some("Prowl")`。自动恢复不通过输入 cwd 名称实现，仍由 API `tab.rename(label: null)` 单独表达 reset。

TUI 新 tab prompt 必须区分“未修改的 numeric placeholder”和用户显式输入的数字：只有 `name_input_replace_on_type == true` 且用户没有编辑时，当前 tab 序号 placeholder（例如 `2`）才映射为 `requested_new_tab_name = None`；用户实际输入 `2` 后必须走 `Some("2")`，由 `tab.create.label` 保存为 `custom_name=Some("2")`。新增 `tui_tab_create_unmodified_numeric_placeholder_stays_auto` 与 `tui_tab_create_explicit_numeric_name_saves_custom_name`，分别断言 placeholder 自动 tab 和显式数字手动 tab。

- [ ] **Step 6: 运行所有 projection tests**

```bash
cd /Users/yam/Developer/herdr
just test-one navigator_rows_use_canonical_tab_label
just test-one tab_bar_renders_canonical_cwd_label_and_width
just test-one mobile_switcher_renders_canonical_cwd_label
just test-one window_title_uses_canonical_tab_label
just test-one session_snapshot_uses_canonical_tab_label
just test-one plugin_context_uses_canonical_tab_label
just test-one agent_panel_uses_canonical_tab_label
```

Expected: 所有自动 tab 显示 cwd basename；manual tab 显示 `custom_name`；production surface 不再输出数字名称。

- [ ] **Step 7: 经 review 后提交 Task 2**

先提出：`feat: project canonical labels across herdr views`。确认后提交 projection 与 tests。

## Task 3: 对齐 Tab API、rename validation 和 schema

**Files:**
- Modify: `/Users/yam/Developer/herdr/src/api/schema/tabs.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/creation.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/tabs.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/input/modal.rs`
- Modify: `/Users/yam/Developer/herdr/src/api/schema/tests.rs`
- Modify: `/Users/yam/Developer/herdr/src/protocol/wire.rs`
- Modify: `/Users/yam/Developer/herdr/docs/next/api/herdr-api.schema.json`
- Modify: `/Users/yam/Developer/herdr/docs/next/website/src/content/docs/socket-api.mdx`
- Modify: `/Users/yam/Developer/herdr/docs/next/CHANGELOG.md`
- Test: `/Users/yam/Developer/herdr/src/app/api/tabs.rs`
- Test: `/Users/yam/Developer/herdr/src/app/input/modal.rs`
- Test: `/Users/yam/Developer/herdr/src/protocol/wire.rs`

**Interfaces:**
- Consumes: Task 1 helper 和 Task 2 `TabInfo` projection。
- Produces:

```rust
pub struct TabInfo {
    pub label: String,
    pub custom_name: Option<String>,
    // existing identity/status fields remain unchanged
}

pub struct TabRenameParams {
    pub tab_id: String,
    pub label: Option<String>,
}
```

- [ ] **Step 1: 添加 test-only API decoder helpers**

在 `src/app/api/tabs.rs` test module 添加：

```rust
fn decode_tab_info(response: &str) -> crate::api::schema::TabInfo {
    let response: crate::api::schema::SuccessResponse = serde_json::from_str(response).unwrap();
    let crate::api::schema::ResponseResult::TabInfo { tab } = response.result else {
        panic!("expected tab_info response");
    };
    tab
}

fn decode_created_tab(response: &str) -> crate::api::schema::TabInfo {
    let response: crate::api::schema::SuccessResponse = serde_json::from_str(response).unwrap();
    let crate::api::schema::ResponseResult::TabCreated { tab, .. } = response.result else {
        panic!("expected tab_created response");
    };
    tab
}

fn decode_error_code(response: &str) -> String {
    serde_json::from_str::<crate::api::schema::ErrorResponse>(response)
        .unwrap()
        .error
        .code
}
```

- [ ] **Step 2: 写 trim、blank、nullable clear failing tests**

```rust
#[test]
fn api_tab_rename_trims_and_rejects_blank_labels() {
    let fixture = cwd_fixture();
    let mut app = app_with_canonical_tab_cwd(fixture.prowl.clone());
    let tab_id = app.public_tab_id(0, 0).unwrap();

    let response = app.handle_tab_rename(
        "trim".into(),
        TabRenameParams { tab_id: tab_id.clone(), label: Some("  Backend  ".into()) },
    );
    let tab = decode_tab_info(&response);
    assert_eq!(tab.label, "Backend");
    assert_eq!(tab.custom_name.as_deref(), Some("Backend"));

    let response = app.handle_tab_rename(
        "blank".into(),
        TabRenameParams { tab_id, label: Some("  \t ".into()) },
    );
    assert_eq!(decode_error_code(&response), "invalid_params");
    assert_eq!(app.state.workspaces[0].tabs[0].custom_name.as_deref(), Some("Backend"));
}

#[test]
fn api_tab_rename_null_restores_current_canonical_label() {
    let fixture = cwd_fixture();
    let mut app = app_with_canonical_tab_cwd(fixture.prowl.clone());
    app.state.workspaces[0].tabs[0].set_custom_name("Backend".into());
    let tab_id = app.public_tab_id(0, 0).unwrap();

    let response = app.handle_tab_rename(
        "clear".into(),
        TabRenameParams { tab_id, label: None },
    );
    let tab = decode_tab_info(&response);
    assert_eq!(tab.label, "Prowl");
    assert_eq!(tab.custom_name, None);
}

#[test]
fn api_tab_create_trims_and_rejects_blank_labels() {
    let fixture = cwd_fixture();
    let mut app = app_with_canonical_tab_cwd(fixture.prowl.clone());
    let workspace_id = app.public_workspace_id(0);

    let created = app.handle_tab_create(
        "create-trim".into(),
        TabCreateParams {
            workspace_id: Some(workspace_id.clone()),
            cwd: Some(fixture.backend.to_string_lossy().into_owned()),
            focus: false,
            label: Some("  Backend  ".into()),
            env: Default::default(),
        },
    );
    let created_tab = decode_created_tab(&created);
    assert_eq!(created_tab.label, "Backend");
    assert_eq!(created_tab.custom_name.as_deref(), Some("Backend"));

    let automatic = app.handle_tab_create(
        "create-auto".into(),
        TabCreateParams {
            workspace_id: Some(workspace_id.clone()),
            cwd: Some(fixture.trailing_space.to_string_lossy().into_owned()),
            focus: false,
            label: None,
            env: Default::default(),
        },
    );
    let automatic_tab = decode_created_tab(&automatic);
    assert_eq!(automatic_tab.label, "Trailing Space ");
    assert_eq!(automatic_tab.custom_name, None);

    let blank = app.handle_tab_create(
        "create-blank".into(),
        TabCreateParams {
            workspace_id: Some(workspace_id),
            cwd: Some(fixture.new.to_string_lossy().into_owned()),
            focus: false,
            label: Some(" \t ".into()),
            env: Default::default(),
        },
    );
    assert_eq!(decode_error_code(&blank), "invalid_params");
    assert!(app
        .state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.tabs.iter())
        .all(|tab| tab.custom_name.as_deref().map_or(true, |name| !name.trim().is_empty())));
}

#[test]
fn api_manual_rename_and_clear_emit_exactly_one_tab_renamed_when_name_equals_cwd() {
    let fixture = cwd_fixture();
    let (mut app, event_hub, _pane_id) = app_with_evented_tab_cwd(fixture.prowl.clone());
    let expected_workspace_id = app.public_workspace_id(0);
    let tab_id = app.public_tab_id(0, 0).unwrap();

    let rename_sequence = event_hub.current_sequence();
    let renamed = app.handle_tab_rename(
        "same-cwd-rename".into(),
        TabRenameParams { tab_id: tab_id.clone(), label: Some("Prowl".into()) },
    );
    assert_eq!(decode_tab_info(&renamed).custom_name.as_deref(), Some("Prowl"));
    let rename_events = event_hub
        .events_after(rename_sequence)
        .into_iter()
        .filter(|(_, event)| matches!(&event.data, EventData::TabRenamed { .. }))
        .collect::<Vec<_>>();
    assert_eq!(rename_events.len(), 1);
    let rename_event = rename_events
        .first()
        .expect("manual rename must emit tab.renamed");
    assert!(matches!(
        &rename_event.1.data,
        EventData::TabRenamed { workspace_id, tab_id: emitted_tab_id, label }
            if workspace_id == &expected_workspace_id
                && emitted_tab_id == &tab_id
                && label == "Prowl"
    ));

    let clear_sequence = event_hub.current_sequence();
    let cleared = app.handle_tab_rename(
        "same-cwd-clear".into(),
        TabRenameParams { tab_id, label: None },
    );
    assert_eq!(decode_tab_info(&cleared).label, "Prowl");
    let clear_events = event_hub
        .events_after(clear_sequence)
        .into_iter()
        .filter(|(_, event)| matches!(&event.data, EventData::TabRenamed { .. }))
        .collect::<Vec<_>>();
    assert_eq!(clear_events.len(), 1);
    let clear_event = clear_events
        .first()
        .expect("clear must emit tab.renamed");
    assert!(matches!(
        &clear_event.1.data,
        EventData::TabRenamed { workspace_id, tab_id: emitted_tab_id, label }
            if workspace_id == &expected_workspace_id
                && emitted_tab_id == &tab_id
                && label == "Prowl"
    ));
}
```

在同一 test module 定义：

```rust
fn app_with_canonical_tab_cwd(cwd: std::path::PathBuf) -> App {
    let (_api_tx, api_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut app = App::new(
        &Config::default(),
        true,
        None,
        api_rx,
        crate::api::EventHub::default(),
    );
    app.state.workspaces = vec![Workspace::test_new("tabs")];
    app.state.ensure_test_terminals();
    let pane_id = app.state.workspaces[0].tabs[0].layout.focused();
    let terminal_id = app.state.workspaces[0].terminal_id(pane_id).unwrap().clone();
    app.state.terminals.get_mut(&terminal_id).unwrap().cwd = cwd;
    app
}

fn app_with_evented_tab_cwd(
    cwd: std::path::PathBuf,
) -> (App, crate::api::EventHub, crate::layout::PaneId) {
    let event_hub = crate::api::EventHub::default();
    let (_api_tx, api_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut app = App::new(&Config::default(), true, None, api_rx, event_hub.clone());
    app.state.workspaces = vec![Workspace::test_new("tabs")];
    app.state.ensure_test_terminals();
    let pane_id = app.state.workspaces[0].tabs[0].layout.focused();
    let terminal_id = app.state.workspaces[0].terminal_id(pane_id).unwrap().clone();
    app.state.terminals.get_mut(&terminal_id).unwrap().cwd = cwd;
    (app, event_hub, pane_id)
}
```

`cwd_fixture()` 和 `app_with_evented_tab_cwd` 必须使用真实已创建目录并持有 guard；`api_manual_rename_and_clear_emit_exactly_one_tab_renamed_when_name_equals_cwd` 同时锁定手动来源不能由 label/cwd 字符串相等关系推断。

- [ ] **Step 3: 运行 API/schema tests，确认失败**

```bash
cd /Users/yam/Developer/herdr
just test-one api_tab_rename_trims_and_rejects_blank_labels
just test-one api_tab_create_trims_and_rejects_blank_labels
just test-one rename_tab_same_as_cwd_saves_custom_name
just test-one tui_tab_create_unmodified_numeric_placeholder_stays_auto
just test-one tui_tab_create_explicit_numeric_name_saves_custom_name
just test-one api_manual_rename_and_clear_emit_exactly_one_tab_renamed_when_name_equals_cwd
just test-one generated_protocol_schema_artifact_is_current
```

Expected: `custom_name` 尚不存在，当前 handler 会接受 blank label，且 same-cwd rename/clear 的 exact-one event contract 尚未成立。

- [ ] **Step 4: 重命名 wire field 并实现严格 rename contract**

把 `TabInfo.custom_label` 改为 `custom_name`；保持 `src/protocol/wire.rs::PROTOCOL_VERSION` 为 21，并保留现有 exact-match version guard，使未来 protocol 22 在 API/render 前返回 `protocol_mismatch`。在 mutation 前 normalization：

```rust
let normalized_label = params.label.map(|label| label.trim().to_string());
if normalized_label.as_deref().is_some_and(str::is_empty) {
    return encode_error(id, "invalid_params", "tab label must not be blank");
}
match normalized_label {
    Some(label) => tab.set_custom_name(label),
    None => tab.custom_name = None,
}
```

mutation 完成后再构造 response/event。`TabRenamed` 保持 `tab_id + workspace_id + final label`，不重复携带 `custom_name`；`TabInfo` 同时携带 `label + custom_name`。

手动 rename 和成功 clear 各自必须无条件发送恰好一次 `TabRenamed`，即使最终 canonical label 与变更前相同（例如把 tab 命名为当前 cwd basename）；cwd/focus/move 派生变化才使用“仅 label 真变化才发送”的 emitter。重复 clear 保持幂等，不写入 `Some("")`。

`tab.create.label` 复用同一 normalization：`None`/字段省略表示自动名称；非空字符串 trim 后写入 `custom_name`；空或纯空白字符串返回 `invalid_params` 并且不创建带空 custom name 的 tab。新增的 `api_tab_create_trims_and_rejects_blank_labels` 必须覆盖 trim、blank reject 和 `None` auto behavior。

该 API test 使用现有 `shutdown_test_runtimes(&mut app)` 清理 `tab.create` 启动的 test runtimes，fixture guard 在 cleanup 后才释放。

`src/app/input/modal.rs` 的 TUI rename 也必须无条件保存 nonblank `custom_name`，包括输入与 cwd basename 相同的 case；新增 `rename_tab_same_as_cwd_saves_custom_name`。reset 仍只能通过 `label: null`，不把 cwd 同名输入当作 reset。

在 `src/protocol/wire.rs` 的 version tests 中覆盖当前 protocol 21 compatibility 与 19/20 rejection；protocol 20 的历史 bincode freeze comment 保持原样，不能只测试 `PROTOCOL_VERSION - 1` 一个邻近值。

- [ ] **Step 5: 更新 docs 并重新生成 schema**

```bash
cd /Users/yam/Developer/herdr
HERDR_UPDATE_API_SCHEMA=1 just test-one generated_protocol_schema_artifact_is_current
just test-one api_tab_rename_trims_and_rejects_blank_labels
just test-one api_tab_create_trims_and_rejects_blank_labels
just test-one rename_tab_same_as_cwd_saves_custom_name
just test-one tui_tab_create_unmodified_numeric_placeholder_stays_auto
just test-one tui_tab_create_explicit_numeric_name_saves_custom_name
just test-one api_manual_rename_and_clear_emit_exactly_one_tab_renamed_when_name_equals_cwd
just test-one protocol_21_is_compatible
just test-one protocol_19_is_rejected
just test-one protocol_20_is_rejected
rg -n "custom_label" src docs/next
```

Expected: schema artifact 已由带 `HERDR_UPDATE_API_SCHEMA=1` 的命令更新；API tests PASS；Herdr `src`/`docs/next` 中 `custom_label` 无输出。

- [ ] **Step 6: 经 review 后提交 Task 3**

先提出：`feat: align tab label api with custom name state`。确认后把 API、schema、next docs 作为同一个契约提交。

## Task 4: 接入 cwd、focus 和 move 的最终 label events

**Files:**
- Modify: `/Users/yam/Developer/herdr/src/app/api.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/actions.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/panes.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/tabs.rs`
- Test: 对应 inline test modules

**Interfaces:**
- Consumes: `tab_canonical_label`、`tab_canonical_label_for_pane`、`EventHub::current_sequence/events_after`。
- Produces:

```rust
fn emit_tab_renamed(
    &mut self,
    ws_idx: usize,
    tab_idx: usize,
);

fn emit_tab_renamed_if_changed(
    &mut self,
    ws_idx: usize,
    tab_idx: usize,
    previous_label: Option<String>,
);
```

- [ ] **Step 1: 写 focused cwd report event failing tests**

在 `src/app/api.rs` test module 使用独立 `EventHub`：

```rust
#[test]
fn focused_cwd_report_emits_final_tab_renamed_label() {
    let fixture = cwd_fixture();
    let (mut app, event_hub, pane_id) = app_with_evented_tab_cwd(fixture.old.clone());
    let expected_workspace_id = app.public_workspace_id(0);
    let expected_tab_id = app.public_tab_id(0, 0).unwrap();
    let sequence = event_hub.current_sequence();

    app.handle_internal_event(AppEvent::TerminalCwdReported {
        pane_id,
        cwd: fixture.new.clone(),
    });

    let events = event_hub.events_after(sequence);
    assert!(events.iter().any(|(_, event)| matches!(
        &event.data,
        EventData::TabRenamed {
            workspace_id,
            tab_id,
            label,
        } if workspace_id == &expected_workspace_id
            && tab_id == &expected_tab_id
            && label == "New"
    )));
}

#[test]
fn manual_tab_cwd_report_does_not_emit_tab_renamed() {
    let fixture = cwd_fixture();
    let (mut app, event_hub, pane_id) = app_with_evented_tab_cwd(fixture.old.clone());
    app.state.workspaces[0].tabs[0].set_custom_name("Backend".into());
    let sequence = event_hub.current_sequence();

    app.handle_internal_event(AppEvent::TerminalCwdReported {
        pane_id,
        cwd: fixture.new.clone(),
    });

    assert!(!event_hub.events_after(sequence).iter().any(|(_, event)| {
        matches!(&event.data, EventData::TabRenamed { .. })
    }));
}

#[test]
fn inactive_tab_cwd_report_emits_for_its_own_workspace_and_tab() {
    let fixture = cwd_fixture();
    let (mut app, event_hub, inactive_pane_id, inactive_tab_id) =
        app_with_inactive_tab_cwd(fixture.old.clone(), fixture.new.clone());
    let expected_workspace_id = app.public_workspace_id(0);
    app.state.active = Some(0);
    app.state.workspaces[0].active_tab = 0;
    let sequence = event_hub.current_sequence();

    app.handle_internal_event(AppEvent::TerminalCwdReported {
        pane_id: inactive_pane_id,
        cwd: fixture.new.clone(),
    });

    assert!(event_hub.events_after(sequence).iter().any(|(_, event)| matches!(
        &event.data,
        EventData::TabRenamed {
            workspace_id,
            tab_id,
            label,
        } if workspace_id == &expected_workspace_id
            && tab_id == &inactive_tab_id
            && label == "New"
    )));
}
```

`cwd_fixture()` 必须创建并持有 `Old`/`New` 真实目录；本 Task 直接复用 Task 3 定义的 `app_with_evented_tab_cwd(PathBuf)`，不重新引入字符串路径 helper。

`app_with_inactive_tab_cwd(old, new)` 必须在同一 workspace 创建两个 tab，给 tab 1 的 focused pane 设置已创建的 `old`，保持 active tab 为 tab 0，返回 `(App, EventHub, PaneId, String)`，其中 `String` 是 `app.public_tab_id(0, 1).unwrap()`；实现用 `Workspace::test_add_tab(None)`、`ensure_test_terminals()` 和 terminal map 写入 cwd，所有返回值都来自 stable public IDs。该测试证明 cwd report 不依赖 active workspace/active tab 才能计算 canonical label。

- [ ] **Step 2: 写 focus、tab.move、pane.move failing tests**

分别添加：

- 同一 tab 从已创建的 `Old` pane focus 到已创建的 `New` pane，产生一次 final `tab.renamed(New)`；
- non-focused pane 的 cwd report 只更新该 pane 的 in-memory cwd，不发送 tab rename；
- manual tab 的 pane focus 不产生 rename；
- 纯 `workspace.focused`/`tab.focused` 不产生 rename；
- `tab.move` 只产生 `TabMoved`；
- `pane.move` 只为实际变化且仍存在的 source/target tab 发 rename；closed source 不发；created target 只在 `TabCreated.tab.label` 携带 final label；增加 source 位于 target 前方且 remove 会改变数组 index 的 case，断言实现使用 stable public `workspace_id`/`tab_id` 重新解析而不是 mutation 后的旧 index。

所有 positive `TabRenamed` assertions 都必须同时匹配 `workspace_id`、稳定 `tab_id` 和变更后的最终 `label`；只检查事件数量或 label 字符串不算通过。

- [ ] **Step 3: 运行 tests，确认现状未发 label lifecycle event**

```bash
cd /Users/yam/Developer/herdr
just test-one focused_cwd_report_emits_final_tab_renamed_label
just test-one manual_tab_cwd_report_does_not_emit_tab_renamed
just test-one nonfocused_cwd_report_does_not_emit_tab_renamed
just test-one inactive_tab_cwd_report_emits_for_its_own_workspace_and_tab
just test-one pane_focus_emits_tab_renamed_for_changed_auto_label
just test-one pane_move_re_resolves_stable_tab_ids_before_emitting_labels
just test-one tab_move_emits_only_tab_moved
```

Expected: cwd report 只更新 `TerminalState.cwd`；focus/move 没有完整 final-label event contract。

- [ ] **Step 4: 实现区分手动 mutation 与派生变化的 event emitter**

```rust
fn emit_tab_renamed(&mut self, ws_idx: usize, tab_idx: usize) {
    let Some(tab_id) = self.public_tab_id(ws_idx, tab_idx) else { return };
    let Some(label) = self.state.tab_canonical_label(ws_idx, tab_idx) else { return };
    self.emit_event(EventEnvelope {
        event: EventKind::TabRenamed,
        data: EventData::TabRenamed {
            tab_id,
            workspace_id: self.public_workspace_id(ws_idx),
            label,
        },
    });
}

fn emit_tab_renamed_if_changed(
    &mut self,
    ws_idx: usize,
    tab_idx: usize,
    previous_label: Option<String>,
) {
    let current_label = self.state.tab_canonical_label(ws_idx, tab_idx);
    if previous_label == current_label {
        return;
    }
    self.emit_tab_renamed(ws_idx, tab_idx);
}
```

只在 mutation 完成后调用。手动 `tab.rename`/clear 使用无条件的 `emit_tab_renamed`；cwd、pane focus 和 move 使用 `emit_tab_renamed_if_changed`。旧 label 必须在 cwd、focus 或 move mutation 前捕获。

- [ ] **Step 5: 接入 cwd/focus event 闭环**

- `handle_internal_event_with_pane_updates`：在 dispatch `TerminalCwdReported` 前只为 focused pane 记录 affected `(ws_idx, tab_idx, old_label)`，state 更新后调用 `emit_tab_renamed_if_changed`；non-focused pane report 不触发 tab rename。
- `sync_focus_events_with_outer_event`：保留现有 workspace/tab/pane focus events；同一 tab 内 pane 改焦点时，用 `tab_canonical_label_for_pane` 比较 old/new，真实变化才发 rename；纯 workspace/tab selection 只发 focus event。
- 仅切换 workspace/tab selection 不发 rename；Task 7 会让 focus event 本身触发 Prowl snapshot refresh。

- [ ] **Step 6: 接入 pane.move/tab.move**

`handle_pane_move` 在 remove/insert 前记录 source/target 的 stable public `workspace_id` + `tab_id` 以及 labels；mutation 后禁止继续使用旧 `source_ws_idx`/`source_tab_idx`/`target_tab_idx` 作为身份。先用 public IDs 调用 `parse_workspace_id`/`parse_tab_id` 重新解析当前数组位置，再在 focus settle 后重新计算：

- source 存在且变化：发一次；
- target 存在且变化：发一次；
- source/target 相同：去重；
- source closed：只发 `TabClosed`；
- target created：`TabCreated.tab.label` 已是 final label，不重复发 rename；
- label 未变：不发。

source workspace 被删除、source tab 被删除或 source 位于 target 前方导致数组收缩时，仍必须通过 stable IDs 找到 surviving target；找不到的 source 只由 `TabClosed`/`WorkspaceClosed` 表达，不允许对错误 index 发送 `TabRenamed`。新建 target 使用返回的 `TabInfo.tab_id` 作为 ID，`TabCreated.tab.label` 已是最终值。

`handle_tab_move` 保持纯重排，只发 `TabMoved`。

- [ ] **Step 7: 运行完整 lifecycle tests**

```bash
cd /Users/yam/Developer/herdr
just test-one focused_cwd_report_emits_final_tab_renamed_label
just test-one nonfocused_cwd_report_does_not_emit_tab_renamed
just test-one inactive_tab_cwd_report_emits_for_its_own_workspace_and_tab
just test-one pane_focus_emits_tab_renamed_for_changed_auto_label
just test-one pane_move_re_resolves_stable_tab_ids_before_emitting_labels
just test-one tab_move_emits_only_tab_moved
```

Expected: 只对实际 label 变化发送 final `tab.renamed`；manual label 不随 cwd/focus/move 变化；tab reorder 不发 rename。

- [ ] **Step 8: 经 review 后提交 Task 4**

先提出：`feat: emit canonical tab label lifecycle events`。确认后提交 event ordering 与 move tests。

## Task 5: 保证 restore 和首个 snapshot label 一致

**Files:**
- Modify: `/Users/yam/Developer/herdr/src/persist/restore.rs`
- Modify: `/Users/yam/Developer/herdr/src/persist/snapshot.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/api/session.rs`
- Modify: `/Users/yam/Developer/herdr/src/app/creation.rs`
- Test: 上述 inline test modules

**Interfaces:**
- Consumes: Task 1 helper、Task 3 `TabInfo { label, custom_name }`。
- Produces: first post-restore snapshot 已使用 focused pane cwd，且只持久化 `custom_name`。

- [ ] **Step 1: 写 restore first-snapshot failing test**

在 `src/app/api/session.rs` 的现有 `app_with_two_tabs` test fixture 旁新增本模块合法的 platform helper 和 restore fixture。不要引用 `src/persist/restore.rs` 的私有 test helper；定义：

```rust
fn test_restore_shell() -> String {
    #[cfg(unix)]
    { "/bin/sh".to_string() }
    #[cfg(windows)]
    { "cmd.exe".to_string() }
}
```

测试 module 显式 `use crate::app::actions::test_support::{cwd_fixture, CwdFixture};`，测试函数先持有 `let fixture = cwd_fixture();`，再用 `fixture.prowl.clone()`、`fixture.backend.clone()` 和 `fixture.corrected.clone()` 构造 `crate::persist::SessionSnapshot`；`app_from_restored_snapshot(snapshot: &crate::persist::SessionSnapshot, fixture: &CwdFixture) -> App` 接收 guard 引用，保证目录存活到所有 assertions 和 runtime shutdown 完成。helper 用 `App::new(&Config::default(), true, None, api_rx, EventHub::default())` 创建 no-session App，保留 `let shell = test_restore_shell();`，并调用真实 restore 签名：

```rust
fn app_from_restored_snapshot(
    snapshot: &crate::persist::SessionSnapshot,
    _fixture: &CwdFixture,
) -> App {
    let (_api_tx, api_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut app = App::new(
        &Config::default(),
        true,
        None,
        api_rx,
        EventHub::default(),
    );
    let shell = test_restore_shell();
    let (workspaces, terminals, terminal_runtimes) = crate::persist::restore(
    snapshot,
    None,
    24,
    80,
    0,
    shell.as_str(),
    ShellModeConfig::NonLogin,
    false,
    app.event_tx.clone(),
    std::sync::Arc::new(tokio::sync::Notify::new()),
    std::sync::Arc::new(crate::render_signal::RenderSignal::new()),
);
app.state.workspaces = workspaces;
app.state.terminals = terminals;
app.terminal_runtimes = terminal_runtimes.into();
app.state.active = Some(0);
    app
}
```

测试 snapshot 使用已创建 `Prowl` cwd 的 tab 0、无 custom；已创建 `Backend` cwd 的 tab 1、`custom_name=Some("Pinned")`；active tab/focused pane 为 tab 0。然后调用 `handle_session_snapshot`：

```rust
let response = app.handle_session_snapshot("snapshot".into());
let response: SuccessResponse = serde_json::from_str(&response).unwrap();
let ResponseResult::SessionSnapshot { snapshot } = response.result else {
    panic!("expected session_snapshot response");
};
assert_eq!(snapshot.tabs[0].label, "Prowl");
assert_eq!(snapshot.tabs[0].custom_name, None);
assert_eq!(snapshot.tabs[1].label, "Pinned");
assert_eq!(snapshot.tabs[1].custom_name.as_deref(), Some("Pinned"));
```

- [ ] **Step 2: 写 restored runtime cwd correction test**

首个 snapshot 后发送一次指向 fixture 已创建 `Corrected` 目录的 `TerminalCwdReported`；断言只产生一次 final `tab.renamed(Corrected)`，第二次 snapshot 的 label 为 `Corrected`。fixture guard 必须一直存活到 event 和 snapshot assertions 完成。

- [ ] **Step 3: 运行 restore tests，确认失败**

```bash
cd /Users/yam/Developer/herdr
just test-one restored_session_snapshot_uses_focused_cwd_label
just test-one restored_runtime_cwd_correction_emits_final_tab_renamed
```

Expected: 自动 restored tab 仍暴露数字 label，或 `custom_name` wire field 尚未对齐。

- [ ] **Step 4: 保持 persistence 只有 custom_name**

不得向 `TabSnapshot` 增加 `label`/`automatic_name`。确保 `restore_tab` 完成 pane/terminal construction、layout focus resolution 后，才允许 `App::session_snapshot()`/`TabInfo` 通过 canonical helper 读取 label；restore 遇到 legacy 空/纯空白 `custom_name` 时先归一为 `None`，不得让空 custom name 进入 snapshot。首个 snapshot 不依赖后续 OSC cwd event 才正确。

- [ ] **Step 5: 运行 restore/session tests**

```bash
cd /Users/yam/Developer/herdr
just test-one restored_session_snapshot_uses_focused_cwd_label
just test-one restored_runtime_cwd_correction_emits_final_tab_renamed
just test-one session_snapshot_uses_canonical_tab_label
```

Expected: first snapshot 即 final label；custom name round-trip；后续 cwd correction 走 Task 4 rename event，不引入第二份 persisted label。

- [ ] **Step 6: 经 review 后提交 Task 5**

先提出：`fix: keep restored tab labels canonical`。确认后只提交 restore/snapshot/tests。

## Task 6: 清理 Prowl transitional fields，以 server label 为 projection source

**Files:**
- Modify: `/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrWireModels.swift`
- Modify: `/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrSocketClient.swift`
- Modify: `/Users/yam/Developer/Prowl/supacode/Features/Clean/HerdrTabBarView.swift`
- Modify: `/Users/yam/Developer/Prowl/supacodeTests/HerdrTabBarViewTests.swift`
- Modify: `/Users/yam/Developer/Prowl/supacodeTests/HerdrInputContextTests.swift`
- Modify: `/Users/yam/Developer/Prowl/supacodeTests/CleanAppFeatureTests.swift`
- Modify: `/Users/yam/Developer/Prowl/docs/components/clean-mode.md`

**Interfaces:**
- Consumes: Herdr `TabInfo.label + TabInfo.custom_name`。
- Produces: `HerdrTab.customName: String?`；server label + independent decorations；无 Git process fallback。

- [ ] **Step 1: 写 new wire/projection failing tests**

```swift
@Test func decodesCustomNameWithoutLegacyCustomLabelFields() throws {
  let data = Data(
    #"{"tab_id":"w1:t1","workspace_id":"w1","label":"Backend","custom_name":"Backend"}"#.utf8
  )
  let tab = try JSONDecoder().decode(HerdrTab.self, from: data)

  #expect(tab.label == "Backend")
  #expect(tab.customName == "Backend")
}

@Test func serverLabelIsDirectorySegmentWithoutCustomName() {
  let snapshot = HerdrSessionSnapshot(
    version: "0.8.2",
    protocolVersion: 21,
    focusedWorkspaceID: "w1",
    focusedTabID: "w1:t1",
    focusedPaneID: "w1:p1",
    workspaces: [],
    tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "Prowl")],
    panes: [HerdrPane(paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true)],
    layouts: [],
    agents: []
  )

  let item = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1").first
  #expect(item?.directoryLabel == "Prowl")
}

@Test func rejectsLegacyProtocolsBeforeCanonicalProjection() throws {
  for version in [19, 20, 22] {
    #expect(
      throws: HerdrSocketError.unsupportedProtocol(supported: 22...22, actual: UInt32(version))
    ) {
      try HerdrProtocolCompatibility.validate(protocolVersion: UInt32(version))
    }
  }
  try HerdrProtocolCompatibility.validate(protocolVersion: 21)
}
```

另加两个明确 cases：manual name=`Prowl` 且 cwd=`Prowl` 时 `customName` 仍非空；process cwd 使用 fixture 已创建的 `Other` 目录时 server label=`Prowl` 仍显示 `lazygit ・ Prowl`，且 projection 不检查该目录是否存在。

- [ ] **Step 2: 运行 HerdrTabBarViewTests，确认失败**

```bash
cd /Users/yam/Developer/Prowl
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project supacode.xcodeproj -scheme supacode -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrTabBarViewTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -skipMacroValidation
```

Expected: decoder 没有 `customName`，projection 仍依赖 `customLabel`/numeric inference/process cwd；兼容性测试证明只有 protocol 21 可用，19/20/22 在渲染前失败。

- [ ] **Step 3: 替换 HerdrTab wire model**

`HerdrTab` 删除 `customLabel`/`hasCustomLabelField`，加入：

```swift
internal let customName: String?

private enum CodingKeys: String, CodingKey {
  case tabID = "tab_id"
  case workspaceID = "workspace_id"
  case number
  case label
  case customName = "custom_name"
  case focused
  case paneCount = "pane_count"
  case agentStatus = "agent_status"
}
```

init 与 decode 直接赋值 `customName`，不记录字段是否存在，不做 legacy inference。

`HerdrProtocolCompatibility.supportedVersions` 改为 `21...21`；protocol 19/20/22 的 `ping`/snapshot response 返回 `.unsupportedProtocol` 并把 native chrome 置为 hidden。protocol 21 且缺少可选 `custom_name` 的 snapshot 仍按自动命名处理，这是字段可选性。

将 `supacodeTests` 中所有正常 snapshot fixture 的 `protocolVersion` 保持为 21；显式 incompatibility cases 覆盖 19、20 和未来 22，并断言不会进入 tab projection；protocol 21 的正常 fixture 必须通过兼容性检查。

- [ ] **Step 4: 删除 parallel automatic projection 和 Git subprocess**

在 `HerdrTabBarItem/Projection/View`：

- 删除 `automaticDirectoryName`、`resolvedCustomLabel`、numeric/legacy inference；
- directory segment 默认用 `tab.label`；
- `tab.customName != nil` 时 manual label 优先于 worktree decoration；
- 仅使用 snapshot workspace worktree provenance 进行 automatic rich presentation；
- process title directory segment 使用 server label，不使用 foreground process cwd 覆盖；
- agent icon/process detection 保持独立；
- 删除 `HerdrWorktreeIdentityResolver`、`gitRevParseArguments`、`gitWorktreePaths`、`worktreeResolutionKey`、view `.task` 和对应 state。

- [ ] **Step 5: reset UI 只读取 customName**

context menu 与 rename sheet 仅在 `item.customName != nil` 时显示 reset。继续发送现有 `.resetTabNameRequested`；禁止根据 label text、digits、cwd equality 或旧 JSON key presence 推断。

rename editor 的初始值必须改为 `item.label`（server canonical label），不能读取 `item.directoryLabel`，因为 automatic linked-worktree decoration 可能把 `repo ↳ checkout` 填进编辑器并被误保存为 custom name。增加两个 tests：

```swift
@Test func renameEditorUsesServerLabelNotLinkedDecoration() {
  let linked = HerdrLinkedWorktreeTitle(repoName: "repo", checkoutName: "feature")
  let item = HerdrTabBarItem(
    id: "w1:t1",
    workspaceID: "w1",
    label: "Prowl",
    isZoomed: false,
    isFocused: true,
    customName: nil,
    linkedWorktree: linked
  )
  #expect(HerdrTabBarProjection.renameEditorLabel(for: item) == "Prowl")
  #expect(item.customName == nil)
}
```

`HerdrTabBarView` context menu and `editorView(.rename)` both use `item.label` for the editor seed; only server-returned `custom_name` controls reset visibility. In `HerdrTerminalChromeTests`, add `linkedAutomaticDecorationIsNotSavedAsCustomName`: construct snapshot tab `label="Prowl"`, `customName=nil`, linked provenance `repo ↳ feature`, send `.renameTabRequested("Prowl")`, assert the dependency receives exactly `label="Prowl"` and the state remains `customName == nil` until the server snapshot confirms a value. The decoration string must never be submitted or persisted as customName.

- [ ] **Step 6: 运行 tests 和 static cleanup**

```bash
cd /Users/yam/Developer/Prowl
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project supacode.xcodeproj -scheme supacode -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrTabBarViewTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -skipMacroValidation

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project supacode.xcodeproj -scheme supacode -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrInputContextTests \
  -only-testing:supacodeTests/CleanAppFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -skipMacroValidation

rg -n "Workspace::tab_display_name|active_tab_display_name|customLabel|custom_label|hasCustomLabelField|resolvedCustomLabel|automaticDirectoryName|HerdrWorktreeIdentityResolver|/usr/bin/git" \
  supacode/Features/Clean/HerdrTabBarView.swift supacode/Infrastructure/Herdr \
  supacodeTests/HerdrTabBarViewTests.swift supacodeTests/HerdrTerminalChromeTests.swift
```

Expected: tests PASS；最后 `rg` 无输出；tab projection 不启动 process/polling。

- [ ] **Step 7: 经 review 后提交 Task 6**

按 Prowl 规则提交：`fix(clean): use server tab labels without local inference`，只 stage 本 Task 文件。

## Task 7: 完成 Prowl event-to-snapshot 和 reset lifecycle

**Files:**
- Modify: `/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrSocketClient.swift`
- Modify: `/Users/yam/Developer/Prowl/supacode/Infrastructure/Herdr/HerdrTerminalChromeClient.swift`
- Modify: `/Users/yam/Developer/Prowl/supacode/Features/Clean/HerdrTerminalChromeFeature.swift`
- Modify: `/Users/yam/Developer/Prowl/supacodeTests/HerdrTerminalChromeTests.swift`
- Test: `/Users/yam/Developer/Prowl/supacodeTests/HerdrTabBarViewTests.swift`

**Interfaces:**
- Consumes: `tab.renamed`、`pane.focused`、`tab.focused`、`workspace.focused`、`pane.moved`、`tab.moved`、`tab.created`、`tab.closed`；`client.snapshot()`；nullable rename。
- Produces: subscribe-before-snapshot lifecycle handshake、lifecycle burst 的 debounced snapshot refresh、generation rejection、server-confirmed reset。

- [ ] **Step 1: 扩展 test helpers 的精确签名**

把现有 helper 改为：

```swift
private func makeSnapshot(
  focusedPaneID: String,
  tabLabel: String = "Shell",
  customName: String? = nil
) -> HerdrSessionSnapshot {
  HerdrSessionSnapshot(
    version: "0.8.2",
    protocolVersion: 21,
    focusedWorkspaceID: "w1",
    focusedTabID: "t1",
    focusedPaneID: focusedPaneID,
    workspaces: [HerdrWorkspace(workspaceID: "w1", label: "Main", focused: true)],
    tabs: [
      HerdrTab(
        tabID: "t1",
        workspaceID: "w1",
        label: tabLabel,
        customName: customName,
        focused: true
      )
    ],
    panes: [
      HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1", agent: "codex"),
      HerdrPane(paneID: "p2", workspaceID: "w1", tabID: "t1", foregroundCWD: nil),
    ],
    layouts: [],
    agents: []
  )
}
```

同步更新 `HerdrTerminalChromeClient` 的所有 live/test dependency values：旧 `events` closure 全部改为 `subscribeEvents: @Sendable () async throws -> HerdrEventSubscription`，并在 fake client 中显式记录 global ack、pane update ack、stream event 顺序和 cancel。

- [ ] **Step 2: 写 tab.renamed snapshot refresh failing test**

```swift
@Test(.dependencies) func tabRenamedEventRefreshesSnapshot() async {
  let clock = TestClock()
  let calls = LockIsolated(0)
  let updated = makeSnapshot(focusedPaneID: "p1", tabLabel: "Backend", customName: "Backend")
  var state = HerdrTerminalChromeFeature.State()
  state.connection = .connected
  state.snapshot = makeSnapshot(focusedPaneID: "p1", tabLabel: "Prowl")

  let store = TestStore(initialState: state) { HerdrTerminalChromeFeature() } withDependencies: {
    $0.continuousClock = clock
    $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
      snapshot: {
        calls.withValue { $0 += 1 }
        return updated
      },
      subscribeEvents: { _ in
        HerdrEventSubscription(
          stream: AsyncStream { $0.finish() },
          cancel: {}
        )
      },
      focusWorkspace: { _ in }, focusTab: { _ in }, focusPane: { _ in },
      createWorkspace: {}, createTab: { _, _, _ in }, renameTab: { _, _ in },
      moveTab: { _, _ in }, closeTab: { _ in }, closeWorkspace: { _ in }
    )
  }

  await store.send(.eventStream(.event(HerdrEventEnvelope(event: "tab.renamed"))))
  await clock.advance(by: .milliseconds(100))
  await store.receive(.debouncedRefresh) { $0.refreshGeneration = 1 }
  await store.receive(.refreshResponseWithGeneration(1, .success(updated))) {
    $0.snapshot = updated
  }
  #expect(calls.value == 1)
}
```

- [ ] **Step 3: 写 focus/move lifecycle table tests**

先定义只接受完整 payload 的 test helper，并让所有 focus event 使用同一组 workspace/tab/pane IDs；禁止构造只有一个 ID 的 partial payload：

```swift
private func completeFocusEvent(
  name: String,
  workspaceID: String = "w1",
  tabID: String = "t1",
  paneID: String = "p2"
) -> HerdrEventEnvelope {
  HerdrEventEnvelope(
    event: name,
    focus: HerdrFocusEvent(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
  )
}
```

增加一个完整的 focus lifecycle test：先发送 `.focusPaneTapped("p2")`，断言 optimistic `selectedWorkspaceID/selectedTabID/selectedPaneID` 和 `pendingFocus`；再发送 `completeFocusEvent(name: "pane_focused")`，断言 server confirmation 清除 `pendingFocus`/rollback，同时保持 optimistic selection；推进 `TestClock` 100ms，断言收到 `.debouncedRefresh`、`refreshGeneration` 增加且只调用一次 `client.snapshot()`，最后以 snapshot 的 focused IDs 完成 reconcile。`tab_focused`、`workspace_focused` 也必须使用完整 payload 并断言 selection + debounce；`pane.moved`、`tab.moved`、`tab.created`、`tab.closed` 逐个断言 snapshot call，`tab.moved` 不调用 rename client。保留 stale generation test，增加旧 response 不能覆盖 updated label 的 assertion。

- [ ] **Step 4: 运行 reducer tests，确认 focus event 当前提前 return**

```bash
cd /Users/yam/Developer/Prowl
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project supacode.xcodeproj -scheme supacode -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrTerminalChromeTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -skipMacroValidation
```

Expected: focus event tests FAIL，因为当前 `applyFocusEvent` 后只 cancel confirmation，没有 refresh。

- [ ] **Step 5: 固定 subscription 和 reducer refresh set**

先修复当前 snapshot→events race：`lifecycleEffect` 不得再先 await `client.snapshot()` 再创建 subscription。定义单一 multiplexed subscription API，不创建第二个独立 AsyncStream：

```swift
nonisolated internal struct HerdrEventSubscription: Sendable {
  internal let stream: AsyncStream<HerdrEventStreamState>
  internal let cancel: @Sendable () -> Void
}

  internal var subscribeEvents: @Sendable (Set<String>) async throws -> HerdrEventSubscription
```

同一个 socket/session 和同一个 `stream` 同时承载 global navigation 与 pane-specific events。每轮 lifecycle 先请求 discovery `session.snapshot`，再用 discovery pane IDs 建立一次 `events.subscribe` 并等待 `subscription_started` acknowledgement，最后请求 authoritative `session.snapshot`；两次 snapshot 之间到达的事件保留在同一个 stream 中。authoritative snapshot 的 pane-set 变化会取消旧 subscription 并重建整轮生命周期。global/pane 两类事件都由同一个 reducer `eventStream(.event)` consumer 消费。`cancel()` 必须取消真实 socket reader、结束同一个 stream，并由 `foregroundChanged(false)`/retry teardown 调用；不得创建第二个 reducer consumer 或第二个未合并 stream。

lifecycle 顺序固定为：

1. 请求 discovery `session.snapshot` 获取 pane IDs；
2. `subscribeEvents(paneIDs)` 建立 global + pane-specific subscription，并等待 ack；
3. authoritative snapshot 成功后继续同一个 stream consumer；若 pane-set 与 discovery 不同，取消旧 subscription 并重建 lifecycle；
4. 断开或取消时关闭该 subscription；重连重新执行上述顺序，不依赖 server replay。

增加 `subscribeBeforeSnapshotDoesNotLoseTabRenamedEvent`：fake subscription 在 global ack 后阻塞 snapshot，期间注入完整 `tab.renamed` event；snapshot 返回旧 label，event 仍由同一 consumer 接收并触发一次 100ms debounce。增加 `multiplexedSubscriptionDeliversGlobalAndPaneEventsToOneConsumer`：在 pane update ack 前后分别注入 global `tab.renamed` 和 pane-specific agent event，断言两者按顺序进入同一个 reducer stream，`cancel()` 后 stream 结束且不再产生 snapshot。

保持 `HerdrSocketClient.terminalChromeEventNames` 与 reducer event set 一致。`eventStream(.event)` 顺序固定：

1. focus event 先 apply optimistic selection/confirmation；
2. focus 和 rename burst 走现有 100ms debounce；
3. structural move/create/close 按现有 immediate refresh 约定处理；
4. `replaceSnapshot` 最终 reconcile selected IDs/subscribed pane IDs；
5. 不新增 polling task。

在 reducer 中定义真实存在的 helper：

```swift
private func scheduleDebouncedRefresh(
  _ state: inout State,
  invalidatesInFlightRefresh: Bool = false
) -> Effect<Action> {
  if invalidatesInFlightRefresh {
    state.refreshGeneration &+= 1
  }
  return .run { [clock] send in
    do {
      try await clock.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      await send(.debouncedRefresh)
    } catch {
      return
    }
  }
  .cancellable(id: CancelID.refreshDebounce, cancelInFlight: true)
}
```

`eventStream(.event)` 的 focus confirmation branch 在 `applyFocusEvent` 后返回 `.merge(.cancel(id: .focusConfirmation), scheduleDebouncedRefresh(&state))`；普通 rename event 也调用同一个 helper，不能内联另一份 sleep。`mutationResponse(.success)` 读取 `pendingMutation` 后：`renameTab`（包括 clear/reset）先递增 `refreshGeneration`，再取消 `CancelID.refresh`，最后返回 `.merge(.cancel(id: .refresh), scheduleDebouncedRefresh(&state))`；create/move/close 等 structural mutation 才继续 `startRefresh(&state)`。旧 `refreshResponseWithGeneration` 必须先比较 generation，旧 response 即使已在 flight 也不能覆盖新 label/customName。mutation success 与 `tab.renamed` event 共用 `CancelID.refreshDebounce`，无论先后顺序都 coalesce 为一次 snapshot request。

- [ ] **Step 6: 保持 nullable reset 与 server confirmation**

继续使用 `Mutation.renameTab(tabID: String, label: String?)`；`.resetTabNameRequested` 发送 `nil`。rename/reset mutation success 不直接修改 `customName`/`label`，只进入上面的 debounce；reset UI 仅由当前 snapshot 的 `customName != nil` 决定。增加 `renameMutationAndTabRenamedEventCoalesceToOneSnapshot`、`resetMutationAndTabRenamedEventCoalesceToOneSnapshot` 和 `canceledRefreshGenerationCannotOverwriteRenamedSnapshot`：前两个分别记录 mutation client call、event、TestClock 100ms 后的 `client.snapshot()`，断言每个操作恰好一次 rename request、恰好一次 snapshot request；第三个先安排旧 generation response，再成功 rename/reset，断言 generation 递增、旧 response 被丢弃、新 label/customName 保留，且没有立即 refresh + 延迟 refresh 的第二次调用。

- [ ] **Step 7: 运行 reducer tests**

```bash
cd /Users/yam/Developer/Prowl
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project supacode.xcodeproj -scheme supacode -destination 'platform=macOS' \
  -only-testing:supacodeTests/HerdrTerminalChromeTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -skipMacroValidation
```

Expected: rename/focus/move/create/close 都 refresh；focus confirmation 不回退；stale response 被丢弃；reset 只发送一次 nullable rename 和一次 snapshot request。

- [ ] **Step 8: 经 review 后提交 Task 7**

按 Prowl 规则提交：`fix(clean): refresh native chrome after herdr label events`。

## Task 8: 文档、全量验证和实际 app 验证

**Files:**
- Modify: `/Users/yam/Developer/Prowl/docs/components/clean-mode.md`
- Modify: `/Users/yam/Developer/Prowl/doc-onevcat/plans/2026-08-23-herdr-native-terminal-chrome-spec.md`
- Modify: Task 3 列出的 Herdr `docs/next` 文件

**Interfaces:**
- Consumes: Tasks 1-7 的最终契约和 passing focused tests。
- Produces: 同步文档、通过 full checks 的 Herdr/Prowl、已安装 Debug app、实际 runtime evidence。

- [ ] **Step 1: 同步最终用户文档**

`clean-mode.md` 和现有 `doc-onevcat/plans/2026-08-23-herdr-native-terminal-chrome-spec.md` 一起明确 server `label` 是 directory segment 来源、`custom_name` 控制 manual persistence、process/agent/worktree 是 decoration、reset 发送 nullable rename、tab projection 不运行 Git subprocess/cwd polling；Prowl 只支持 protocol 21，19/20/22 在 protocol check 前拒绝并隐藏 native chrome，并同步 native chrome spec 的 protocol/capability 与 lifecycle 章节。不得再描述 transitional fields，也不得修改 agent session title 文档。

- [ ] **Step 2: 运行 Herdr focused 与 full checks**

```bash
cd /Users/yam/Developer/herdr
just test-one tab_canonical_label_uses_focused_terminal_cwd
just test-one tab_cwd_label_handles_home_root_empty_and_invalid_cwd_without_numeric_or_empty_label
just test-one tab_bar_projection_resolves_each_tab_once
just test-one api_tab_rename_trims_and_rejects_blank_labels
just test-one api_tab_create_trims_and_rejects_blank_labels
just test-one rename_tab_same_as_cwd_saves_custom_name
just test-one api_manual_rename_and_clear_emit_exactly_one_tab_renamed_when_name_equals_cwd
just test-one focused_cwd_report_emits_final_tab_renamed_label
just test-one inactive_tab_cwd_report_emits_for_its_own_workspace_and_tab
just test-one pane_move_re_resolves_stable_tab_ids_before_emitting_labels
just test-one restored_session_snapshot_uses_focused_cwd_label
just test-one protocol_21_is_compatible
just test-one protocol_19_is_rejected
just test-one protocol_20_is_rejected
just test-one protocol_21_is_rejected
HERDR_UPDATE_API_SCHEMA=1 just test-one generated_protocol_schema_artifact_is_current
just check
just bench-render-scale | tee /tmp/herdr-tab-name-render-scale.txt

rg -n "Workspace::tab_display_name|active_tab_display_name|\\.tab_display_name\\(|automatic_name|Tab::display_name|custom_label|customLabel|hasCustomLabelField|resolvedCustomLabel|automaticDirectoryName" \
  /Users/yam/Developer/herdr/src /Users/yam/Developer/herdr/tests /Users/yam/Developer/herdr/docs/next \
  /Users/yam/Developer/Prowl/supacode /Users/yam/Developer/Prowl/supacodeTests
```

Expected: focused tests/checks PASS；`HERDR_UPDATE_API_SCHEMA=1 just test-one generated_protocol_schema_artifact_is_current` 已更新并验证 schema artifact；`bench-render-scale` 报告明确列出 background/active 两组在 1/15/50 cardinality 的 `median_us`/`p95_us`/`max_us`/ratio before-after；最后 `rg` 无输出，尤其不能残留 `Workspace::tab_display_name`、`active_tab_display_name`、`custom_label` 或 `customLabel`。

- [ ] **Step 3: 运行 Prowl checks 并安装 Debug app**

```bash
cd /Users/yam/Developer/Prowl
make check
make test
make install-dev-build
```

Expected: `/Applications/Prowl.app` 被 Debug app 更新；不能以单纯 build 代替 install target。

- [ ] **Step 4: build/relaunch/handoff 并验证 socket 与 PID 关联**

先从同一个 checkout 构建 release binary，再对正在服务该 session 的 socket 做 live handoff；禁止仅按 process name 选“最新匹配”来证明 binary 已替换：

```bash
cd /Users/yam/Developer/herdr
just build
new_bin="$(pwd)/target/release/herdr"
version="$("$new_bin" status client --json | jq -r '.version')"
compat_cli="${HERDR_COMPAT_CLI:-$(command -v herdr)}"
compat_protocol="$("$compat_cli" status client --json | jq -r '.protocol')"
server_status="$("$compat_cli" status server --json)"
server_protocol="$(printf '%s' "$server_status" | jq -r '.protocol')"
socket="$(printf '%s' "$server_status" | jq -r '.socket')"
test "$compat_protocol" = "$server_protocol"
test -S "$socket"
HERDR_SOCKET_PATH="$socket" "$compat_cli" api snapshot > /tmp/herdr-tab-name-before.json
lsof -nP -U "$socket"
```

before snapshot 必须由与旧 server protocol 相同的 installed/current CLI 采集；若默认 `herdr` 不匹配，先通过 `HERDR_COMPAT_CLI=/path/to/protocol-compatible/herdr` 指定兼容 binary，不能让 future-protocol `new_bin` 对 protocol-21 server 发 snapshot。也可以用同一 socket 的 raw unchecked NDJSON `session.snapshot` 请求，但必须保存完整 response。

从 `lsof -nP -U "$socket"` 的输出中只选择同时满足“持有该 socket”和 `ps -p PID -o command=` 明确显示 Herdr server invocation 的 PID；记录 `old_pid`、完整 command、`lsof -p "$old_pid" -a -d txt -Fn` 返回的 executable path 以及 `stat -f '%i %N' <path>` 的 inode。然后执行明确的 handoff/relaunch：

```bash
"$new_bin" server live-handoff \
  --import-exe "$new_bin" \
  --expected-protocol 21 \
  --expected-version "$version"
```

handoff 完成后，用同一 `socket` 再次运行 `lsof -nP -U "$socket"`，以 socket 关联选出唯一新的 Herdr server PID；验证 `new_pid != old_pid`、`ps -p "$new_pid" -o pid,ppid,command=` 的 command 指向 `new_bin`、loaded executable path/inode 与 `new_bin` 一致。然后用 protocol-21 client 获取 after snapshot，并比较完整稳定身份和 layout：

```bash
HERDR_SOCKET_PATH="$socket" "$new_bin" api snapshot > /tmp/herdr-tab-name-after.json
for phase in before after; do
  jq -S '.result.snapshot | {
    focused_workspace_id,
    focused_tab_id,
    focused_pane_id,
    workspace_ids: ([.workspaces[].workspace_id] | sort),
    tab_ids: ([.tabs[].tab_id] | sort),
    pane_terminal_ids: ([.panes[] | {
      pane_id,
      terminal_id,
      workspace_id,
      tab_id
    }] | sort_by(.pane_id)),
    layouts: (.layouts | sort_by(.workspace_id, .tab_id))
  }' "/tmp/herdr-tab-name-${phase}.json" > "/tmp/herdr-tab-name-${phase}-stable.json"
done
diff -u /tmp/herdr-tab-name-before-stable.json /tmp/herdr-tab-name-after-stable.json
```

Expected: workspace/tab/pane/terminal stable IDs、pane-to-terminal/workspace/tab mapping、全部 layouts 和 focused IDs 完全一致；不能只比较 counts。若 live handoff capability 不可用，验证应失败并保留证据，不能改用会杀掉 pane processes 的 stop/relaunch 来冒充无损验证。

- [ ] **Step 5: 完成实际 Clean Mode acceptance flow**

1. 自动 tab 显示 cwd basename，不显示 `1`/`2`。
2. focused pane 执行 `cd` 后，Clean tab bar、Herdr attach、Goto/Navigator、mobile switcher、window title 收敛到同一 label。
3. 同 tab pane focus 与跨 tab focus 后 selection/label 一致；仅真实 automatic label 变化触发 `tab.renamed`。
4. `tab.move` 只变顺序；`pane.move` 只更新实际变化的 source/target label。
5. 手动 rename 为 `Backend` 后，process title 和 agent icon 仍保留，process cwd 不覆盖 `Backend`。
6. 手动 rename 为当前 cwd basename 后，reset 仍可见，后续 `cd` 不改变 label。
7. **Use Automatic Directory Name** 和 rename sheet **Use Automatic Name** 都发送 nullable rename，并在 server snapshot 后恢复当前 cwd。
8. 有 server provenance 的 linked worktree 正确 decoration；无 provenance 时直接用 server label，Prowl 不启动 Git。
9. restart/restore 后首个 snapshot、attach、Goto、native tab bar 不短暂显示数字 label。

- [ ] **Step 6: 经 runtime verification 后提交文档**

Herdr 文档随 Task 3 API commit；Prowl 文档 commit message 固定为 `docs(clean): document canonical herdr tab labels`。只 stage 本 feature 文件，不包含现有无关 working-copy 内容。

## Self-Review Checklist

- [ ] 自动 cwd label、manual persistence（含同名边界）、explicit reset、独立 decorations、无数字 fallback 和 no-extra-cost 均有对应 Task。
- [ ] canonical cwd helper 不依赖 `fallback_label_from_cwd`，不 trim cwd、不特殊处理 HOME；原始 basename（含 trailing space）被保留，root/empty/invalid=`Terminal`，所有 cwd/focus/restore fixtures 都创建并持有真实临时目录。
- [ ] `test_support::CwdFixture`、字段和 `cwd_fixture()` 都是 `pub(crate)`；所有 sibling test module 的 fixture 访问可编译，任何 move-out 都使用 clone/borrow。
- [ ] cwd report、pane/tab/workspace focus、pane move、tab move、create、close、rename、restore 均有明确 event 路径。
- [ ] `tab.move` 与 `pane.move` 有独立语义和 tests；pane move 只用 stable public workspace/tab IDs 并在 mutation 后重解析。
- [ ] mobile visible label 不再有 `ws.active_tab + 1`/`idx + 1` numeric fallback；静态 gate 覆盖这些实际表达式。
- [ ] blank rename、nullable clear、same-cwd manual rename/clear 各恰好一次 `TabRenamed`、final-label event 和 Prowl snapshot refresh 都已定义。
- [ ] `tab.create.label`、TUI modal rename、API rename 使用同一 blank/trim/null contract；nonblank 同 cwd 也保存 custom name，reset 单独发送 null。
- [ ] canonical helper owner 固定为 `AppState`，所有 production projection 有明确迁移边界。
- [ ] Task 2 包含 `src/ui.rs`、notification/toast/headless caller，且 `notification_context` 明确从 AppState helper 取 tab label。
- [ ] `custom_label` -> `custom_name` 的 additive JSON API contract 保持 protocol 21；Prowl compatibility 只接受 21，拒绝 19/20/22；schema 用 `HERDR_UPDATE_API_SCHEMA=1 just test-one generated_protocol_schema_artifact_is_current` 更新。
- [ ] `automatic_name`/`Tab::display_name`、`Workspace::tab_display_name`、`active_tab_display_name`、`custom_label`/`customLabel` 等真实旧符号有 static cleanup gate。
- [ ] focus 测试有完整 workspace/tab/pane payload，并覆盖 optimistic selection、confirmation、debounced snapshot；所有 nextest filter 都是合法完整 test name。
- [ ] `TabRenamed` 测试同时断言 workspace ID、tab ID 和最终 label，并覆盖 inactive tab cwd report。
- [ ] Prowl subscribe-before-snapshot race、mutation/event debounce coalescing、rename/reset 恰好一次 snapshot request 和 linked decoration editor seed 都有 tests。
- [ ] 所有 test command 使用真实 repo tooling；没有未完成占位符、未定义执行选项或泛化测试步骤。
- [ ] 包含 `make install-dev-build` 和实际 Clean/attach/Goto/native tab/reset 验证。
- [ ] Task 8 包含现有 native terminal chrome design 文档，以及 build/relaunch/handoff、socket/PID/executable inode、pane/session preservation 的证据链，不以“最后一个匹配进程”替代关联验证。
- [ ] Task 2/8 包含真实 production projection 一次解析验证，以及 `just bench-render-scale` 的 1/15/50 `median_us`/`p95_us`/`max_us`/ratio background/active scaling 报告。
