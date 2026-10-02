import Foundation

struct WorktreeTerminalNotification: Identifiable, Equatable, Sendable {
  let id: UUID
  let surfaceId: UUID
  let title: String
  let body: String
  let createdAt: Date
  var workflowRunID: UUID?
  var isRead: Bool

  init(
    id: UUID = UUID(),
    surfaceId: UUID,
    title: String,
    body: String,
    createdAt: Date = .distantPast,
    isRead: Bool = false,
    workflowRunID: UUID? = nil
  ) {
    self.id = id
    self.surfaceId = surfaceId
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.isRead = isRead
    self.workflowRunID = workflowRunID
  }

  var content: String {
    [title, body].filter { !$0.isEmpty }.joined(separator: " - ")
  }
}
