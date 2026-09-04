# FX agent icon research

## Recommendation

Use the standalone **`fx` glyph served by the official `fx.sh` header** as the master artwork, not the Vercel triangle/divider, the site favicon, or a newly invented mark. Extract the path named `logo-fx-glyph` from the inline SVG at <https://fx.sh/#logo-fx-glyph>, normalize its current view box (`166.241 0 155.861 156`) to a tight square-ish `viewBox`, and package it as a one-color template SVG following Prowl's existing Herdr agent-image-set convention. Keep a provenance comment or adjacent note naming the URL and retrieval date when the asset is added.

This is the strongest source because it is current, first-party, vector artwork explicitly labeled as the fx logo on the official product site. If explicit brand permission is required for distribution, obtain it from Vercel first: Apache-2.0 covers the repository work but expressly does **not** grant trademark/product-name rights.

## Primary-source findings

- **Canonical project and license.** The local fork identifies its upstream as `vercel-labs/fx` in `/Users/yam/Developer/fx/AGENTS.md` (canonical-repository note) and `/Users/yam/Developer/fx/README.md:16,25`. GitHub identifies <https://github.com/vercel-labs/fx> as the official repository, with `main` as its default branch and Apache-2.0 as its detected license. The repo license is `/Users/yam/Developer/fx/LICENSE` / <https://github.com/vercel-labs/fx/blob/main/LICENSE>; its notice says `Copyright 2025 Vercel, Inc.` and §6 says the license does not grant permission to use the licensor's trade names, trademarks, service marks, or product names.

- **The repository has no distributable production logo file.** A recursive inspection of the local tree and the official `main` tree found no logo SVG and only test fixtures at `tests/e2e/fixtures/favicon.png` and `tests/e2e/fixtures/placeholder-logo.png`; these are not branding sources. The official README instead opens with a block-character `fx` illustration: `/Users/yam/Developer/fx/README.md:1-12` and <https://github.com/vercel-labs/fx/blob/main/README.md#L1-L12>. It was already present in Vercel's initial commit, `439f83ce94a3119bbb4a4c0d86d8fc253ca090d9` (`Pranit <pranit@vercel.com>`, “Initial commit”): <https://github.com/vercel-labs/fx/commit/439f83ce94a3119bbb4a4c0d86d8fc253ca090d9>. This establishes first-party provenance but is a poor direct source for a small SVG because it is terminal character art.

- **The CLI uses a compact textual mark.** `/Users/yam/Developer/fx/src/ui/render.zig:200-204` renders the welcome line as `𝒇x … · Run /help for commands`; tests assert that same `𝒇x` marker. This corroborates that the product identity is the combined italic-f plus x mark, but font-dependent text should not be converted to outlines when a first-party vector exists.

- **The official site supplies that vector.** The live first-party page <https://fx.sh/> links its “source” navigation to `vercel-labs/fx` and renders an inline `<svg class="logo-fx">` whose path is explicitly `id="logo-fx-glyph"`, `fill="currentColor"`, with `viewBox="166.241 0 155.861 156"`. The adjacent slash and `logo-triangle-glyph` are separate SVGs; therefore only `logo-fx-glyph` should be used for an FX agent icon. The site's separate <https://fx.sh/favicon.png> is a 100×100 raster PNG, so it is inferior to the site's canonical vector for Prowl's scalable/template use.

## Prowl / Herdr asset conventions

- Existing agent art lives in one asset catalog image set per icon, for example:
  - `supacode/Assets.xcassets/HerdrAgentCodexIcon.imageset/HerdrAgentCodexIcon.svg`
  - `supacode/Assets.xcassets/HerdrAgentClaudeIcon.imageset/HerdrAgentClaudeIcon.svg`
  - generic fallback: `supacode/Assets.xcassets/HerdrAgentIcon.imageset/HerdrAgentIcon.svg`
- Each sibling `Contents.json` declares one universal SVG plus `preserves-vector-representation: true` and `template-rendering-intent: template`; the SVG uses `currentColor` and a self-contained `viewBox`. See `supacode/Assets.xcassets/HerdrAgentCodexIcon.imageset/Contents.json` and `supacode/Assets.xcassets/HerdrAgentIcon.imageset/Contents.json`.
- Runtime names are centralized in `supacode/Features/Clean/HerdrTabBarView.swift:131-169` (`HerdrTabAgentIcon`), and the existing icons were introduced together by Prowl commit `6b05cba164cfe93809b68581a35257b28b12786a` on 2026-08-23. Prowl's own docs describe these as provider canonical icons and the generic Zap fallback at `docs/components/clean-mode.md:63-66`.

## Proposed eventual asset shape (not created here)

`supacode/Assets.xcassets/HerdrAgentFxIcon.imageset/HerdrAgentFxIcon.svg`, with a matching `Contents.json`; use only the official `logo-fx-glyph` geometry, `fill="currentColor"`, no fixed brand color/background, no Vercel triangle, and no website animation/gradient. Add an `fx` enum case and identifier mapping separately when implementation is requested.

## Provenance / licensing conclusion

The vector geometry should be attributed to the official FX site (`https://fx.sh/`, Vercel) and treated as brand artwork. Repository code/documentation is Apache-2.0, but Apache-2.0 §6 leaves trademark permission outside the license. Using the logo solely to identify the FX integration is the factually appropriate choice; this research does not establish a separate logo/trademark grant. Preserve source attribution and seek Vercel approval if Prowl's release policy requires explicit third-party mark permission.
