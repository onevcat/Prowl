import AppKit
import SwiftUI

extension View {
  func persistentPopover<Content: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(PersistentPopoverModifier(isPresented: isPresented, popoverContent: content))
  }
}

private struct PersistentPopoverModifier<PopoverContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  @ViewBuilder var popoverContent: () -> PopoverContent

  func body(content: Content) -> some View {
    content
      .background {
        PersistentPopoverAnchor(
          isPresented: $isPresented,
          popoverContent: popoverContent
        )
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
      }
  }
}

private struct PersistentPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
  @Binding var isPresented: Bool
  @ViewBuilder var popoverContent: () -> PopoverContent

  func makeNSView(context: Context) -> NSView {
    NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if isPresented {
      if context.coordinator.popover == nil {
        context.coordinator.show(anchorHint: nsView, content: popoverContent())
      } else {
        context.coordinator.updateContent(popoverContent())
      }
    } else {
      context.coordinator.close()
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(isPresented: $isPresented)
  }

  final class Coordinator: NSObject, NSPopoverDelegate {
    private(set) var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?
    private let isPresented: Binding<Bool>

    init(isPresented: Binding<Bool>) {
      self.isPresented = isPresented
    }

    @MainActor
    func show(anchorHint: NSView, content: some View) {
      let hosting = NSHostingController(rootView: AnyView(content))
      let popover = NSPopover()
      popover.behavior = .semitransient
      popover.contentViewController = hosting
      popover.delegate = self

      let anchor: NSView
      let rect: NSRect

      if anchorHint.window != nil {
        anchor = anchorHint
        rect = anchorHint.bounds
      } else if let window = NSApp.keyWindow, let contentView = window.contentView {
        anchor = contentView
        rect = NSRect(x: 10, y: contentView.bounds.height - 10, width: 1, height: 1)
      } else {
        return
      }

      popover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
      self.popover = popover
      self.hostingController = hosting
    }

    @MainActor
    func updateContent(_ content: some View) {
      hostingController?.rootView = AnyView(content)
    }

    @MainActor
    func close() {
      let ref = popover
      popover = nil
      hostingController = nil
      ref?.close()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
      Task { @MainActor in
        self.popover = nil
        self.hostingController = nil
        if self.isPresented.wrappedValue {
          self.isPresented.wrappedValue = false
        }
      }
    }
  }
}
