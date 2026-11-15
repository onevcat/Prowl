import SwiftUI

/// Builds `content` only when `value` changes. Apply `.equatable()` to it.
///
/// Use it for a part of a large body that the parent evaluates often while the part rarely
/// changes, such as one sidebar row or one toolbar item. `value` must hold every input that the
/// content shows. The content builds in this view's body, so state that it reads through
/// observation invalidates only this view. An action in the content can be older than the
/// parent: it must read the current state when it runs, or its inputs must be in `value`.
struct EquatableContent<Value: Equatable, Content: View>: View, @MainActor Equatable {
  let value: Value
  @ViewBuilder let content: (Value) -> Content

  init(_ value: Value, @ViewBuilder content: @escaping (Value) -> Content) {
    self.value = value
    self.content = content
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value == rhs.value
  }

  var body: some View {
    content(value)
  }
}
