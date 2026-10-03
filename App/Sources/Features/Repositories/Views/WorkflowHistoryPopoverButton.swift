import ComposableArchitecture
import SwiftUI

struct WorkflowHistoryPopoverButton: View {
  @Bindable var store: StoreOf<WorkflowStepHistoryFeature>
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  let onIntent: (WorkflowRunPanelIntent) -> Void

  var body: some View {
    Button {
      popovers.toggle(.history)
    } label: {
      Image(systemName: "checklist")
        .foregroundStyle(.secondary)
    }
    .help("Workflow History. Hover to preview or click to keep open.")
    .accessibilityLabel("Workflow History")
    .onHover { popovers.hoverButton(.history, hovering: $0) }
    .popover(
      isPresented: Binding(
        get: { popovers.presented == .history },
        set: { if !$0 { popovers.dismiss(.history) } }
      )
    ) {
      WorkflowStepHistoryView(store: store, onIntent: onIntent, onInteraction: { popovers.pin(.history) })
        .onHover { popovers.hoverPopover(.history, hovering: $0) }
    }
    .onChange(of: popovers.presented == .history) { _, visible in
      store.send(.setPresented(visible))
    }
    .onChange(of: store.openRequest) { _, _ in popovers.showPinned(.history) }
    .onDisappear { popovers.dismiss(.history) }
  }
}
