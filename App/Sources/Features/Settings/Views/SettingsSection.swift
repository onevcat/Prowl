import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case shortcuts
  case worktree
  case updates
  case advanced
  case github
  case customCommands
  case remoteMirror
  case agentDisplay
  case profiles
  case workflows
  case commandLineTool
  case repository(Repository.ID)
}
