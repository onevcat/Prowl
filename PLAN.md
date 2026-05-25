# Prowl Web Implementation Plan

更新时间：2026-05-25

当前分支：`web-sveltekit-implementation`

当前执行位置：

- [x] 已完成一轮 Web 版本主体实现与多轮增量修正。
- [x] 最新已推送提交停在 `0db497c9 Handle daemon notifications in web client`。
- [ ] 当前还有一组未提交改动：前端处理 daemon 通过 `pane.updated` 广播的 pane 完成状态，并对未聚焦 pane 发出完成通知。
- [ ] `WEB.md` 仍是未跟踪文件，作为当前 Web 规格文档保留，尚未提交。

## 已完成

- [x] 建立 `web/` Bun workspace：`apps/web`、`apps/daemon`、`apps/cli`、`packages/protocol`、`packages/ui`、`packages/config`。
- [x] 使用 Bun 作为唯一 JS/TS 运行与包管理基础；保留 `bun.lock`，并通过脚本禁止 npm/pnpm/yarn lockfile。
- [x] 建立 Biome、TypeScript、Vitest、Bun test、Playwright、bundle/dependency budget 等基础校验脚本。
- [x] 新增 `web/flake.nix` 声明 Playwright 运行环境。
- [x] Playwright 配置已改为只测试 Chrome/Chromium。
- [x] 增加 Playwright/Nix 配置守卫测试，防止重新引入 Firefox/WebKit 项目。
- [x] daemon PTY 已从 `node-pty` 路线切到 Bun Terminal API。
- [x] 增加 daemon runtime 守卫，禁止 `node-pty`、`bun-pty`、`pty.js` 依赖或源码导入。
- [x] 实现共享 wire protocol 包：control message、binary frame codec、版本定义与测试。
- [x] 实现 daemon 基础服务、认证配置、session/bootstrap、pane 创建/附加/更新、IPC socket、状态 schema 与测试。
- [x] 实现 daemon 侧 Git/worktree 操作队列，避免同 repo 并发 git worktree 操作互相踩踏。
- [x] daemon 已将系统 git 操作输出写入 system pane，并让 web client 订阅相关输出。
- [x] daemon custom action 启动时会把目标 pane 标记为 `running`。
- [x] 实现 CLI 基础命令面：daemon/status、repo、worktree、pane/list、version 等，并覆盖单元测试。
- [x] CLI build 脚本会产出 `web/dist/bin/prowl`；daemon build 脚本会产出 `web/dist/bin/prowld`。
- [x] 实现 SvelteKit SPA 壳、AuthGate、Shelf、Canvas、Settings、Command Palette、Diff、TerminalView、PWA update prompt 等主要 UI 模块。
- [x] 实现 AppState，覆盖 panes、worktrees、settings、palette、notifications、renderer pool、WS reconnect、metrics 等核心状态。
- [x] 实现 WebSocket client、RPC、frame encode、backpressure monitor、reconnect 度量与测试。
- [x] 实现 renderer pool，并将长列表/可见区间切到 TanStack virtual。
- [x] 实现 command palette action registry、快捷键、历史记录、fuzzy search worker。
- [x] command palette fuzzy search 使用 `fzf` 包，并通过守卫确保是 ajitid/fzf-for-js 实现。
- [x] 实现 custom actions 设置 UI 与从 command palette 运行 custom action 的 E2E 覆盖。
- [x] 实现 diff parser、worker、语法高亮、inline diff；inline diff 使用 `diff-match-patch`，并避免进入初始 bundle。
- [x] 实现通知权限请求、daemon `notification` message 处理、前端 focus-aware OS notification。
- [x] 实现 PWA manifest、icons、service worker/update prompt 基础覆盖。
- [x] 新增 web favicon 资源。
- [x] 增加 client runtime/storage/boundary/CSP、dependency budget、bundle budget、workflow release artifact 等守卫脚本。
- [x] 最近一次完整校验已通过：
  - [x] `bun run test:web`
  - [x] `bun run typecheck`
  - [x] `bun run check:deps`
  - [x] `bun run build`
  - [x] `bun run check:bundle`
  - [x] `bun run e2e`，Chrome 23 tests passed

