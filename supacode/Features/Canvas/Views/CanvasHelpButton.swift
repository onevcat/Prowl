import SwiftUI

/// The canvas navigation help affordance shown in the bottom-leading corner.
///
/// Mirrors the toolbar notifications bell: hovering the button reveals the help
/// popover, moving away dismisses it after a short grace period (so the cursor
/// can travel onto the popover), and clicking pins it open until clicked again.
struct CanvasHelpButton: View {
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @State private var isPresented = false
  @State private var isPinnedOpen = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var closeTask: Task<Void, Never>?

  var body: some View {
    Button {
      togglePresentation()
    } label: {
      Image(systemName: "questionmark.circle")
        .interfaceFont(.body)
        .accessibilityLabel("Canvas navigation help")
    }
    .buttonStyle(.bordered)
    .help("Canvas navigation help. Hover or click to show.")
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      canvasHelpContent
        .onHover { hovering in
          isHoveringPopover = hovering
          updatePresentation()
        }
        .onDisappear {
          isHoveringPopover = false
          isPinnedOpen = false
        }
    }
    .onDisappear {
      closeTask?.cancel()
    }
    .padding()
  }

  private var canvasHelpContent: some View {
    let expandShortcut = AppShortcuts.display(
      for: AppShortcuts.CommandID.expandCanvasCard,
      in: resolvedKeybindings
    )
    let navUpDown = [
      AppShortcuts.display(for: AppShortcuts.CommandID.selectPreviousWorktree, in: resolvedKeybindings),
      AppShortcuts.display(for: AppShortcuts.CommandID.selectNextWorktree, in: resolvedKeybindings),
    ].compactMap { $0 }
    let navLeftRight = [
      AppShortcuts.display(for: AppShortcuts.CommandID.selectPreviousShelfBook, in: resolvedKeybindings),
      AppShortcuts.display(for: AppShortcuts.CommandID.selectNextShelfBook, in: resolvedKeybindings),
    ].compactMap { $0 }
    let navKeys = (navUpDown + navLeftRight).joined(separator: " / ")

    return VStack(alignment: .leading, spacing: 14) {
      Text("Canvas Navigation")
        .interfaceFont(.headline)

      VStack(alignment: .leading, spacing: 12) {
        canvasHelpRow(
          icon: "plus.magnifyingglass",
          title: "Zoom in/out",
          detail: "⌘ + scroll, or pinch gesture"
        )
        canvasHelpRow(
          icon: "hand.draw",
          title: "Pan canvas",
          detail: "Drag empty area, middle-click drag, or two-finger swipe"
        )
        canvasHelpRow(
          icon: "arrow.up.left.and.arrow.down.right",
          title: "Expand / restore card",
          detail: expandShortcut.map { "\($0), or the card's title-bar button" }
            ?? "Use the card's title-bar button"
        )
        if !navKeys.isEmpty {
          canvasHelpRow(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            title: "Navigate between cards",
            detail: "\(navKeys) — jump to the nearest card in that direction"
          )
        }
      }
    }
    .padding()
    .frame(width: 320, alignment: .leading)
  }

  private func canvasHelpRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).interfaceFont(.callout).fontWeight(.medium)
        Text(detail)
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func togglePresentation() {
    if isPinnedOpen {
      closePopover()
      return
    }
    closeTask?.cancel()
    isPinnedOpen = true
    isPresented = true
  }

  private func updatePresentation() {
    if isPinnedOpen || isHoveringButton || isHoveringPopover {
      closeTask?.cancel()
      isPresented = true
      return
    }
    closeTask?.cancel()
    closeTask = Task { @MainActor in
      try? await ContinuousClock().sleep(for: .milliseconds(150))
      if !Task.isCancelled {
        isPresented = false
      }
    }
  }

  private func closePopover() {
    closeTask?.cancel()
    isPinnedOpen = false
    isPresented = false
  }
}
