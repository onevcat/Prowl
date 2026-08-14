# Prowl Clean Mode 实施进度

关联设计：[Prowl Clean Mode 可行性评估与技术方案](2026-08-14-clean-mode-evaluation-and-technical-design.md)

## 当前状态

- 状态：实施中
- 实现基线：本地 `custom` (`a8a63678`)
- 目标分支：`codex/clean-mode`
- 远端同步：禁止；实施期间不执行 `fetch`、`pull`、`rebase` 或 merge `main`
- 开始日期：2026-08-14

## 阶段进度

| 阶段 | 状态 | 验证 |
|---|---|---|
| 0. 固定基线与实施记录 | 完成 | 已从本地 `custom` 创建 `codex/clean-mode`，未同步远端 |
| 1. 启动设置与 runtime 分流 | 未开始 | 待补 reducer/model 测试 |
| 2. full-bleed 单 surface Clean terminal | 未开始 | 待补 host/window 测试与实机验证 |
| 3. 输入法 target/router | 未开始 | 待补 direct context 回归测试 |
| 4. Herdr 自动识别与 socket adapter | 未开始 | 待补 protocol/lifecycle 测试 |
| 5. 文档与最终验证 | 未开始 | 待运行测试、check 和 Debug 安装 |

## 已确认约束

- Clean 是独立 runtime profile，不是 Freestyle 或 repository presentation。
- Settings 只在现有 `Default View > Launch in` Picker 增加 `Clean Mode`。
- Clean 只启动一个 home-directory 普通 shell，不自动启动或 attach Herdr。
- Clean 不构造 Prowl-managed tmux、tab、split、repository、CLI 或 layout persistence 依赖。
- Herdr 由 foreground process 自动识别；只有进入 Herdr 后才启用只读 socket adapter。
- Clean main window 不显示 sidebar、toolbar、tab bar、titlebar、title 或 traffic lights。
- 保留 native resize、fullscreen、Window menu 和 frame restore，不使用 borderless window。

## 取舍记录

| 日期 | 决定 | 原因 | 影响 |
|---|---|---|---|
| 2026-08-14 | 从当前本地 `custom` 创建实现分支 | 自动输入法功能只存在于 `custom`，公共祖先不包含目标依赖 | 避免重复移植；Clean 首期集成回 `custom` |
| 2026-08-14 | 不同步 `main` 或 upstream | 当前分支冲突较多，用户要求固定本地基线 | 实现不吸收更新后的上游变化，后续同步单独处理 |
| 2026-08-14 | `Startup Profile` 仅作为内部类型 | 用户界面已有 `Launch in`，增加第二个设置会造成语义重复 | UI 只新增一个 `Clean Mode` Picker item |

## 验证记录

- 2026-08-14：确认当前分支为 `codex/clean-mode`，分支起点为本地 `custom` (`a8a63678`)。

## 未决风险

- `supacodeApp` 当前一次性构造 Standard 依赖，runtime 分流需要保持 Settings、更新与 app lifecycle 为公共能力。
- full-size titlebar 区域的 window drag 与 Ghostty mouse input 可能冲突，需以 terminal 输入完整性优先进行实机验证。
- Herdr socket wire contract 位于独立 repository，decoder 必须保持最小字段依赖并忽略未知字段。
