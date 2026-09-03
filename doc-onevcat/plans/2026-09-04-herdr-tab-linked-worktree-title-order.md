# Herdr Tab Linked Worktree 标题顺序调换

**状态：** 已实现

**背景：** linked worktree 的 tab 目录段此前显示为 `repo ↳ checkout`（如 `Warlock ↳ warlock-ios-simulator-replay`）。原规格见 `2026-08-26-herdr-tab-name-design.md`，保持不变，本文只记录段顺序调换。

## 变更

顺序调换为 `checkout ↳ repo`，其余不动：

- 纯文本 `HerdrLinkedWorktreeTitle.displayLabel` 改为 `"\(checkoutName) ↳ \(repoName)"`。accessibility、`.help`、processTitle 的 directory 段经此自动跟随。
- tab bar 富文本 `linkedWorktreeTitleLabel`：仅交换第一段与第三段的文本内容，三个 `Text` 的字号、weight、颜色修饰符原位不动。效果：checkout 使用 15pt 强调色槽位，repo 使用 14.5pt 弱化色槽位。

不变项：分隔符 `↳`、手动目录名优先、agent icon / process title 装饰逻辑、字号与颜色数值。

## 命名

沿用现有符号名（`linkedWorktreeRepoFontSize`、`linkedRepoTone`、`linkedCheckoutTone`），本次不重命名；这些名字描述槽位而非内容，语义以本文为准。

## 测试

`supacodeTests/HerdrTabBarViewTests.swift` 中两处 `displayLabel` 断言同步为调换后的顺序。