## 当前未提交改动

- [x] 已修改 `web/apps/web/src/lib/state/AppState.svelte.ts`：
  - [x] 新增 `handleServerPaneUpdate`
  - [x] 当 daemon `pane.updated` 让未聚焦 pane 从非 `done` 转为 `done` 时，前端会标记 unread 并发通知。
  - [x] `#handleServerMessage` 的 `pane.updated` 分支已改为走该方法。
- [x] 已修改 `web/apps/web/src/lib/state/AppState.test.ts`：
  - [x] 增加未聚焦 pane 通过 daemon update 完成时发通知的测试。
  - [x] 增加已聚焦 pane 通过 daemon update 完成时不发通知的测试。
- [x] 这组改动已通过 targeted 与 full validation：
  - [x] `nix develop ./web -c bash -lc 'cd web && bun run --filter @prowl/web test -- src/lib/state/AppState.test.ts && bun run --filter @prowl/web typecheck && bun run lint'`
  - [x] `nix develop ./web -c bash -lc 'cd web && bun run test:web && bun run typecheck && bun run check:deps && bun run build && bun run check:bundle && bun run e2e'`
- [ ] 尚未 commit。
- [ ] 尚未 push。

## 未完成 / 待继续

- [ ] 提交并推送当前 `pane.updated` 通知补齐改动。
- [ ] 重新按 `WEB.md` 做一次逐项功能审计，确认哪些是 demo-level、哪些已经达到 v1 exit criteria。
- [ ] 清理或归档 `web/.tmp` 下 E2E/perf 临时产物，确认是否需要加入/调整 `.gitignore`。
- [ ] 确认 `WEB.md` 是否要作为正式规格提交；如果要提交，需要先更新其中仍提到 `node-pty`、WebKit 等已经被用户决策替代的内容。
- [ ] 对照 `WEB.md` M1/M2/M3 的性能指标生成明确报告：input p99、cold start、daemon RSS、client RSS、50 pane renderer pool 行为。
- [ ] 完成 remote mode/TLS/token rotation 的实现审计；目前已有 auth/CSP/token 基础，但还需要确认是否达到 M9 标准。
- [ ] 审计 daemon 持久化：当前代码中存在 state schema，但需要确认 `bun:sqlite` 持久化与重启恢复是否完整符合规格。
- [ ] 审计 replay/scrollback：确认 reconnect 后 `pane.replay` 与 64 KiB ring buffer 是否完全符合规格。
- [ ] 审计 backpressure：确认 client 256 KiB 与 daemon 1 MiB/256 KiB 暂停恢复策略是否全链路生效。
- [ ] 审计 CLI 与 native `prowl` parity：命令、输出格式、exit code、local socket fallback 还需逐项对照。
- [ ] 审计 Settings parity：Appearance、Repositories、Custom Actions、Shortcuts、Advanced、Updates disabled/PWA prompt 是否完整。
- [ ] 审计 Shelf/Canvas UX parity：repo/worktree/tab 行为、cycle shortcuts、vertical tabs、broadcast input、pane focus/unread 细节。
- [ ] 审计 Custom Actions 安全与行为：用户信任模型已决定，但 action cwd/env/output/target pane 行为还需对照规格与 native reference。
- [ ] 审计 browser compatibility：用户当前要求 Playwright 只测 Chrome；Safari/Firefox best-effort 不作为当前自动测试目标。
- [ ] 审计 release workflow：Web app static deployment、daemon/CLI binary artifacts、GitHub Actions 流程与 fork 发布规则尚未完整落地。
- [ ] 编写/更新用户文档：如何进入 Nix shell、启动 daemon/web、运行 CLI、运行测试、构建 binaries。

## 下一步建议

- [ ] 先 commit/push 当前通知补齐改动，避免验证过的改动悬空。
- [ ] 再更新 `WEB.md` 中已被明确推翻的技术选择：`node-pty` 改 Bun Terminal API，Playwright 范围改 Chrome-only。
- [ ] 然后按 milestone 从 M0 到 M10 做一次 checklist 审计，每个 milestone 标注：完成、部分完成、未开始、需要测试证明。
- [ ] 最后补齐文档和 release workflow，再考虑开 PR。
