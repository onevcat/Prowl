import Testing

@testable import Prowl

struct StyledScreenSnapshotTests {
  @Test func rowsKeepTheDimAttributePerScalar() throws {
    let styled = try #require(StyledScreenSnapshot(styledSnapshot: "a\u{1B}[2mbc\u{1B}[22md\r\n\u{1B}[2m e\u{1B}[0mf"))
    #expect(styled.rows.map(\.text) == ["abcd", " ef"])
    #expect(styled.rows.map(\.dim) == [[false, true, true, false], [true, true, false]])
    #expect(styled.plain.lines == ["abcd", " ef"])
  }

  @Test func colorComponentsAreNotIntensityAttributes() throws {
    let styled = try #require(
      StyledScreenSnapshot(styledSnapshot: "\u{1B}[38;2;2;0;22mx\u{1B}[38;5;2my\u{1B}[2;38;5;22mz"))
    #expect(styled.rows.map(\.dim) == [[false, false, true]])
  }

  @Test func formatterPrefixesAndModesAreNotCells() throws {
    let palette = "\u{1B}]4;0;rgb:1d/1f/21\u{1B}\\\u{1B}]10;rgb:ff/ff/ff\u{7}"
    let styled = try #require(StyledScreenSnapshot(styledSnapshot: palette + "\u{1B}[?2004h\u{1B}[>1ux"))
    #expect(styled.rows.map(\.text) == ["x"])
  }

  @Test func cursorForwardStandsForBlankCells() throws {
    // A TUI that positions each word leaves never-written cells between them.
    let row = try #require(
      StyledScreenSnapshot(styledSnapshot: "\u{1B}[2C[Pasted\u{1B}[1Ctext\u{1B}[C#1]\u{1B}[2m\u{1B}[3Cx"))
    #expect(row.rows.map(\.text) == ["  [Pasted text #1]   x"])
    #expect(row.rows[0].dim.suffix(4) == [true, true, true, true])
    #expect(row.rows[0].dim.prefix(2) == [false, false])
  }

  @Test func escapesWithoutCellsAreSkipped() throws {
    // The formatter restores a pending wrap with DECSC/ECH/DECRC after the content.
    let wrap = try #require(
      StyledScreenSnapshot(styledSnapshot: "\u{1B}[2mab\u{1B}[22m\u{1B}[1;3H \u{1B}7\u{1B}[X\u{1B}8"))
    #expect(wrap.rows.map(\.text) == ["ab "])
    #expect(wrap.rows.map(\.dim) == [[true, true, false]])
    let others = try #require(
      StyledScreenSnapshot(styledSnapshot: "\u{1B}(B\u{1B}=x\u{1B}>\u{1B}Pq;1\u{1B}\\y\u{1B}_z\u{7}"))
    #expect(others.rows.map(\.text) == ["xy"])
  }

  @Test func malformedOrOversizedSnapshotsAreUnreadable() {
    #expect(StyledScreenSnapshot(styledSnapshot: "\u{1B}]unterminated") == nil)
    #expect(StyledScreenSnapshot(styledSnapshot: "\u{1B}Punterminated") == nil)
    #expect(StyledScreenSnapshot(styledSnapshot: "x\u{1B}") == nil)
    #expect(StyledScreenSnapshot(styledSnapshot: "\u{1B}(") == nil)
    #expect(StyledScreenSnapshot(styledSnapshot: "\u{1B}\u{01}x") == nil)
    #expect(
      StyledScreenSnapshot(styledSnapshot: String(repeating: "x", count: StyledScreenSnapshot.maximumSize + 1)) == nil)
  }

  @Test func onlyDimTextIgnoresWhitespaceAndAPrefix() throws {
    let styled = try #require(StyledScreenSnapshot(styledSnapshot: "❯\u{A0}\u{1B}[2mhint\u{1B}[22m  "))
    #expect(styled.rows[0].showsOnlyDimText(from: 1))
    #expect(!styled.rows[0].showsOnlyDimText())
    let typed = try #require(StyledScreenSnapshot(styledSnapshot: "❯ \u{1B}[2mhint\u{1B}[22m typed"))
    #expect(!typed.rows[0].showsOnlyDimText(from: 1))
  }
}
