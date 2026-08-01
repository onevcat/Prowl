# 053.006 — 环境补丁改为 launch-scoped

| | |
| --- | --- |
| **日期** | 2026-07-31 |
| **状态** | Implemented(与 005 同分支/PR) |
| **关联** | [000-plan](000-plan.md) · [004-environment-overrides](004-environment-overrides.md) · [005-v1-audit](005-v1-audit.md) |

## 背景:onevcat 发现的串 env

原设计把环境补丁(dedicated home 变量 + 用户 env overrides)在 **surface spawn 时注入
shell 环境**(000-plan「环境 patch 是叠加而非替换」)。onevcat 在 005 审计讨论中指出
这与产品语义冲突,并定位出具体串号链:

```
Agents button → shell 带 CODEX_HOME/OPENAI_API_KEY 出生 → agent 退出(Ctrl+C)
→ env 残留在 shell → 用户手动敲 codex → 继承 profile 的 home/key
→ 手动启动跑在了 profile 账号 / override 端点上
```

产品承诺被澄清为:**profile 属于启动动作,不属于 pane**。经 Prowl 的 Agent Profile
入口(Agents 菜单、Command Palette)拉起的 agent 带 profile;用户手动启动的
agent 必须走自己的默认环境与账号。surface-scoped 注入违反该承诺,且 pane 里后续
任何进程(npm script、curl…)都会静默继承 API key。

## 决策:全部 launch-scoped

三个候选(全 launch-scoped / home 留 surface 的混合 / 维持现状 + 可见化)中,
onevcat 选定**全部 launch-scoped**。已知且接受的行为代价:绑定 pane 内 agent 退出后,
手动 `codex` / `codex resume` 走用户默认账号,profile home 里的 session 手动恢复不到
——回到 profile 上下文的唯一方式是再经 Agents 入口启动。这正是所选语义的直接推论。

## 机制

打入 pane 的命令从 `'codex' …` 变为:

```
env CODEX_HOME='/Users/x/.prowl/agent-profiles/<uuid>' OPENAI_API_KEY="$PROWL_ENV_OPENAI_API_KEY" 'codex' …
```

- **home 路径内联**:非 secret,UUID 派生无空格,经既有 `AgentInvocation.shellQuote`
  单引号渲染;preview 里可见即自文档。
- **override 值经 `PROWL_ENV_<NAME>` carrier 间接引用**:真实值仍走 Ghostty spawn env,
  但顶着 Prowl 保留前缀——没有工具会读它;命令文本、shell history、scrollback 里只有
  引用,永不出现值。name 经 POSIX 校验,引用 token 不含任何用户 shell 文本,注入安全
  不变。`PROWL_` 保留名单保证用户行无法与 carrier 碰撞。
- `env(1)` 是外部二进制,zsh/bash/fish 语法一致(fish 不可靠支持 `VAR=x cmd` 裸前缀,
  故不用裸前缀);`"$VAR"` 展开三家皆同。
- **launch identity 与 launched 进程同生命周期**:`removeAgentEntryIfNeeded`(detection
  层感知 agent 退出的缝)同时清除 `launchProfilesBySurface`——之后手动启动的同 runtime
  agent 不再顶着 profile 名,rooted session 检测的 config root 一并复原。
- Launch Preview 即 `terminalInput` 本身(所打即所见);004 的名字启发式脱敏机制删除
  ——secret 已不在预览里,无需脱敏。

## 连带简化

- 005 曾把「split 继承 / layout restore 重放 env」列为下一步推荐;launch-scoped 语义下
  这两条**不再需要**(surface 上只剩 carrier 变量,不继承恰是正确行为),从 follow-up
  中撤销。
- restore/手动启动"不重放 override"从 known limitation 升格为规则本身。
- source resume 携带环境的缺口不变:结构化 resume 仍需把同一组 token/carrier
  语义带过去,但 053.007 的最小 Profile-aware handoff 波次只配置接收端,不扩展
  outgoing source 的 `AgentResumeRequest`;该缺口继续延期(见
  [007-profile-aware-handoff.md](007-profile-aware-handoff.md))。

## 已知边界

- agent 退出与手动重启发生在同一 detection tick 内时,identity 存在极短的残留窗口
  (presence hold 粒度);可接受,detection 按进程存亡收敛。
- 用户可 `echo $PROWL_ENV_X` 查看 carrier 值:同用户主动检视,与 0600 JSON 同级,
  非泄露面。
- 从 shell history 重放 launch 命令会得到空的 carrier 展开(auth 显式失败,可见),
  这与"手动启动不带 profile env"的语义一致。

## 验证

- Planner 测试:home token 内联渲染、override 排序 token + carrier 映射、reserved 行
  (含 `CODEX_HOME` 伪造)零 token、preview == terminalInput 且不含任何 override 值、
  空值 override 语义保留。
- 终端层测试:agent 退出清除 launch identity。
- `make check` / 全量 `make test` / `make build-app` 全绿;文案与 docs
  (`docs/components/agent-profiles.md`)同步改写为 launch-scoped 语义。
