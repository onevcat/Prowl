import os

/// The iOS mirror's unified log. Collect it from a device with Console.app, or with
/// `sudo log collect --device --last 30m` and the predicate `subsystem == "com.onevcat.prowl.mirror-ios"`.
/// Ids are public; screen text, prompts and messages stay private.
nonisolated enum MirrorLog {
  private static let subsystem = "com.onevcat.prowl.mirror-ios"

  /// Connection status, subscriptions and protocol errors.
  static let session = Logger(subsystem: subsystem, category: "Session")
  /// Host commands: sends, prompt answers, keys, and their results.
  static let commands = Logger(subsystem: subsystem, category: "Commands")
  /// Screen prompts as they open, change and close, in Chat and Terminal.
  static let prompts = Logger(subsystem: subsystem, category: "Prompts")
}
