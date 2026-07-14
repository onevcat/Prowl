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
| [Simple Icons](https://simpleicons.org/) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | AWS, Azure, Bun, Curl, Deno, Docker, Git, GitHub, Go, GoogleCloud, Gradle, Homebrew, Kubernetes, MySQL, Neovim, Node, Npm, Pnpm, Podman, PostgreSQL, Python, Rust, SQLite, Swift, Terraform, Tmux, TypeScript, Vim, VSCode, Xcode, Yarn, Gemini |
| [Lobe Icons](https://github.com/lobehub/lobe-icons) | [MIT](https://github.com/lobehub/lobe-icons/blob/master/LICENSE) | Amp, ClaudeCode, Codex, GitHubCopilot, Grok, Kimi, OpenCode |

`ClaudeCode` is sourced from the Lobe Icons `claude.svg` mark and
re-authored as a single `fill-rule="evenodd"` path so the `>_` glyph
renders as a native cutout under SwiftUI template tinting (the
upstream two-path version relies on multi-colour `fill` that
`Image(_:)` can't reproduce).

## Trademarks

The image files are released under permissive licenses, but the
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
