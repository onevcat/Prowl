import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case shortcuts
  case worktree
  case bootstrap
  case updates
  case advanced
  case github
  case repository(Repository.ID)
}
