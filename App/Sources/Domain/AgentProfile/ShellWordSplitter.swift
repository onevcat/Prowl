import Foundation

/// Splits a user-authored extra-arguments string into literal argv tokens.
///
/// Best-effort POSIX-style word splitting: whitespace separates tokens, single
/// and double quotes group characters, and a backslash escapes the next
/// character outside single quotes. There is no expansion of any kind — a
/// token is always a literal argument value, never shell input. An
/// unterminated quote consumes the rest of the input, so the launch preview
/// shows exactly what would be sent instead of failing the save.
nonisolated enum ShellWordSplitter {
  static func split(_ input: String) -> [String] {
    enum Quote {
      case none, single, double
    }

    var tokens: [String] = []
    var current = ""
    var hasToken = false
    var quote = Quote.none
    var index = input.startIndex

    while index < input.endIndex {
      let character = input[index]
      index = input.index(after: index)
      switch quote {
      case .none:
        switch character {
        case "'":
          quote = .single
          hasToken = true
        case "\"":
          quote = .double
          hasToken = true
        case "\\":
          if index < input.endIndex {
            current.append(input[index])
            index = input.index(after: index)
          }
          hasToken = true
        case let character where character.isWhitespace:
          if hasToken {
            tokens.append(current)
            current = ""
            hasToken = false
          }
        default:
          current.append(character)
          hasToken = true
        }
      case .single:
        if character == "'" {
          quote = .none
        } else {
          current.append(character)
        }
      case .double:
        if character == "\"" {
          quote = .none
        } else if character == "\\", index < input.endIndex,
          input[index] == "\"" || input[index] == "\\"
        {
          current.append(input[index])
          index = input.index(after: index)
        } else {
          current.append(character)
        }
      }
    }
    if hasToken {
      tokens.append(current)
    }
    return tokens
  }
}
