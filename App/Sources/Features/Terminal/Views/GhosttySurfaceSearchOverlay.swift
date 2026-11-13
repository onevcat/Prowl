import AppKit
import SwiftUI

struct GhosttySurfaceSearchOverlay: View {
  let surfaceView: GhosttySurfaceView
  @Bindable var state: GhosttySurfaceState
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  @State private var corner: GhosttySearchCorner = .topRight
  @State private var dragOffset: CGSize = .zero
  @State private var barSize: CGSize = .zero
  @State private var searchTask: Task<Void, Never>?

  private let overlayPadding: CGFloat = 8

  init(surfaceView: GhosttySurfaceView) {
    self.surfaceView = surfaceView
    self._state = Bindable(surfaceView.bridge.state)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: corner.alignment) {
        HStack(spacing: 4) {
          GhosttySearchField(
            text: $state.searchInput,
            focusPending: $state.searchFocusPending,
            focusOwner: state,
            focusRequests: surfaceView.runtime.focusRequests,
            onSubmit: { isShifted in
              navigateSearch(isShifted ? .previous : .next)
            },
            onEscape: {
              closeSearch()
              surfaceView.requestFocus()
            },
            onFocusedRemoval: { window in
              guard state.searchNeedle != nil else { return }
              let requests = surfaceView.runtime.focusRequests
              let currentRequest = requests.searchRequest(for: state)
              if !state.searchFocusPending || currentRequest?.context?.matches(in: window) != true {
                requests.beginSearch(for: state, in: window)
              }
              state.searchFocusPending = true
            },
            onFocused: { surfaceView.onFocusChange?(true) }
          )
          .frame(width: 180)
          .padding(.leading, 8)
          .padding(.trailing, 50)
          .padding(.vertical, 6)
          .background(Color.primary.opacity(0.1))
          .clipShape(.capsule)
          .overlay(alignment: .trailing) {
            matchLabel
          }

          Button {
            navigateSearch(.previous)
          } label: {
            SearchButtonLabel(
              title: String(localized: "Previous"),
              shortcut: resolvedKeybindings.display(for: AppShortcuts.CommandID.findPrevious),
              systemImage: "chevron.up"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())
          .help(
            searchButtonHelp(
              String(localized: "Find Previous"), commandID: AppShortcuts.CommandID.findPrevious))

          Button {
            navigateSearch(.next)
          } label: {
            SearchButtonLabel(
              title: String(localized: "Next"),
              shortcut: resolvedKeybindings.display(for: AppShortcuts.CommandID.findNext),
              systemImage: "chevron.down"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())
          .help(
            searchButtonHelp(
              String(localized: "Find Next"), commandID: AppShortcuts.CommandID.findNext))

          Button {
            closeSearch()
            surfaceView.requestFocus()
          } label: {
            SearchButtonLabel(
              title: String(localized: "Close"),
              shortcut: nil,
              systemImage: "xmark"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())
          .help("Close Find Bar (Esc)")
        }
        .padding(8)
        .background(.background)
        .clipShape(.capsule)
        .shadow(radius: 4)
        .background(
          GeometryReader { barGeo in
            Color.clear.onAppear {
              barSize = barGeo.size
            }
          }
        )
        .padding(overlayPadding)
        .offset(dragOffset)
        .contentShape(.rect)
        .gesture(
          DragGesture()
            .onChanged { value in
              dragOffset = value.translation
            }
            .onEnded { value in
              let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
              let newCenter = CGPoint(
                x: centerPos.x + value.translation.width,
                y: centerPos.y + value.translation.height
              )
              let newCorner = closestCorner(to: newCenter, in: geo.size)
              withAnimation(.easeOut(duration: 0.2)) {
                corner = newCorner
                dragOffset = .zero
              }
            }
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
      .onAppear {
        scheduleSearch(state.searchInput)
      }
      .onChange(of: state.searchInput) { _, newValue in
        scheduleSearch(newValue)
      }
      .onChange(of: state.searchTotal) { _, newValue in
        if let total = newValue, total > 0, state.searchSelected == nil {
          surfaceView.performBindingAction("navigate_search:next")
        }
      }
      .onDisappear {
        searchTask?.cancel()
        searchTask = nil
      }
    }
  }

  @ViewBuilder
  private var matchLabel: some View {
    if let selected = state.searchSelected, let total = state.searchTotal {
      Text("\(total - selected)/\(total)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
    } else if let total = state.searchTotal {
      Text("-/\(total)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
    }
  }

  private func scheduleSearch(_ needle: String) {
    searchTask?.cancel()
    if needle.isEmpty || needle.count >= 3 {
      emitSearch(needle)
      return
    }

    let text = needle
    searchTask = Task { @MainActor in
      do {
        try await ContinuousClock().sleep(for: .milliseconds(300))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      emitSearch(text)
    }
  }

  private func emitSearch(_ needle: String) {
    surfaceView.performBindingAction("search:\(needle)")
  }

  private func navigateSearch(_ direction: GhosttySearchDirection) {
    flushPendingSearch()
    surfaceView.navigateSearch(direction)
  }

  private func closeSearch() {
    surfaceView.performBindingAction("end_search")
  }

  private func flushPendingSearch() {
    guard let searchTask else { return }
    searchTask.cancel()
    self.searchTask = nil
    emitSearch(state.searchInput)
  }

  private func searchButtonHelp(_ title: String, commandID: String) -> String {
    if let shortcut = resolvedKeybindings.display(for: commandID) {
      return "\(title) (\(shortcut))"
    }
    return title
  }

  private func centerPosition(
    for corner: GhosttySearchCorner,
    in containerSize: CGSize,
    barSize: CGSize
  ) -> CGPoint {
    let halfWidth = barSize.width / 2 + overlayPadding
    let halfHeight = barSize.height / 2 + overlayPadding

    switch corner {
    case .topLeft:
      return CGPoint(x: halfWidth, y: halfHeight)
    case .topRight:
      return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
    case .bottomLeft:
      return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
    case .bottomRight:
      return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
    }
  }

  private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> GhosttySearchCorner {
    let midX = containerSize.width / 2
    let midY = containerSize.height / 2

    if point.x < midX {
      return point.y < midY ? .topLeft : .bottomLeft
    }
    return point.y < midY ? .topRight : .bottomRight
  }
}

private enum GhosttySearchCorner {
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight

  var alignment: Alignment {
    switch self {
    case .topLeft: return .topLeading
    case .topRight: return .topTrailing
    case .bottomLeft: return .bottomLeading
    case .bottomRight: return .bottomTrailing
    }
  }
}

private nonisolated struct GhosttySearchOverlayShape: Shape {
  func path(in rect: CGRect) -> Path {
    ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true).path(in: rect)
  }
}

private struct SearchButtonLabel: View {
  let title: String
  let shortcut: String?
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .accessibilityHidden(true)
  }
}

struct GhosttySearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var focusPending: Bool
  let focusOwner: GhosttySurfaceState
  let focusRequests: GhosttySurfaceView.FocusRequests
  var onSubmit: (Bool) -> Void
  var onEscape: () -> Void
  var onFocusedRemoval: (NSWindow) -> Void = { _ in }
  var onFocused: () -> Void = {}

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> SearchField {
    let field = SearchField()
    field.delegate = context.coordinator
    field.focusRequests = focusRequests
    field.focusOwner = focusOwner
    field.updateFocusPending($focusPending)
    field.onSubmit = onSubmit
    field.onEscape = onEscape
    field.onFocusedRemoval = onFocusedRemoval
    field.onFocused = onFocused
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = String(localized: "Search")
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return field
  }

  func updateNSView(_ nsView: SearchField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.onSubmit = onSubmit
    nsView.onEscape = onEscape
    nsView.onFocusedRemoval = onFocusedRemoval
    nsView.onFocused = onFocused
    nsView.focusRequests = focusRequests
    nsView.focusOwner = focusOwner

    nsView.updateFocusPending($focusPending)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding var text: String

    init(text: Binding<String>) {
      _text = text
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      text = field.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard let field = control as? SearchField else { return false }
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        let isShifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        field.onSubmit?(isShifted)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        field.onEscape?()
        return true
      default:
        return false
      }
    }
  }

  static func dismantleNSView(_ nsView: SearchField, coordinator: Coordinator) {
    nsView.stopRequestingFocus()
  }

  final class SearchField: NSTextField {
    var onSubmit: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusedRemoval: ((NSWindow) -> Void)?
    var onFocused: (() -> Void)?
    var focusRequests: GhosttySurfaceView.FocusRequests?
    var focusOwner: GhosttySurfaceState?

    private var focusPending: Binding<Bool>?
    private weak var observedWindow: NSWindow?
    private var focusContext: GhosttySurfaceView.FocusContext?
    private var pendingFocusRequest: GhosttySurfaceView.SearchFocusRequest?
    private var focusOwnership: GhosttySurfaceView.SearchFocusRequest?
    private var isFocusRequestScheduled = false
    private var isFocusTransferScheduled = false
    private var isActive = true

    func updateFocusPending(_ binding: Binding<Bool>) {
      focusPending = binding
      requestFocus()
    }

    func stopRequestingFocus() {
      transferFocusBeforeRemoval()
      isActive = false
      removeWindowUpdateObserver()
    }

    func requestFocus() {
      guard isActive, focusPending?.wrappedValue == true else {
        pendingFocusRequest = nil
        focusContext = nil
        removeWindowUpdateObserver()
        return
      }
      guard let window else {
        removeWindowUpdateObserver()
        return
      }
      _ = updateRequestContext(in: window)
      updateWindowUpdateObserver()
      guard !isFocusRequestScheduled else { return }
      isFocusRequestScheduled = true
      Task { @MainActor [weak self, weak window] in
        guard let self else { return }
        var retryAfterWindowChange = false
        defer {
          self.isFocusRequestScheduled = false
          if retryAfterWindowChange {
            self.requestFocus()
          }
        }
        guard self.isActive, let window, self.window === window,
          let focusPending = self.focusPending, focusPending.wrappedValue
        else {
          retryAfterWindowChange = self.isActive && self.window != nil && self.window !== window
          self.updateWindowUpdateObserver()
          return
        }
        guard self.updateRequestContext(in: window),
          self.isFocused(in: window) || self.focusContext?.matchesOrAllowsDetachedSource(in: window) == true
        else {
          self.finishFocusRequest(focusPending)
          return
        }
        _ = window.makeFirstResponder(self)
        if self.isFocused(in: window) {
          self.recordFocusOwnership()
          self.finishFocusRequest(focusPending)
        } else if window.firstResponder === window,
          let request = self.pendingFocusRequest,
          self.focusRequests?.searchRequest(for: request.owner)?.matches(request) == true
        {
          self.focusContext = GhosttySurfaceView.FocusContext(window: window)
          self.focusRequests?.refreshSearchContext(for: request, in: window)
        }
      }
    }

    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result {
        recordFocusOwnership()
        onFocused?()
      }
      return result
    }

    private func recordFocusOwnership() {
      guard let window, isFocused(in: window), let focusOwner, let focusRequests else { return }
      if focusPending?.wrappedValue != true || focusRequests.searchRequest(for: focusOwner) == nil {
        focusRequests.beginSearch(for: focusOwner, in: window)
      }
      focusOwnership = focusRequests.searchRequest(for: focusOwner)
      focusRequests.recordFocusedSearchField(self, for: focusOwner)
    }

    private func updateRequestContext(in window: NSWindow) -> Bool {
      guard let focusOwner, let focusRequests,
        let request = focusRequests.searchRequest(for: focusOwner), let context = request.context,
        context.window === window
      else { return false }
      if focusContext?.window !== window || pendingFocusRequest?.matches(request) != true {
        focusContext = context
        pendingFocusRequest = request
      }
      return true
    }

    private func finishFocusRequest(_ binding: Binding<Bool>) {
      pendingFocusRequest = nil
      focusContext = nil
      removeWindowUpdateObserver()
      binding.wrappedValue = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil {
        transferFocusBeforeRemoval()
      }
      super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        isFocusTransferScheduled = false
      }
      requestFocus()
    }

    private func transferFocusBeforeRemoval() {
      guard isActive, !isFocusTransferScheduled, let window, isFocused(in: window),
        let focusRequests, let focusOwner, let ownership = focusOwnership,
        let request = focusRequests.searchRequest(for: focusOwner),
        request.matches(ownership) || request.context?.matches(in: window) == true,
        let onFocusedRemoval
      else { return }
      isFocusTransferScheduled = true
      Task { @MainActor [self, weak window] in
        guard let window, self.window == nil || self.window === window,
          self.focusRequests === focusRequests, self.focusOwner === focusOwner,
          focusRequests.searchRequest(for: focusOwner)?.matches(request) == true
            || focusRequests.isSearchFieldFocused(for: focusOwner, in: window),
          isFocused(in: window)
            || window.firstResponder === window
            || window.firstResponder === window.contentView
            || focusRequests.isSearchFieldFocused(for: focusOwner, in: window)
        else { return }
        onFocusedRemoval(window)
      }
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
      guard let window, notification.object as? NSWindow === window else { return }
      guard focusPending?.wrappedValue == true else {
        removeWindowUpdateObserver()
        return
      }
      requestFocus()
    }

    private func updateWindowUpdateObserver() {
      guard isActive, focusPending?.wrappedValue == true, let window else {
        removeWindowUpdateObserver()
        return
      }
      guard observedWindow !== window else { return }
      removeWindowUpdateObserver()
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowDidUpdate(_:)), name: NSWindow.didUpdateNotification,
        object: window
      )
      observedWindow = window
    }

    private func removeWindowUpdateObserver() {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didUpdateNotification, object: nil)
      observedWindow = nil
    }

    private func isFocused(in window: NSWindow) -> Bool {
      guard self.window === window, let editor = currentEditor() else { return false }
      return window.firstResponder === editor
    }

    override func cancelOperation(_ sender: Any?) {
      onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard currentEditor() != nil,
        event.type == .keyDown,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command]
          || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
        event.charactersIgnoringModifiers?.lowercased() == "g"
      else {
        return super.performKeyEquivalent(with: event)
      }
      let isShifted = event.modifierFlags.contains(.shift)
      onSubmit?(isShifted)
      return true
    }

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 36, 76:
        onSubmit?(event.modifierFlags.contains(.shift))
      case 53:
        onEscape?()
      default:
        super.keyDown(with: event)
      }
    }
  }
}

private struct GhosttySearchButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
      .padding(.horizontal, 6)
      .frame(height: 26)
      .background(
        Capsule()
          .fill(backgroundColor(isPressed: configuration.isPressed))
      )
      .onHover { hovering in
        if hovering != isHovered {
          isHovered = hovering
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      }
      .onDisappear {
        if isHovered {
          isHovered = false
          NSCursor.pop()
        }
      }
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      return Color.primary.opacity(0.2)
    }
    if isHovered {
      return Color.primary.opacity(0.1)
    }
    return Color.clear
  }
}
