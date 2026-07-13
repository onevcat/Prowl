import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteControlRouterTests {
  private let token = "test-access-token"
  private let paneID = UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!

  @Test func bridgeIsPinnedToIPv4Loopback() {
    #expect(RemoteControlServer.loopbackHost == "127.0.0.1")
    #expect(RemoteControlServer.port == 39466)
  }

  @Test func unauthorizedRequestsDoNotReachLiveStateProviders() throws {
    let recorder = RouterRecorder()
    let response = makeRouter(recorder: recorder).route(.init(method: "GET", target: "/v1/agents"))

    #expect(response.statusCode == 401)
    #expect(recorder.agentRequests == 0)
    #expect(errorCode(in: response) == "UNAUTHORIZED")
  }

  @Test func agentsUseOpaqueIDsAndDoNotIncludeViewportContent() throws {
    let recorder = RouterRecorder()
    recorder.viewport = "token=/Users/alice/secret/.env"
    let response = makeRouter(recorder: recorder).route(authorizedRequest(target: "/v1/agents"))
    let body = try #require(String(bytes: response.body, encoding: .utf8))

    #expect(response.statusCode == 200)
    #expect(!body.contains("/Users/alice/secret"))
    #expect(!body.contains(paneID.uuidString))
    #expect(agentID(in: response) != paneID.uuidString)
  }

  @Test func readRequiresOpaqueIDAndCapsLinesAndBytes() throws {
    let recorder = RouterRecorder()
    recorder.viewport = (0..<100).map { "\($0)-🦊" }.joined(separator: "\n")
    let router = makeRouter(recorder: recorder)
    let opaqueID = try #require(agentID(in: router.route(authorizedRequest(target: "/v1/agents"))))

    let rawIDResponse = router.route(authorizedRequest(target: "/v1/agents/\(paneID.uuidString)/read"))
    let readResponse = router.route(authorizedRequest(target: "/v1/agents/\(opaqueID)/read?last=80"))
    let payload = try #require(jsonObject(in: readResponse) as? [String: Any])
    let text = try #require(payload["text"] as? String)

    #expect(rawIDResponse.statusCode == 404)
    #expect(readResponse.statusCode == 200)
    #expect(payload["truncated"] as? Bool == true)
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count <= RemoteControlRouter.maximumLineCount)
    #expect(text.utf8.count <= RemoteControlRouter.maximumTextByteCount)
    #expect(recorder.viewportRequests == 1)
  }

  @Test func readPreservesUTF8WhenTheViewportExceedsTheByteLimit() throws {
    let recorder = RouterRecorder()
    recorder.viewport = String(repeating: "🦊", count: RemoteControlRouter.maximumTextByteCount)
    let router = makeRouter(recorder: recorder)
    let opaqueID = try #require(agentID(in: router.route(authorizedRequest(target: "/v1/agents"))))
    let response = router.route(authorizedRequest(target: "/v1/agents/\(opaqueID)/read"))
    let payload = try #require(jsonObject(in: response) as? [String: Any])
    let text = try #require(payload["text"] as? String)

    #expect(payload["truncated"] as? Bool == true)
    #expect(text.utf8.count <= RemoteControlRouter.maximumTextByteCount)
    #expect(!text.contains("�"))
  }

  @Test func writeLikePathsAndNonGETMethodsAreRejectedWithoutViewportAccess() throws {
    let recorder = RouterRecorder()
    let router = makeRouter(recorder: recorder)
    let unknownResponse = router.route(authorizedRequest(target: "/v1/send"))
    let methodResponse = router.route(
      .init(method: "POST", target: "/v1/agents", headers: ["Authorization": "Bearer \(token)"]))

    #expect(unknownResponse.statusCode == 404)
    #expect(methodResponse.statusCode == 405)
    #expect(recorder.viewportRequests == 0)
  }

  private func makeRouter(recorder: RouterRecorder) -> RemoteControlRouter {
    RemoteControlRouter(
      accessTokenProvider: { self.token },
      agentsProvider: {
        recorder.agentRequests += 1
        return [
          RemoteControlAgentSnapshot(
            paneID: self.paneID,
            type: "codex",
            name: "codex",
            status: "working",
            projectName: "Prowl",
            branchName: "relay/mobile-control",
            lastChangedAt: Date(timeIntervalSince1970: 0)
          )
        ]
      },
      viewportProvider: { paneID in
        recorder.viewportRequests += 1
        return paneID == self.paneID ? recorder.viewport : nil
      }
    )
  }

  private func authorizedRequest(target: String) -> RemoteControlHTTPRequest {
    .init(method: "GET", target: target, headers: ["Authorization": "Bearer \(token)"])
  }

  private func jsonObject(in response: RemoteControlHTTPResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: response.body)
  }

  private func errorCode(in response: RemoteControlHTTPResponse) -> String? {
    guard let object = try? jsonObject(in: response),
      let root = object as? [String: Any],
      let error = root["error"] as? [String: Any]
    else { return nil }
    return error["code"] as? String
  }

  private func agentID(in response: RemoteControlHTTPResponse) -> String? {
    guard let object = try? jsonObject(in: response),
      let root = object as? [String: Any],
      let agents = root["agents"] as? [[String: Any]]
    else { return nil }
    return agents.first?["id"] as? String
  }
}

@MainActor
private final class RouterRecorder {
  var agentRequests = 0
  var viewportRequests = 0
  var viewport = "ready"
}
