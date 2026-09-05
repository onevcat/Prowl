# Reference: Keyboard Shortcuts

> The complete, authoritative shortcut table. Source of truth:
> `supacode/App/AppShortcuts.swift` (app actions) and `supacode/Commands/*.swift`
> (menu wiring). Terminal-level keys come from the Ghostty engine.

**Keywords:** keyboard, shortcuts, hotkeys, keybindings, key bindings, remap, ⌘, command, shortcut list

Symbols: **⌘** Command · **⇧** Shift · **⌥** Option · **⌃** Control · **↩** Return · **⌫** Delete · arrows ↑ ↓ ← →

> **Defaults shown.** Most rows are user-remappable (see
> [Remapping](#remapping--customization)). To see a human's _live_ binding, the
> [Command Palette](../components/command-palette.md) displays the resolved key
> next to each action. Automation should use the [`prowl` CLI](../components/cli.md),
> which never depends on keybindings.

## Worktrees & repositories

| Action | Default | Command ID | Remappable |
|--------|---------|------------|------------|
| New Worktree | ⌘N | `new_worktree` | yes |
| Open Worktree (with the selected Open-in app) | ⌘O | `open_worktree` | yes |
| Open Repository… | ⌘⇧O | `open_repository` | yes |
| Open on Code Host (e.g. GitHub) | ⌘⌃G | `open_pull_request` | yes |
| Refresh Worktrees | ⌘⇧R | `refresh_worktrees` | yes |
| Archived Worktrees (panel) | ⌘⌃A | `archived_worktrees` | yes |
| Select Next Worktree _(cycles tabs in Shelf view)_ | ⌘⌃↓ | `select_next_worktree` | yes |
| Select Previous Worktree _(cycles tabs in Shelf view)_ | ⌘⌃↑ | `select_previous_worktree` | yes |
| Back in Worktree History | ⌘⌥[ | `worktree_history_back` | yes |
| Forward in Worktree History | ⌘⌥] | `worktree_history_forward` | yes |
| Select Worktree 1–9 | ⌃1 … ⌃9 | `select_worktree_1` … `_9` | yes |
| Reveal in Sidebar | ⌘⇧L | `reveal_in_sidebar` | yes |
| Rename Branch | ⌘⇧M | `rename_branch` | yes (local) |
| Archive Worktree | _(menu only, no default key)_ | — | — |
| Delete Worktree | ⌘⇧⌫ | _(menu-bound, fixed)_ | no |
| Confirm Worktree Action (in dialogs) | ⌘↩ | _(menu-bound, fixed)_ | no |

## View & layout

| Action | Default | Command ID | Remappable |
|--------|---------|------------|------------|
| Toggle Left Sidebar | ⌘⌃S | `toggle_left_sidebar` | yes |
| Toggle Active Agents Panel | ⌘⌥P | `toggle_active_agents_panel` | yes |
| Toggle Agent Island hot window | Unassigned | `toggle_agent_island` | yes |
| Select Next Agent (in panel) | ⌥⌃↓ | `select_next_active_agent` | yes |
| Select Previous Agent (in panel) | ⌥⌃↑ | `select_previous_active_agent` | yes |
| Jump to Latest Unread | ⌘⌥U | `jump_to_latest_unread` | yes |
| Show Diff | ⌘⇧Y | `show_diff` | yes |
| Show Outgoing Changes | ⌘⌥⇧Y | `outgoing_changes` | yes |
| Toggle Canvas | ⌘⌥↩ | `toggle_canvas` | yes |
| Toggle Shelf | ⌘⇧↩ | `toggle_shelf` | yes |

Agent Island deliberately ships without a shortcut. Assign **Toggle Agent Island** under
Settings → Agents → Display or Settings → Shortcuts. Both use the same recorder and conflict
handling. The globe beside the command explains its system-wide scope on hover. Prowl registers the resolved shortcut globally
only while Agent Island has entries and Prowl is in the background; while Prowl is active, the
normal menu key equivalent handles it. A globally registered chord takes precedence over the
frontmost application's matching shortcut until the island becomes inactive or Prowl returns to
the foreground. If macOS cannot register the shortcut globally, the
shortcut row in either settings page reports the failure until the binding changes or a
later registration succeeds. Reset returns the command to Unassigned.

In the open roster, Arrow Up or `k` and Arrow Down or `j` select; Arrow Left or `h` and Arrow Right
or `l` page; Return opens (Space is an alias); `1`…`9` directly opens a current-page row even when
shortcut modifiers remain held; and `Esc` closes. Opening selects the newest Blocked reminder
first, then the newest unviewed Done reminder, before falling back to the focused agent.

## Shelf view

| Action | Default | Command ID | Remappable |
|--------|---------|------------|------------|
| Select Next Book | ⌘⌃→ | `select_next_shelf_book` | yes |
| Select Previous Book | ⌘⌃← | `select_previous_shelf_book` | yes |
| Select Book 1–9 | ⌥⌃1 … ⌥⌃9 | `select_shelf_book_1` … `_9` | yes |

> In Shelf view, **⌘⌃←/→ flips between books (worktrees)** and **⌘⌃↑/↓ cycles the
> tabs of the open book** (those are the `select_previous/next_worktree` actions).

## Canvas view

| Action | Default | Command ID | Remappable |
|--------|---------|------------|------------|
| Select All Canvas Cards | ⌘⌥A | `select_all_canvas_cards` | yes (local) |
| Arrange Canvas Cards (pack to fit) | ⌘⌥R | `arrange_canvas_cards` | yes (local) |
| Organize Canvas Cards (uniform grid) | ⌘⌥G | `organize_canvas_cards` | yes (local) |
| Tile Canvas Cards (fill viewport) | ⌘⌥T | `tile_canvas_cards` | yes (local) |
| Expand / Restore Canvas Card | ⌘⌥E | `expand_canvas_card` | yes (local) |
| Clear selection | Esc | — | — |
| Zoom | ⌘ + scroll, or pinch | — | — |

## Terminal tabs & panes

These app actions are also registered with Ghostty, so they work while a terminal
pane has focus. The Ghostty action each maps to is shown for reference.

| Action | Default | Command ID | Ghostty action |
|--------|---------|------------|----------------|
| Select Terminal Tab 1–9 | ⌘1 … ⌘9 | `select_terminal_tab_1` … `_9` | `goto_tab:N` |
| Select Previous Tab | ⌘⇧[ | `select_previous_terminal_tab` | `previous_tab` |
| Select Next Tab | ⌘⇧] | `select_next_terminal_tab` | `next_tab` |
| Select Previous Pane | ⌘[ | `select_previous_terminal_pane` | `goto_split:previous` |
| Select Next Pane | ⌘] | `select_next_terminal_pane` | `goto_split:next` |
| Select Pane Up | ⌘⌥↑ | `select_terminal_pane_up` | `goto_split:up` |
| Select Pane Down | ⌘⌥↓ | `select_terminal_pane_down` | `goto_split:down` |
| Select Pane Left | ⌘⌥← | `select_terminal_pane_left` | `goto_split:left` |
| Select Pane Right | ⌘⌥→ | `select_terminal_pane_right` | `goto_split:right` |
| Toggle Split Zoom | ⌘⌥⇧F | `toggle_split_zoom` | `toggle_split_zoom` |
| Find | ⌘F | `start_search` | — |
| Find Next | ⌘G | `find_next` | — |
| Find Previous | ⌘⇧G | `find_previous` | — |

## Terminal engine (Ghostty-managed)

These are **not** Prowl app shortcuts; they are Ghostty terminal bindings, shown
in Prowl's Terminal menu with whatever key Ghostty resolves. Customize them in
your Ghostty config (`~/.config/ghostty/config`). Typical defaults in parentheses.

| Action | Ghostty action | Typical default |
|--------|----------------|-----------------|
| New Terminal (tab) | `new_tab` | ⌘T |
| Close Terminal (pane/surface) | `close_surface` | ⌘W |
| Close Terminal Tab | `close_tab` | ⌘⇧W |
| New Split (vertical / horizontal) | `new_split:right` / `new_split:down` | (Ghostty default; config-only, not in the Terminal menu) |
| Reset Font Size | `reset_font_size` | ⌘0 |
| Increase Font Size | `increase_font_size:1` | ⌘+ |
| Decrease Font Size | `decrease_font_size:1` | ⌘- |
| Hide Find Bar | `end_search` | Esc |
| Use Selection for Find | `search_selection` | ⌘E |

## App & global

| Action | Default | Command ID | Remappable |
|--------|---------|------------|------------|
| Command Palette | ⌘P | `command_palette` | yes |
| Open Settings | ⌘, | `open_settings` | yes |
| Run Script | ⌘R | `run_script` | yes |
| Stop Script | ⌘. | `stop_script` | yes |
| Check for Updates | ⌘⇧U | `check_for_updates` | yes |
| Quit Application | ⌘Q | `quit_application` | **no** (fixed) |

Plus any enabled global or per-repository **Custom Commands**, which can each carry
their own hotkey — see [`components/custom-actions.md`](../components/custom-actions.md).

## Remapping & customization

- **App actions** (scope `configurableAppAction`) are remappable in
  **Settings → Shortcuts**. Overrides are stored in
  `~/.prowl/settings.json` under `keybindingUserOverrides`.
- While recording a remappable shortcut, choose **Clear** to leave the action
  unassigned. The empty shortcut field can be recorded again, or **Reset** can
  restore the default binding.
- **`quit_application`** is fixed (`systemFixedAppAction`) — it can't be remapped.
- **Canvas/local actions** (`localInteraction`, e.g. Arrange/Organize/Expand,
  Rename Branch) are remappable and conflict-checked against all remappable actions.
- **Custom Command** hotkeys take precedence over app shortcuts within the focused
  repository. Local commands win global-command collisions; global bindings use a
  separate internal command ID namespace. Recording an app shortcut already used by an active
  Custom Command is rejected; pre-existing collisions are marked Unavailable in Shortcuts.
- Disabling a Custom Command unregisters its hotkey with every other command surface,
  but preserves the configured key so re-enabling restores it.
- **Terminal engine keys** are owned by Ghostty. Prowl automatically *unbinds*
  any Ghostty key that collides with an app shortcut, and re-binds the
  tab/pane-navigation actions into Ghostty so they work inside the terminal. You
  customize the rest in `~/.config/ghostty/config`.

## Notes for agents

- These are **defaults**. If a human says "my `⌘P` does X", trust them — they may
  have remapped it. The CLI is binding-independent; prefer it for automation.
- When two rows look like they share keys (e.g. `⌥⌃↑/↓` for agent navigation vs
  `⌘⌥↑/↓` for pane navigation), check the **modifiers carefully** — Control vs
  Command distinguishes them.
- `select_previous/next_worktree` (⌘⌃↑/↓) is overloaded by design: in Shelf view
  it cycles the open book's **tabs**; elsewhere it changes the selected worktree.

### Recent input close protection

Closing a pane or tab asks for confirmation if any affected pane received text,
paste, dropped text or file paths, or deletion input within the last 10 seconds.
Active input-method composition also requires confirmation, even after 10 seconds.
This applies to idle agents and ordinary terminals, alongside existing protection
for active agents, unseen results, and long-running commands.

Navigation, copying, scrolling, and the close shortcut itself do not extend this
window. Enter and Escape do not clear it. This guards against accidental closure
while editing; it does not detect saved drafts or protect input indefinitely.
Explicit no-confirmation close operations retain their existing behavior.
