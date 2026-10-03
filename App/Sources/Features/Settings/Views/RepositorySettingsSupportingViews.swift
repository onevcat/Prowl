import AppKit
import SwiftUI

struct InlineEditableCellButton<Label: View>: View {
  let isActive: Bool
  let activeColor: Color
  let contentAlignment: Alignment
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    contentAlignment: Alignment = .leading,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.contentAlignment = contentAlignment
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity, alignment: contentAlignment)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: contentAlignment)
    .onHover { hovering in
      isHovering = hovering
    }
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    }
  }

  private var borderColor: Color {
    if isActive {
      return activeColor
    }
    if isHovering {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

struct InlineEditableFieldContainer<Content: View>: View {
  let isActive: Bool
  let activeColor: Color
  @ViewBuilder let content: () -> Content
  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.content = content
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovering in
        isHovering = hovering
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(borderColor, lineWidth: borderWidth)
      }
  }

  private var borderColor: Color {
    if isActive {
      return activeColor
    }
    if isHovering {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

struct FirstResponderAnchorView: NSViewRepresentable {
  let onResolve: (NSView) -> Void

  func makeNSView(context: Context) -> FirstResponderAnchorNSView {
    let view = FirstResponderAnchorNSView()
    onResolve(view)
    return view
  }

  func updateNSView(_ nsView: FirstResponderAnchorNSView, context: Context) {
    onResolve(nsView)
  }
}

final class FirstResponderAnchorNSView: NSView {
  override var acceptsFirstResponder: Bool {
    true
  }
}

struct BranchPickerPopover: View {
  @Binding var searchText: String
  let options: [String]
  let automaticLabel: String
  let selection: String?
  let onSelect: (String?) -> Void
  @FocusState private var isSearchFocused: Bool

  var filteredOptions: [String] {
    if searchText.isEmpty { return options }
    return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Filter branches...", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .padding(8)
      Divider()
      List {
        Button {
          onSelect(nil)
        } label: {
          HStack {
            Text(automaticLabel)
            Spacer()
            if selection == nil {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            }
          }
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(filteredOptions, id: \.self) { ref in
          Button {
            onSelect(ref)
          } label: {
            HStack {
              Text(ref)
              Spacer()
              if selection == ref {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.plain)
    }
    .frame(width: 300, height: 350)
    .onAppear { isSearchFocused = true }
  }
}

struct CustomCommandShortcutConflict: Equatable {
  let newCommandID: UserCustomCommand.ID
  let newCommandTitle: String
  let existingCommandID: UserCustomCommand.ID
  let existingCommandTitle: String
  let shortcutDisplay: String
}

struct PendingCustomShortcut: Equatable {
  let commandID: UserCustomCommand.ID
  let shortcut: UserCustomShortcut
}

struct ScriptEnvironmentRow: View {
  let name: String
  var value: String?
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name)
        .monospaced()
      if let value {
        Text(value)
          .foregroundStyle(.secondary)
          .monospaced()
      }
      Text(description)
        .foregroundStyle(.tertiary)
    }
  }
}
