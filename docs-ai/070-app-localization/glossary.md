# Simplified Chinese Glossary

Living document. Follow it for every `zh-Hans` value in `supacode/Localizable.xcstrings`, and
update it in the same change when a new term needs a decision. Background and tooling:
[000-plan.md](000-plan.md).

## Not translated

| Term | Write | Note |
| --- | --- | --- |
| Agent | Agent | Never 智能体 or 代理 |
| worktree | worktree | A git term. Lowercase inside a sentence; `Worktree` when it is a whole title, such as the menu name |
| Bundle (workflow) | Bundle | Same word as the DSL, the CLI, and the docs |
| Prowl, GitHub, Ghostty, SF Symbol, CLI, PR, URL, YAML, JSON | as is | Command names such as `prowl` and `gh` stay lowercase |

## Feature names

| English | 中文 |
| --- | --- |
| Shelf / Shelf View | 书架 / 书架视图 |
| spine / book | 书脊 / 书 (“Select Book 3” → 选择第 3 本书) |
| Canvas / card | 画布 / 卡片 |
| Agent Island / the island | Agent 灵动岛 / 灵动岛 |
| Active Agents | 活跃 Agent |
| Remote Mirror / mirror (v.) | 远程镜像 / 镜像 |
| Command Palette | 命令面板 |
| Workflow / Workflow History | 工作流 / 工作流历史 |
| Handoff / hand off | 交接 |
| Agent Profile / profile | Agent 配置 / 配置 |
| Agent Skills / skill | Agent 技能 / 技能 |

When “profile” and “configuration” meet in one sentence, write 设置 for “configuration”.

## Agent states

| English | 中文 |
| --- | --- |
| Working | 工作中 |
| Blocked | 需处理 |
| Done | 已完成 |
| Idle | 空闲 |

## Interface

| English | 中文 |
| --- | --- |
| pane / panel / tab | 窗格 / 面板 / 标签页 |
| split (n.) / split (v.) | 分屏 / 拆分 |
| sidebar / toolbar | 边栏 / 工具栏 |
| Dock / Finder / Trash / notch | 程序坞 / 访达 / 废纸篓 / 刘海 |
| badge | 标记 |
| tint (n.) / tint (v.) | 色调 / 着色 |
| font size | 字号 (增大字号, 减小字号, 重置字号) |
| built-in, bundled | 内置 |
| active | 活跃 for an agent; 进行中 for a run; 当前 for the focused pane |
| dismiss | 关闭 |
| pin / Pin to top | 固定 / 置顶 |
| Reveal in Finder | 在访达中显示 |
| account | 账户 |
| In Place | 就地 |

## Git and GitHub

| English | 中文 |
| --- | --- |
| repository / workspace / branch | 仓库 / 工作区 / 分支 |
| pull request | 拉取请求 (keep `PR` where the source says PR) |
| Ready for review | 可审查 |
| check / job / task | 检查 / 作业 / 任务 |
| fetch / pull | 获取 / 拉取 |
| outgoing changes | 待推送的更改 |
| rebase / squash / merge | 变基 / 压缩合并 / 合并 |
| checkout (n.) | 检出 |
| symlink / link | 符号链接 / 链接 |

## Scripts and workflows

| English | 中文 |
| --- | --- |
| Setup Script / Run Script / Archive Script | 初始化脚本 / 运行脚本 / 归档脚本 |
| run (n.) / execution | 运行 (运行记录 for an item in a history list) / 执行 |
| role / step / delivery / verdict / action | 角色 / 步骤 / 交付 / 判定 / 操作 |
| starter | 起始模板 |
| Attempt 3 / Invocation 3 / Round 3 | 第 3 次尝试 / 第 3 次调用 / 第 3 轮 |
| review (a Bundle) | 审阅 |
| unrestricted / least-restricted | 不受限制 / 限制最少 |

## Remote Mirror

| English | 中文 |
| --- | --- |
| Host / Client / device | 主机 / 客户端 / 设备 |
| pair / pairing code | 配对 / 配对码 |
| Take Over / Revoke / Forget | 接管 / 撤销 / 忘记 |
| mirror (n., one connected viewer) | 镜像 (`%lld 个镜像`) |
| Last seen / Last connected | 上次在线 / 上次连接 |

## Playful copy

The loading messages of `supacode/App/AppLoadingView.swift` are jokes. Do not translate them
word for word: give each English line a Chinese line with a joke that works in Chinese developer
culture (`Aligning refs` → 正在对齐颗粒度, `Reducing agent flattery` → 正在帮 Agent 戒掉彩虹屁).

## Punctuation and spacing

- One space between Chinese and Latin letters or digits: `新建 worktree`, `第 3 次尝试`.
  No space next to Chinese punctuation.
- Full-width punctuation in Chinese text: `，。；：？！（）“”`. A shortcut hint is
  `归档（⌘↩）`.
- Ellipsis is `…`, never `...`. A dash between clauses is `——`.
- Keep arrows in paths: `设置 → 命令`. Put a UI label that is quoted in a sentence in `“”`.
- When a translation changes the order of two or more placeholders, number every one of them:
  `%1$@`, `%2$lld`. `make check-localization` rejects a mix of numbered and plain placeholders.
