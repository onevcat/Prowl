import Foundation

struct GitRemoteWebInfo: Equatable, Sendable {
  let host: String
  let repositoryPath: String
  let port: Int?

  nonisolated init(host: String, repositoryPath: String, port: Int? = nil) {
    self.host = host
    self.repositoryPath = repositoryPath
    self.port = port
  }

  nonisolated var repositoryURL: URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = port
    components.path = "/\(repositoryPath)"
    return components.url
  }
}
