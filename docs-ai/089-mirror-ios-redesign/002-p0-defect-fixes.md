# 089.002 — P0: Defect Fixes

## Context

The 2026-11-05 walkthrough of the 088 client found defects D1–D6 (see
[000-plan.md](000-plan.md#background)). P0 fixes D1–D5 before the redesign slices. D6 needs
Host hook data and belongs to S4.

## Change

| Defect | Fix |
| --- | --- |
| D1 | `MirrorLaunchModel.create()` (`Mirror/Shared/MirrorLaunchModel.swift`) sets `agent` to the Profile runtime and `conversation` to `pending`, and names the pane after the Profile when the Host title is empty. `PaneView` hands each newer roster descriptor of the open pane to `MirrorSession.refreshDescriptor(_:)`, so the title, agent and composer hint follow the Host. |
| D2 | `MirrorInjectedText.split(_:)` separates the dispatch completion protocol from the user's text. The user bubble folds it under a "Prowl instructions" disclosure. The client matches the separator that `AgentProfileLaunchPlan` writes; the Host change that marks the text is still open (plan, Host and wire additions). |
| D3 | `MirrorConversationStore` keeps only the latest attention item, and only while the latest status is `blocked`. |
| D4 | `MirrorMarkdown` reads the block structure of agent messages (headings, bullet, ordered and task lists with nesting, quotes, fenced code, tables, rules). `MirrorMarkdownView` renders it, with inline Markdown through `AttributedString` and a parse cache. `MirrorDocumentView` stays for the Screen reader. |
| D5 | The launch form dismisses the keyboard on scroll and has a keyboard Done button. |

Tests: `MirrorMarkdownTests`, `MirrorInjectedTextTests`, the attention and roster-descriptor
tests in `MirrorConversationStoreTests`, and the created-descriptor test in
`MirrorLaunchModelTests`.

## Decisions

- D2 is fixed on the client first because the text comes from one constant and P0 stays
  client only. When the Host marks injected text (S2 or later), the client uses the mark and
  keeps the separator match as a fallback for older Hosts.

## Refs

#1045
