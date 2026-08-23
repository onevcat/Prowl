import AppKit
import ComposableArchitecture
import SwiftUI

internal enum HerdrTabBarLayout {
  internal static let height: CGFloat = 34
  internal static let minimumTabWidth: CGFloat = 92
  internal static let tabHorizontalPadding: CGFloat = 10
  internal static let tabSpacing: CGFloat = 3
  internal static let closeButtonSize: CGFloat = 18
}

internal struct HerdrTabBarItem: Equatable, Identifiable, Sendable {
  internal let id: String
  internal let workspaceID: String
  internal let label: String
  internal let isZoomed: Bool
  internal let isFocused: Bool

  internal var displayLabel: String {
    isZoomed ? "\(label) Z" : label
  }
}

internal enum HerdrTabBarProjection {
  internal static func items(
    in snapshot: HerdrSessionSnapshot,
    workspaceID: String?
  ) -> [HerdrTabBarItem] {
    guard let workspaceID else { return [] }
    let zoomedTabIDs = Set(
      snapshot.layouts
        .filter { $0.workspaceID == workspaceID && $0.zoomed }
        .map(\.tabID)
    )
    return snapshot.tabs.compactMap { tab in
      guard tab.workspaceID == workspaceID else { return nil }
      return HerdrTabBarItem(
        id: tab.id,
        workspaceID: tab.workspaceID,
        label: tab.label,
        isZoomed: zoomedTabIDs.contains(tab.id),
        isFocused: tab.id == snapshot.focusedTabID || tab.focused
      )
    }
  }

  internal static func insertIndex(
    sourceID: String,
    targetID: String,
    items: [HerdrTabBarItem]
  ) -> Int? {
    guard sourceID != targetID,
      let targetIndex = items.firstIndex(where: { $0.id == targetID })
    else { return nil }
    return targetIndex
  }

  internal static func cycleTarget(
    selectedID: String?,
    direction: Int,
    items: [HerdrTabBarItem]
  ) -> String? {
    guard !items.isEmpty else { return nil }
    let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
    let nextIndex = (currentIndex + direction + items.count) % items.count
    return items[nextIndex].id
  }
}

internal struct HerdrTabBarView: View {
  @Bindable internal var store: StoreOf<HerdrTerminalChromeFeature>

  @State private var editor: Editor?
  @State private var hoveredTabID: String?

  private enum Editor: Identifiable {
    case new(workspaceID: String, sourceTabID: String?)
    case rename(tabID: String, label: String)

    internal var id: String {
      switch self {
      case .new(let workspaceID, let sourceTabID): return "new-\(workspaceID)-\(sourceTabID ?? "current")"
      case .rename(let tabID, _): return "rename-\(tabID)"
      }
    }
  }

