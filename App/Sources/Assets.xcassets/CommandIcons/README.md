# Command Icons

Brand artwork used by the auto-detected tab icon
(`CommandIconMap` → `TabIconImage`). All SVGs ship as monochrome
templates (`template-rendering-intent: "template"` +
`preserves-vector-representation: true`) so they tint with the
surrounding `foregroundStyle` and adapt to dark / light appearance
without per-mode variants.

## Sources

| Source | License | Imagesets |
| ------ | ------- | --------- |
| [Simple Icons](https://simpleicons.org/) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | AWS, Azure, Bun, Curl, Deno, Docker, Git, GitHub, Go, GoogleCloud, Gradle, Homebrew, Kubernetes, MySQL, Neovim, Node, Npm, Pnpm, Podman, PostgreSQL, Python, Rust, SQLite, Swift, Terraform, Tmux, TypeScript, Vim, VSCode, Xcode, Yarn, Gemini, Trae |
| [Lobe Icons](https://github.com/lobehub/lobe-icons) | [MIT](https://github.com/lobehub/lobe-icons/blob/master/LICENSE), © 2023 LobeHub | Amp, Antigravity, ClaudeCode, Cline, Codex, Cursor, Devin, GitHubCopilot, Grok, Kimi, OpenCode |
| [Pi](https://github.com/earendil-works/pi) logo (`packages/ai/src/utils/oauth-page.ts`) | [MIT](https://github.com/earendil-works/pi/blob/main/LICENSE), © 2025 Mario Zechner | Pi |
| [Oh My Pi](https://github.com/can1357/oh-my-pi) favicon (`packages/collab-web/public/favicon.svg`) | [MIT](https://github.com/can1357/oh-my-pi/blob/main/LICENSE), © 2025 Mario Zechner, © 2025-2026 Can Bölük | OMP |
| [Qwen Code](https://github.com/QwenLM/qwen-code) Zed extension (`packages/zed-extension/qwen-code.svg`) | [MIT](https://github.com/QwenLM/qwen-code/blob/main/packages/zed-extension/LICENSE), © 2025 Qwen Team | Qwen |
| Factory brand mark (widely redistributed 67×65 trace) | None found | Droid |

`ClaudeCode` is sourced from the Lobe Icons `claude.svg` mark and
re-authored as a single `fill-rule="evenodd"` path so the `>_` glyph
renders as a native cutout under SwiftUI template tinting (the
upstream two-path version relies on multi-colour `fill` that
`Image(_:)` can't reproduce).

`Pi` merges the three coloured paths of the Pi logo into one
monochrome mark (the first two paths become one `evenodd` path). It
predates the Lobe Icons `pi.svg`, which uses a different grid.

`OMP` is the Oh My Pi favicon path with its gradient fill replaced by
`currentColor`.

`Trae` keeps the Simple Icons path unchanged; only the `<title>` and
fill differ.

`Droid` has no traced open-license source. Lobe Icons and Simple
Icons have no Factory or Droid mark, and the artwork comes from
Factory's own branding. Replace it with a licensed version, or remove
it, if this is a concern.

Icons under MIT must carry the copyright and permission notice in
every distributed copy. `Credits.rtf` does not list them yet.

## Trademarks

Most image files are released under permissive licenses, but the
**marks themselves remain the trademarks of their respective
holders**. Inclusion here is for tool integration only — surfacing a
brand alongside the matching CLI is a long-standing convention in
terminal apps (iTerm2, Warp, Wezterm, …) and not an endorsement.
Remove or replace any entry whose holder objects.

## Adding a new entry

1. Drop a single-colour SVG (use `currentColor` or a bare path) into
   `<Name>.imageset/`.
2. Add a `Contents.json` mirroring an existing imageset
   (`preserves-vector-representation: true` +
   `template-rendering-intent: "template"`).
3. Reference the asset in `CommandIconMap`:
   `TabIconSource(systemSymbol: "<sf-fallback>", assetName: "<Name>")`.
4. (Optional) Verify how it looks via
   **Debug → Icon Catalog** in a DEBUG build.
