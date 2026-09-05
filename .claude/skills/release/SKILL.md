---
name: release
description: Build, sign, notarize, and publish a Prowl release.
---

# Release

Build, sign, notarize, and publish a Prowl release.

1. Verify current branch is `main`: `git branch --show-current`
   - If not on main, abort and tell the user to switch first
2. Verify working tree is clean: `git status --porcelain`
   - If dirty, list the changes and ask whether to proceed or abort
3. Sync the docs to the code being released — **before** the version bump and tag:
   - First read `docs-ai/001-fork-bootstrap-and-release-pipeline/release-runbook.md`'s
     **Workflow UI release scope** and **Agent contract release check**, and surface their status to the user. Follow the linked
     contract runbook: run the full `--mode verify` suite with the owner's configured model
     routes, then `--mode publish --report PATH` before bump/tag. Commit the generated receipt,
     version baseline, and matrix. Publication requires the original artifacts/result bundles
     and unchanged source, binaries, and routes within 24 hours; rerun after relevant changes.
     Report T1 headless results separately from D3 handoff acceptance in R2b and D2 review acceptance in R3;
     inventory alone is not a contract pass, and T1 success does not establish workflow release readiness.
   - Run the `sync-docs` skill. It diffs `docs/.sync-meta.json`'s `last_synced_commit`
     against the current `main` HEAD (the code about to ship), updates any docs whose
     implementation changed, and sets `last_synced_commit` to the **current HEAD** —
     the exact commit being released, recorded *before* the bump/tag.
   - Commit the result as its own commit (only `docs/**`, which includes
     `docs/.sync-meta.json`; never `git add .`): e.g. `git commit -m "Sync docs for <VERSION>"`.
     This is required: `release.sh` aborts on a dirty tree, and the doc commit must land
     on `main` *now* so it is an ancestor of the tag and ships inside the release.
   - **Ordering is load-bearing: docs first, then bump + tag. Never tag first.** The baseline
     points at the released code (the pre-doc-commit HEAD), not at the later doc/bump/CHANGELOG
     commits — that is correct and intentional (those commits touch no implementation files,
     so the next sync starts from a tight, accurate diff range).
   - If sync-docs reports "needs human decision" items, resolve or defer them before continuing.
   - Most releases change little or no implementation, so this step is usually a no-op doc-wise
     (just a baseline bump). Keep it cheap — see the `sync-docs` skill's cost notes.
4. Determine the version:
   - If `$ARGUMENTS` is provided, use it as the version (e.g., `2026.3.18`)
   - Otherwise, default to today's date format and confirm with the user before proceeding
5. Generate release notes: `./scripts/release-notes.sh <VERSION>`
   - This script compares HEAD against the previous release tag, gathers commits and
     PR descriptions, and generates user-facing notes via LLM into `build/release-notes.md`.
   - Read the generated `build/release-notes.md`, show the content to the user, and wait
     for explicit confirmation. If the user wants changes, edit the file directly.
   - Alongside that maintainer-facing confirmation, report the agent contract check result
     and evidence location, including any blocked or untested runtimes. Keep this diagnostic
     summary out of the public release notes; apply the release runbook's scope policy.
   - **Do NOT proceed to the next step until the user confirms the release notes.**
6. Run the release script: `./scripts/release.sh <VERSION>`
   - The script reads `build/release-notes.md` (required — refuses to run without it).
   - It handles: version bump, build, sign, notarize, DMG, appcast, GitHub Release, and
     Prowl-Site update. If the tag already exists (e.g., from a prior interrupted run),
     it skips the bump step automatically.
7. Report the GitHub release URL and remind the user to verify:
   - The DMG downloads and installs correctly
   - Sparkle update check works (launch app → Check for Updates)
