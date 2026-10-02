struct TerminalTabContextMenuActions {
  let renameTab: (TerminalTabID) -> Void
  let changeIcon: (TerminalTabID) -> Void
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
}
