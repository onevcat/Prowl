### Change content

| summary | commit hash | status |
| --- | --- | --- |
| Fix initial prompt path by normalizing trailing slash so working directory is set correctly on launch. | `fbfeec4` | Merged upstream |
| Align embedded Ghostty accessibility with Ghostty.app so AX-driven dictation/transcription tools like Typeless can recognize terminal panes correctly. | `aa57f08` | Merged upstream |
| Add fork sync and personal release workflow docs plus helper scripts (`sync-upstream-main.sh`, `release-to-fork.sh`). | `3599f5f` | Fork only |
| Remove `Cmd+Delete` shortcut from worktree archive actions, so the key can be handled by Ghostty/terminal behavior. | `022bb87` | Fork only |
| Harden fork release script: detect target repo from `origin` and add fallback (`gh api` + upload) when `gh release create` fails. | `058177e` | Fork only |
| Add local app notarization flow to fork release script (Developer ID signing + `notarytool` + stapling) for personal releases. | `a66c4b2` | Fork only |
| Clarify fork customization guidance and release workflow docs for this fork. | `b7f4e0b` | Fork only |
| Ignore local build artifacts in fork working tree to reduce noise. | `cccd36d` | Fork only |
| Harden upstream sync script/docs with deterministic fetch/merge flow and safer failure handling. | `56deb49` | Fork only |
| Add repo-scoped custom command buttons with configurable icon/title/command/execution mode and shortcut overrides. | `76046bc` | Fork only |
| Refine custom shortcut editor layout by tightening modifier symbol and toggle spacing. | `b5c58e4` | Fork only |
| Execute Terminal Input custom commands by injecting return key so the command runs immediately. | `562042f` | Fork only |
| Disable push-triggered `tip` release workflow in fork to avoid expected CI failures. | `85b3fd7` | Fork only |
| Enforce notarized-only fork releases; block non-notarized publishing path in release script and docs. | `2ab70fd` | Fork only |
| Move repo-scoped settings files to `~/.prowl/repo/<repo-last-path>/` (was `~/.supacode/repo/…`) with legacy migration from repo root files. | `ea9259f` | Fork only |
| Add `/fork-release` slash command for upstream sync and private release workflow. | `64829dc` | Fork only |
| Add diff window with file tree sidebar and YiTong DiffView for viewing worktree changes. | `0d03848`, `09194c4` | Fork only |
| Wire up diff badge click in worktree row, `Cmd+]` shortcut, and Show Diff menu item. | `59dc4f6` | Fork only |
| Preload all file contents on diff window open for instant file switching. | `5850576` | Fork only |
| Add toolbar with sidebar toggle, diff style picker (split/unified), `Cmd+W` close, and window frame persistence. | `8985fc2` | Fork only |
