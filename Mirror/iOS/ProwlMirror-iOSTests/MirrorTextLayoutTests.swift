import Testing

@testable import ProwlMirror_iOS

struct MirrorTextLayoutTests {
  @Test(arguments: [
    "", "one\n\ntwo\n", String(repeating: "中文 🌍 e\u{301}\n", count: 10_000),
    String(repeating: "x", count: 20_000),
  ])
  func chunksPreserveRawTextAndBoundEachLayout(_ text: String) {
    let chunks = MirrorTextLayout.chunks(text)
    #expect(chunks.map(\.raw).joined() == text)
    #expect(chunks.map(\.id) == Array(chunks.indices))
    #expect(chunks.allSatisfy { $0.raw.unicodeScalars.count <= MirrorTextLayout.maximumScalars })
    #expect(
      chunks.allSatisfy { $0.raw.filter { $0 == "\n" }.count <= MirrorTextLayout.maximumLines })
  }

  @Test func onlyIntermediateLineSeparatorsAreRemovedFromDisplay() {
    let text = String(repeating: "line\n", count: 33)
    let chunks = MirrorTextLayout.chunks(text)
    #expect(chunks.count == 2)
    #expect(chunks[0].display == String(chunks[0].raw.dropLast()))
    #expect(chunks[1].display == "line\n")
  }
}
