import AppKit
import SwiftUI

struct TerminalTabView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isDragging: Bool
  let tabIndex: Int
  let fixedWidth: CGFloat?
  let hasNotification: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onRename: (String) -> Void
  let onChangeIcon: () -> Void
  @Binding var closeButtonGestureActive: Bool
  let isEditing: Bool
  let onBeginRename: () -> Void
  let onEndRename: () -> Void

  @State private var isHovering = false
  @State private var isHoveringClose = false
  @State private var isPressing = false
  @State private var editingTitle = ""
  @State private var initialEditingTitle = ""
  @State private var cancelOnExit = false
  @State private var tabWidth: CGFloat = 0
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    ZStack(alignment: .leading) {
      Button(action: onSelect) {
        TerminalTabLabelView(
          tab: tab,
          isActive: isActive,
          isHoveringTab: isHovering,
          isHoveringClose: isHoveringClose,
          shortcutHint: shortcutHint,
          showsShortcutHint: showsShortcutHint
        )
      }
      .buttonStyle(TerminalTabButtonStyle(isPressing: $isPressing))
      .frame(
        minWidth: TerminalTabBarMetrics.tabMinWidth,
        maxWidth: .infinity,
        minHeight: TerminalTabBarMetrics.tabHeight,
        maxHeight: TerminalTabBarMetrics.tabHeight
      )
      .frame(width: fixedWidth)
      .contentShape(.rect)
      .help("Open tab \(tab.displayTitle)")
      .accessibilityLabel(tab.displayTitle)
      .allowsHitTesting(!isEditing)
      .opacity(isEditing ? 0 : 1)

      ZStack {
        TabNotificationDot()
          .opacity(isShowingNotificationDot ? 1 : 0)
          .allowsHitTesting(false)
        TerminalTabCloseButton(
          isHoveringTab: isHovering,
          isDragging: isDragging,
          isShowingShortcutHint: showsShortcutHint,
          closeAction: onClose,
          closeButtonGestureActive: $closeButtonGestureActive,
          isHoveringClose: $isHoveringClose
        )
      }
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering)
      .animation(.easeInOut(duration: 0.2), value: hasNotification)
      .padding(.leading, TerminalTabBarMetrics.tabHorizontalPadding)
      .opacity(isEditing ? 0 : 1)
      .allowsHitTesting(!isEditing)
    }
    .overlay {
      if isEditing {
        HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
          if tab.isDirty || tab.icon != nil {
            TerminalTabIconBadge(tab: tab, isActive: isActive)
          }
          RenameTextField(
            text: $editingTitle,
            onCommit: { onEndRename() },
            onCancel: {
              cancelOnExit = true
              onEndRename()
            }
          )
          .padding(.horizontal, TerminalTabBarMetrics.contentSpacing)
          .background(
            RoundedRectangle(
              cornerRadius: TerminalTabBarMetrics.renameFieldCornerRadius,
              style: .continuous
            )
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
              RoundedRectangle(
                cornerRadius: TerminalTabBarMetrics.renameFieldCornerRadius,
                style: .continuous
              )
              .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
          )
          .accessibilityLabel("Rename tab")
        }
        .padding(.leading, TerminalTabBarMetrics.closeButtonSize + TerminalTabBarMetrics.contentSpacing)
        .padding(.trailing, TerminalTabBarMetrics.tabHorizontalPadding)
        .padding(.vertical, TerminalTabBarMetrics.renameFieldInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }
    }
    .background {
      TerminalTabBackground(
        isActive: isActive,
        isPressing: isPressing,
        isDragging: isDragging,
        isHovering: isHovering
      )
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering)
    }
    .clipShape(.capsule)
    .contentShape(.capsule)
    .onHover { hovering in
      isHovering = hovering
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      tabWidth = width
    }
    .simultaneousGesture(
      SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { value in
        if isInIconHitArea(value.location) {
          onChangeIcon()
        } else if !tab.isTitleLocked {
          onBeginRename()
        }
      }
    )
    .onChange(of: isEditing) { _, editing in
      if editing {
        editingTitle = tab.displayTitle
        initialEditingTitle = tab.displayTitle
        cancelOnExit = false
      } else if cancelOnExit {
        cancelOnExit = false
      } else if editingTitle != initialEditingTitle {
        onRename(editingTitle)
      }
    }
    .zIndex(isActive ? 2 : (isDragging ? 3 : 0))
    .overlay {
      MiddleClickView(action: onClose)
    }
  }

  private var shortcutHint: String? {
    AppShortcuts.terminalTabSelectionDisplay(at: tabIndex, in: resolvedKeybindings)
  }

  private var showsShortcutHint: Bool {
    commandKeyObserver.isPressed && shortcutHint != nil
  }

  private var isShowingNotificationDot: Bool {
    hasNotification && !isHovering && !isHoveringClose && !isDragging && !showsShortcutHint
  }

  /// Hit zone for the icon-picker double-click, in tab-local coordinates.
  /// The close button now lives in the leading slot, so this mirrors to the
  /// trailing placeholder (the opposite slot) to stay clear of it: a
  /// double-click there opens the icon picker, while the rest of the tab
  /// routes to inline rename.
  private func isInIconHitArea(_ point: CGPoint) -> Bool {
    guard tab.isDirty || tab.icon != nil else { return false }
    guard tabWidth > 0 else { return false }
    let minX = tabWidth - TerminalTabBarMetrics.tabHorizontalPadding - TerminalTabBarMetrics.closeButtonSize
    return point.x >= minX
  }
}

private struct TabNotificationDot: View {
  var body: some View {
    Circle()
      .fill(.orange)
      .frame(width: 6, height: 6)
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
      .accessibilityLabel("Unread notifications")
  }
}

private struct MiddleClickView: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> MiddleClickNSView {
    MiddleClickNSView(action: action)
  }

  func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
    nsView.action = action
  }
}

private final class MiddleClickNSView: NSView {
  var action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent,
      event.type == .otherMouseDown || event.type == .otherMouseUp
    else { return nil }
    return super.hitTest(point)
  }

  override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 {
      action()
    } else {
      super.otherMouseUp(with: event)
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Inline rename field for tabs.
///
/// SwiftUI's `TextField` + `@FocusState` plus `NSApp.sendAction(selectAll:)`
/// is unreliable here: the focus promotion spans multiple runloop ticks, and
/// `sendAction` along the responder chain reaches whatever owns the chain
/// first — typically the active GhosttySurface, which happily selects every
/// glyph in the terminal instead of the tab title. Owning the `NSTextField`
/// directly lets us drive `selectAll` on its own field editor without
/// fighting SwiftUI's focus timing.
private struct RenameTextField: NSViewRepresentable {
  @Binding var text: String
  let onCommit: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> RenameNSTextField {
    let field = RenameNSTextField()
    field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    field.textColor = .labelColor
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byClipping
    field.stringValue = text
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ nsView: RenameNSTextField, context: Context) {
    context.coordinator.parent = self
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: RenameTextField
    private var hasResolved = false

    init(parent: RenameTextField) { self.parent = parent }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.cancelOperation(_:)):
        hasResolved = true
        parent.onCancel()
        return true
      case #selector(NSResponder.insertNewline(_:)):
        hasResolved = true
        parent.onCommit()
        return true
      default:
        return false
      }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      guard !hasResolved else { return }
      hasResolved = true
      parent.onCommit()
    }
  }
}

private final class RenameNSTextField: NSTextField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // Defer one runloop hop so AppKit finishes mounting the field before we
    // request first-responder; otherwise `currentEditor()` returns nil.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self)
      self.currentEditor()?.selectAll(nil)
    }
  }
}