  internal var body: some View {
    let items = tabItems
    HStack(spacing: 6) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: HerdrTabBarLayout.tabSpacing) {
            ForEach(items) { item in
              tabButton(item)
                .id(item.id)
            }
          }
          .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
        .onAppear {
          scrollToSelected(proxy, selectedID: store.selectedTabID)
        }
        .onChange(of: store.selectedTabID) { _, selectedID in
          withAnimation(.easeInOut(duration: 0.16)) {
            scrollToSelected(proxy, selectedID: selectedID)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Button {
        guard let workspaceID else { return }
        editor = .new(workspaceID: workspaceID, sourceTabID: nil)
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .contentShape(.rect)
      .help("New tab")
      .accessibilityLabel("New tab")
      .disabled(workspaceID == nil || store.pendingMutation != nil)
    }
    .padding(.horizontal, 8)
    .frame(height: HerdrTabBarLayout.height)
    .glassEffect(.regular, in: Rectangle())
    .background {
      HerdrTabBarScrollInterceptor { delta in
        let direction = delta > 0 ? -1 : 1
        guard let targetID = HerdrTabBarProjection.cycleTarget(
          selectedID: store.selectedTabID,
          direction: direction,
          items: tabItems
        ) else { return }
        store.send(.focusTabTapped(targetID))
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
    .sheet(item: $editor) { editor in
      editorView(editor)
    }
    .alert(
      "Close workspace?",
      isPresented: closeConfirmationBinding
    ) {
      Button("Close", role: .destructive) {
        store.send(.closeConfirmationConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.closeConfirmationCancelled)
      }
    } message: {
      Text("Closing the last tab will close its Herdr workspace.")
    }
    .alert(
      "Herdr tab action failed",
      isPresented: mutationErrorBinding
    ) {
      Button("OK", role: .cancel) {
        store.send(.mutationErrorDismissed)
      }
    } message: {
      Text(mutationErrorMessage)
    }
  }

  private var workspaceID: String? {
    store.selectedWorkspaceID ?? store.snapshot.focusedWorkspaceID
  }

  private var tabItems: [HerdrTabBarItem] {
    HerdrTabBarProjection.items(in: store.snapshot, workspaceID: workspaceID)
  }

  private func scrollToSelected(_ proxy: ScrollViewProxy, selectedID: String?) {
    guard let selectedID else { return }
    proxy.scrollTo(selectedID, anchor: .center)
  }

  private func tabButton(_ item: HerdrTabBarItem) -> some View {
    let isActive = store.selectedTabID == item.id || (store.selectedTabID == nil && item.isFocused)
    let isHovered = hoveredTabID == item.id
    return ZStack(alignment: .trailing) {
      Button {
        store.send(.focusTabTapped(item.id))
      } label: {
        HStack(spacing: 6) {
          Text(item.displayLabel)
            .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: HerdrTabBarLayout.minimumTabWidth, alignment: .leading)
          Spacer(minLength: 4)
          Color.clear
            .frame(width: HerdrTabBarLayout.closeButtonSize)
        }
        .padding(.horizontal, HerdrTabBarLayout.tabHorizontalPadding)
        .frame(minHeight: 26)
        .background {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.2) : isHovered ? Color.primary.opacity(0.07) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(isActive ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      if isHovered {
        Button {
          store.send(
            .closeTabRequested(tabID: item.id, workspaceID: item.workspaceID)
          )
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .frame(width: HerdrTabBarLayout.closeButtonSize, height: HerdrTabBarLayout.closeButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, HerdrTabBarLayout.tabHorizontalPadding)
        .help("Close tab")
        .accessibilityLabel("Close tab \(item.displayLabel)")
        .disabled(store.pendingMutation != nil)
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isActive ? .primary : .secondary)
    .onHover { hoveredTabID = $0 ? item.id : nil }
    .help("Open tab \(item.displayLabel)")
    .accessibilityLabel(item.displayLabel)
    .contextMenu {
      Button("New tab") {
        editor = .new(workspaceID: item.workspaceID, sourceTabID: item.id)
      }
      Button("Rename") {
        editor = .rename(tabID: item.id, label: item.label)
      }
      Divider()
      Button("Close", role: .destructive) {
        store.send(.closeTabRequested(tabID: item.id, workspaceID: item.workspaceID))
      }
      .disabled(store.pendingMutation != nil)
    }
    .draggable(item.id)
    .dropDestination(for: String.self) { sourceIDs, _ in
      guard let sourceID = sourceIDs.first,
        let insertIndex = HerdrTabBarProjection.insertIndex(
          sourceID: sourceID,
          targetID: item.id,
          items: tabItems
        )
      else { return false }
      store.send(.moveTabRequested(tabID: sourceID, insertIndex: insertIndex))
      return true
    }
  }

  @ViewBuilder
  private func editorView(_ editor: Editor) -> some View {
    switch editor {
    case .new(let workspaceID, let sourceTabID):
      HerdrTabEditorView(title: "New tab", label: "", isOptional: true) { label in
        store.send(
          .newTabRequested(
            workspaceID: workspaceID,
            label: label,
            sourceTabID: sourceTabID
          )
        )
      }
    case .rename(let tabID, let label):
      HerdrTabEditorView(title: "Rename tab", label: label, isOptional: false) { label in
        guard let label else { return }
        store.send(.renameTabRequested(tabID: tabID, label: label))
      }
    }
  }

  private var closeConfirmationBinding: Binding<Bool> {
    Binding(
      get: { store.closeConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          store.send(.closeConfirmationCancelled)
        }
      }
    )
  }

  private var mutationErrorBinding: Binding<Bool> {
    Binding(
      get: { store.mutationError != nil },
      set: { isPresented in
        if !isPresented {
          store.send(.mutationErrorDismissed)
        }
      }
    )
  }

  private var mutationErrorMessage: String {
    guard let error = store.mutationError else { return "Unknown Herdr error." }
    return String(describing: error)
  }
}

private struct HerdrTabBarScrollInterceptor: NSViewRepresentable {
  let onScroll: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScroll: onScroll)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.start(for: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    private let onScroll: @MainActor (CGFloat) -> Void
    private var monitor: Any?
    private weak var view: NSView?

    init(onScroll: @escaping @MainActor (CGFloat) -> Void) {
      self.onScroll = onScroll
    }

    func start(for view: NSView) {
      guard monitor == nil else { return }
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, let view = self.view, view.window != nil else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return event }
        onScroll(event.scrollingDeltaY)
        return nil
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      view = nil
    }
  }
}

private struct HerdrTabEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool
  @State private var label: String

  let title: String
  let isOptional: Bool
  let onSubmit: (String?) -> Void

  init(
    title: String,
    label: String,
    isOptional: Bool,
    onSubmit: @escaping (String?) -> Void
  ) {
    self.title = title
    self.isOptional = isOptional
    self.onSubmit = onSubmit
    _label = State(initialValue: label)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.headline)
      TextField(isOptional ? "Tab name (optional)" : "Tab name", text: $label)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit(submit)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(!isOptional && trimmedLabel.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 340)
    .onAppear { isFocused = true }
  }

  private var trimmedLabel: String {
    label.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submit() {
    let value = trimmedLabel
    guard isOptional || !value.isEmpty else { return }
    onSubmit(value.isEmpty ? nil : value)
    dismiss()
  }
}
