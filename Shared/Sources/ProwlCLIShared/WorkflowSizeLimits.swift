/// Fixed workflow payload limits. Transport permits JSON escaping and envelope fields.
nonisolated public enum WorkflowSizeLimits {
  public static let payload = 16 * 1024 * 1024
  public static let stderr = 4 * 1024 * 1024
  public static let contentPage = 256 * 1024
  public static let launchPrompt = 128 * 1024
  public static let bundle = 64 * 1024 * 1024
  public static let bundleEntries = 8192
  public static let historyMetadata = 64 * 1024
  public static let transportFrame = payload * 6 + 64 * 1024
}
