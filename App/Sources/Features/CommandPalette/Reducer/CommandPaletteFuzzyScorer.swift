import Foundation

struct CommandPaletteFuzzyScorer {
  struct PreparedQueryPiece {
    let normalized: String
    let normalizedLowercase: String
    let expectContiguousMatch: Bool
  }

  struct PreparedQuery {
    let piece: PreparedQueryPiece
    let values: [PreparedQueryPiece]?
  }

  struct Match {
    var start: Int
    var end: Int
  }

  struct ItemScore {
    var score: Int
    var labelMatch: [Match]?
    var descriptionMatch: [Match]?
  }

  struct ScoredItem {
    let item: CommandPaletteItem
    let score: ItemScore
    let recencyScore: Double
    let index: Int
  }

  private static let labelPrefixScoreThreshold = 1 << 17
  private static let labelScoreThreshold = 1 << 16

  let query: PreparedQuery
  let allowNonContiguousMatches: Bool
  let recencyByID: [CommandPaletteItem.ID: TimeInterval]
  let now: Date

  init(
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval],
    now: Date,
    allowNonContiguousMatches: Bool = true
  ) {
    self.query = Self.prepareQuery(query)
    self.allowNonContiguousMatches = allowNonContiguousMatches
    self.recencyByID = recencyByID
    self.now = now
  }

  func rankedItems(from items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let scoredItems = items.enumerated().compactMap { index, item in
      let score = scoreItem(item)
      return score.score > 0
        ? ScoredItem(
          item: item,
          score: score,
          recencyScore: recencyScore(for: item),
          index: index
        )
        : nil
    }
    let sorted = scoredItems.sorted { compare($0, $1) < 0 }
    return sorted.map(\.item)
  }

  func scoreItem(_ item: CommandPaletteItem) -> ItemScore {
    guard !query.piece.normalized.isEmpty else {
      return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
    }

    if let values = query.values, !values.isEmpty {
      return scoreItemMultiple(
        label: item.title,
        description: item.subtitle,
        keywords: item.keywords,
        query: values
      )
    }

    return scoreItemForPiece(
      label: item.title,
      description: item.subtitle,
      keywords: item.keywords,
      query: query.piece
    )
  }

  func scoreItemMultiple(
    label: String,
    description: String?,
    keywords: [String],
    query: [PreparedQueryPiece]
  ) -> ItemScore {
    var totalScore = 0
    var totalLabelMatches: [Match] = []
    var totalDescriptionMatches: [Match] = []

    for piece in query {
      let score = scoreItemForPiece(label: label, description: description, keywords: keywords, query: piece)
      if score.score == 0 {
        return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
      }
      totalScore += score.score
      if let labelMatch = score.labelMatch {
        totalLabelMatches.append(contentsOf: labelMatch)
      }
      if let descriptionMatch = score.descriptionMatch {
        totalDescriptionMatches.append(contentsOf: descriptionMatch)
      }
    }

    return ItemScore(
      score: totalScore,
      labelMatch: normalizeMatches(totalLabelMatches),
      descriptionMatch: normalizeMatches(totalDescriptionMatches)
    )
  }

  /// Score one query piece against the item's title (with description fallback)
  /// and each keyword. Keywords act as alternative labels — when one outscores
  /// the title path, we keep title-derived highlight positions so the UI never
  /// paints offsets that don't exist in the visible string.
  func scoreItemForPiece(
    label: String,
    description: String?,
    keywords: [String],
    query: PreparedQueryPiece
  ) -> ItemScore {
    var best = scoreItemSingle(label: label, description: description, query: query)
    for keyword in keywords {
      let keywordScore = scoreItemSingle(label: keyword, description: nil, query: query)
      if keywordScore.score > best.score {
        best = ItemScore(
          score: keywordScore.score,
          labelMatch: best.labelMatch,
          descriptionMatch: best.descriptionMatch
        )
      }
    }
    return best
  }

  func scoreItemSingle(
    label: String,
    description: String?,
    query: PreparedQueryPiece
  ) -> ItemScore {
    let (labelScore, labelPositions) = scoreFuzzy(
      target: label,
      query: query,
      allowNonContiguousMatches: allowNonContiguousMatches && !query.expectContiguousMatch
    )
    if labelScore > 0 {
      let labelPrefixMatch = matchesPrefix(query: query.normalizedLowercase, target: label)
      let baseScore: Int
      if let labelPrefixMatch {
        let prefixLengthBoost = Int(
          (Double(query.normalized.count) / Double(label.count) * 100).rounded()
        )
        baseScore = Self.labelPrefixScoreThreshold + prefixLengthBoost
        return ItemScore(
          score: baseScore + labelScore,
          labelMatch: labelPrefixMatch,
          descriptionMatch: nil
        )
      }
      baseScore = Self.labelScoreThreshold
      return ItemScore(
        score: baseScore + labelScore,
        labelMatch: createMatches(labelPositions),
        descriptionMatch: nil
      )
    }

    if let description {
      let descriptionPrefixLength = description.count
      let descriptionAndLabel = description + label
      let (labelDescriptionScore, labelDescriptionPositions) = scoreFuzzy(
        target: descriptionAndLabel,
        query: query,
        allowNonContiguousMatches: allowNonContiguousMatches && !query.expectContiguousMatch
      )
      if labelDescriptionScore > 0 {
        let labelDescriptionMatches = createMatches(labelDescriptionPositions)
        var labelMatch: [Match] = []
        var descriptionMatch: [Match] = []

        for match in labelDescriptionMatches {
          if match.start < descriptionPrefixLength && match.end > descriptionPrefixLength {
            labelMatch.append(Match(start: 0, end: match.end - descriptionPrefixLength))
            descriptionMatch.append(Match(start: match.start, end: descriptionPrefixLength))
          } else if match.start >= descriptionPrefixLength {
            labelMatch.append(
              Match(
                start: match.start - descriptionPrefixLength,
                end: match.end - descriptionPrefixLength
              )
            )
          } else {
            descriptionMatch.append(match)
          }
        }

        return ItemScore(
          score: labelDescriptionScore,
          labelMatch: labelMatch,
          descriptionMatch: descriptionMatch
        )
      }
    }

    return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
  }

  func compare(_ itemA: ScoredItem, _ itemB: ScoredItem) -> Int {
    let scoreA = itemA.score.score
    let scoreB = itemB.score.score

    if scoreA > Self.labelScoreThreshold || scoreB > Self.labelScoreThreshold {
      if scoreA != scoreB {
        return scoreA > scoreB ? -1 : 1
      }
      if scoreA < Self.labelPrefixScoreThreshold && scoreB < Self.labelPrefixScoreThreshold {
        let comparedByMatchLength = compareByMatchLength(itemA.score.labelMatch, itemB.score.labelMatch)
        if comparedByMatchLength != 0 {
          return comparedByMatchLength
        }
      }
      let labelA = itemA.item.title
      let labelB = itemB.item.title
      if labelA.count != labelB.count {
        return labelA.count - labelB.count
      }
    }

    if scoreA != scoreB {
      return scoreA > scoreB ? -1 : 1
    }

    let itemAHasLabelMatches = !(itemA.score.labelMatch?.isEmpty ?? true)
    let itemBHasLabelMatches = !(itemB.score.labelMatch?.isEmpty ?? true)
    if itemAHasLabelMatches && !itemBHasLabelMatches {
      return -1
    }
    if itemBHasLabelMatches && !itemAHasLabelMatches {
      return 1
    }

    if let itemAMatchDistance = matchDistance(itemA),
      let itemBMatchDistance = matchDistance(itemB),
      itemAMatchDistance != itemBMatchDistance
    {
      return itemBMatchDistance > itemAMatchDistance ? -1 : 1
    }

    if itemA.item.priorityTier != itemB.item.priorityTier {
      return itemA.item.priorityTier < itemB.item.priorityTier ? -1 : 1
    }

    if itemA.recencyScore != itemB.recencyScore {
      return itemA.recencyScore > itemB.recencyScore ? -1 : 1
    }

    let fallback = fallbackCompare(itemA.item, itemB.item)
    if fallback != 0 {
      return fallback
    }

    return itemA.index - itemB.index
  }

  func matchDistance(_ item: ScoredItem) -> Int? {
    var matchStart = -1
    var matchEnd = -1

    if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchStart = descriptionMatch[0].start
    } else if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchStart = labelMatch[0].start
    }

    if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchEnd = labelMatch[labelMatch.count - 1].end
      if let descriptionMatch = item.score.descriptionMatch,
        !descriptionMatch.isEmpty,
        let description = item.item.subtitle
      {
        matchEnd += description.count
      }
    } else if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchEnd = descriptionMatch[descriptionMatch.count - 1].end
    }

    guard matchStart != -1 else { return nil }
    return matchEnd - matchStart
  }

  func compareByMatchLength(_ matchesA: [Match]?, _ matchesB: [Match]?) -> Int {
    guard let matchesA, let matchesB else { return 0 }
    if matchesA.isEmpty && matchesB.isEmpty {
      return 0
    }
    if matchesB.isEmpty {
      return -1
    }
    if matchesA.isEmpty {
      return 1
    }

    let matchLengthA = matchesA[matchesA.count - 1].end - matchesA[0].start
    let matchLengthB = matchesB[matchesB.count - 1].end - matchesB[0].start

    if matchLengthA == matchLengthB {
      return 0
    }
    return matchLengthB < matchLengthA ? 1 : -1
  }

  func fallbackCompare(_ itemA: CommandPaletteItem, _ itemB: CommandPaletteItem) -> Int {
    let labelA = itemA.title
    let labelB = itemB.title
    let descriptionA = itemA.subtitle
    let descriptionB = itemB.subtitle

    let labelDescriptionALength = labelA.count + (descriptionA?.count ?? 0)
    let labelDescriptionBLength = labelB.count + (descriptionB?.count ?? 0)

    if labelDescriptionALength != labelDescriptionBLength {
      return labelDescriptionALength - labelDescriptionBLength
    }

    if labelA != labelB {
      return compareStrings(labelA, labelB)
    }

    if let descriptionA, let descriptionB, descriptionA != descriptionB {
      return compareStrings(descriptionA, descriptionB)
    }

    return 0
  }

  func compareStrings(_ stringA: String, _ stringB: String) -> Int {
    switch stringA.localizedStandardCompare(stringB) {
    case .orderedAscending:
      return -1
    case .orderedDescending:
      return 1
    case .orderedSame:
      return 0
    }
  }

  func recencyScore(for item: CommandPaletteItem) -> Double {
    commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now)
  }

  func scoreFuzzy(
    target: String,
    query: PreparedQueryPiece,
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    if target.isEmpty || query.normalized.isEmpty {
      return (0, [])
    }

    let targetChars = Array(target)
    let queryChars = Array(query.normalized)

    if targetChars.count < queryChars.count {
      return (0, [])
    }

    let targetLower = Array(target.lowercased())
    let queryLower = Array(query.normalizedLowercase)

    return doScoreFuzzy(
      query: queryChars,
      queryLower: queryLower,
      target: targetChars,
      targetLower: targetLower,
      allowNonContiguousMatches: allowNonContiguousMatches
    )
  }

  func doScoreFuzzy(
    query: [Character],
    queryLower: [Character],
    target: [Character],
    targetLower: [Character],
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    let queryLength = query.count
    let targetLength = target.count
    let scores = Array(repeating: 0, count: queryLength * targetLength)
    var mutableScores = scores
    let matches = Array(repeating: 0, count: queryLength * targetLength)
    var mutableMatches = matches

    for queryIndex in 0..<queryLength {
      let queryIndexOffset = queryIndex * targetLength
      let queryIndexPreviousOffset = queryIndexOffset - targetLength
      let queryIndexGtNull = queryIndex > 0

      let queryCharAtIndex = query[queryIndex]
      let queryLowerCharAtIndex = queryLower[queryIndex]

      for targetIndex in 0..<targetLength {
        let targetIndexGtNull = targetIndex > 0

        let currentIndex = queryIndexOffset + targetIndex
        let leftIndex = currentIndex - 1
        let diagIndex = queryIndexPreviousOffset + targetIndex - 1

        let leftScore = targetIndexGtNull ? mutableScores[leftIndex] : 0
        let diagScore = queryIndexGtNull && targetIndexGtNull ? mutableScores[diagIndex] : 0

        let matchesSequenceLength =
          queryIndexGtNull && targetIndexGtNull ? mutableMatches[diagIndex] : 0

        let score: Int
        let scoreContext = CharScoreContext(
          queryChar: queryCharAtIndex,
          queryLowerChar: queryLowerCharAtIndex,
          target: target,
          targetLower: targetLower,
          targetIndex: targetIndex,
          matchesSequenceLength: matchesSequenceLength
        )
        if diagScore != 0 && queryIndexGtNull {
          score = computeCharScore(scoreContext)
        } else if queryIndexGtNull {
          score = 0
        } else {
          score = computeCharScore(scoreContext)
        }

        let isValidScore = score > 0 && diagScore + score >= leftScore

        if isValidScore
          && (allowNonContiguousMatches || queryIndexGtNull
            || startsWith(
              targetLower,
              queryLower,
              at: targetIndex
            ))
        {
          mutableMatches[currentIndex] = matchesSequenceLength + 1
          mutableScores[currentIndex] = diagScore + score
        } else {
          mutableMatches[currentIndex] = 0
          mutableScores[currentIndex] = leftScore
        }
      }
    }

    var positions: [Int] = []
    var queryIndex = queryLength - 1
    var targetIndex = targetLength - 1
    while queryIndex >= 0 && targetIndex >= 0 {
      let currentIndex = queryIndex * targetLength + targetIndex
      let match = mutableMatches[currentIndex]
      if match == 0 {
        targetIndex -= 1
      } else {
        positions.append(targetIndex)
        queryIndex -= 1
        targetIndex -= 1
      }
    }

    positions.reverse()
    let finalScore = mutableScores[queryLength * targetLength - 1]
    return (finalScore, positions)
  }

  struct CharScoreContext {
    let queryChar: Character
    let queryLowerChar: Character
    let target: [Character]
    let targetLower: [Character]
    let targetIndex: Int
    let matchesSequenceLength: Int
  }

  func computeCharScore(_ context: CharScoreContext) -> Int {
    if !considerAsEqual(context.queryLowerChar, context.targetLower[context.targetIndex]) {
      return 0
    }

    var score = 1

    if context.matchesSequenceLength > 0 {
      score += (min(context.matchesSequenceLength, 3) * 6)
      score += max(0, context.matchesSequenceLength - 3) * 3
    }

    if context.queryChar == context.target[context.targetIndex] {
      score += 1
    }

    if context.targetIndex == 0 {
      score += 8
    } else {
      let separatorBonus = scoreSeparatorAtPos(context.target[context.targetIndex - 1])
      if separatorBonus > 0 {
        score += separatorBonus
      } else if isUpper(context.target[context.targetIndex]) && context.matchesSequenceLength == 0 {
        score += 2
      }
    }

    return score
  }

  func considerAsEqual(_ lhs: Character, _ rhs: Character) -> Bool {
    if lhs == rhs {
      return true
    }
    if lhs == "/" || lhs == "\\" {
      return rhs == "/" || rhs == "\\"
    }
    return false
  }

  func scoreSeparatorAtPos(_ char: Character) -> Int {
    switch char {
    case "/", "\\":
      return 5
    case "_", "-", ".", " ", "'", "\"", ":":
      return 4
    default:
      return 0
    }
  }

  func isUpper(_ char: Character) -> Bool {
    guard let scalar = String(char).unicodeScalars.first else { return false }
    return scalar.properties.isUppercase
  }

  func startsWith(
    _ target: [Character],
    _ query: [Character],
    at index: Int
  ) -> Bool {
    guard index + query.count <= target.count else { return false }
    for queryIndex in 0..<query.count where target[index + queryIndex] != query[queryIndex] {
      return false
    }
    return true
  }

  func createMatches(_ offsets: [Int]) -> [Match] {
    var matches: [Match] = []
    var lastMatch: Match?

    for position in offsets {
      if var lastMatch, lastMatch.end == position {
        lastMatch.end += 1
        matches[matches.count - 1] = lastMatch
      } else {
        let match = Match(start: position, end: position + 1)
        matches.append(match)
        lastMatch = match
      }
    }

    return matches
  }

  func normalizeMatches(_ matches: [Match]) -> [Match]? {
    guard !matches.isEmpty else { return nil }

    let sortedMatches = matches.sorted { $0.start < $1.start }
    var normalizedMatches: [Match] = []
    var currentMatch: Match?

    for match in sortedMatches {
      if let existing = currentMatch, matchOverlaps(existing, match) {
        let merged = Match(
          start: min(existing.start, match.start),
          end: max(existing.end, match.end)
        )
        currentMatch = merged
        normalizedMatches[normalizedMatches.count - 1] = merged
      } else {
        currentMatch = match
        normalizedMatches.append(match)
      }
    }

    return normalizedMatches
  }

  func matchOverlaps(_ matchA: Match, _ matchB: Match) -> Bool {
    if matchA.end < matchB.start {
      return false
    }
    if matchB.end < matchA.start {
      return false
    }
    return true
  }

  func matchesPrefix(query: String, target: String) -> [Match]? {
    let targetLower = target.lowercased()
    guard targetLower.hasPrefix(query) else { return nil }
    return [Match(start: 0, end: query.count)]
  }

  private static func prepareQuery(_ original: String) -> PreparedQuery {
    let expectContiguousMatch = queryExpectsExactMatch(original)
    let normalized = normalizeQuery(original)
    let piece = PreparedQueryPiece(
      normalized: normalized.normalized,
      normalizedLowercase: normalized.normalizedLowercase,
      expectContiguousMatch: expectContiguousMatch
    )

    let splitPieces = original.split(separator: " ")
    var values: [PreparedQueryPiece] = []
    if splitPieces.count > 1 {
      for pieceValue in splitPieces {
        let value = String(pieceValue)
        let expectExactMatchPiece = queryExpectsExactMatch(value)
        let normalizedPiece = normalizeQuery(value)
        if normalizedPiece.normalized.isEmpty {
          continue
        }
        values.append(
          PreparedQueryPiece(
            normalized: normalizedPiece.normalized,
            normalizedLowercase: normalizedPiece.normalizedLowercase,
            expectContiguousMatch: expectExactMatchPiece
          )
        )
      }
    }

    return PreparedQuery(
      piece: piece,
      values: values.isEmpty ? nil : values
    )
  }

  private static func normalizeQuery(_ original: String) -> (normalized: String, normalizedLowercase: String) {
    var pathNormalized = String()
    pathNormalized.reserveCapacity(original.count)
    for char in original {
      if char == "\\" {
        pathNormalized.append("/")
      } else {
        pathNormalized.append(char)
      }
    }

    var normalized = String()
    normalized.reserveCapacity(pathNormalized.count)
    for char in pathNormalized {
      if char == "*" || char == "…" || char == "\"" || char.isWhitespace {
        continue
      }
      normalized.append(char)
    }

    if normalized.count > 1, normalized.hasSuffix("#") {
      normalized.removeLast()
    }

    return (normalized, normalized.lowercased())
  }

  private static func queryExpectsExactMatch(_ query: String) -> Bool {
    query.hasPrefix("\"") && query.hasSuffix("\"")
  }
}
