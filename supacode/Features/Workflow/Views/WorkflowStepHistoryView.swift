import ComposableArchitecture
import SwiftUI

struct WorkflowStepHistoryView: View {
  @Bindable var store: StoreOf<WorkflowStepHistoryFeature>
  let onIntent: (WorkflowRunPanelIntent) -> Void
  var onInteraction: () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Workflow History").font(.headline)
        Spacer()
        if store.isLoading { ProgressView().controlSize(.small) }
        Picker("History Scope", selection: $store.selectedScope.sending(\.setScope)) {
          ForEach(WorkflowHistoryScope.allCases, id: \.self) { scope in
            Text(scope.rawValue).tag(scope)
          }
        }
        .labelsHidden()
        .fixedSize()
        .help("Show runs started here or involving this pane, this worktree, or all runs")
      }
      .padding(12)
      Divider()
      HStack(spacing: 0) {
        runList.frame(width: 200)
        Divider()
        if let detail = store.detail {
          WorkflowStepHistoryDetailView(
            record: detail, directory: store.selectedDirectory, livePaneIDs: store.context.livePaneIDs,
            liveRun: store.selectedLiveRun,
            onIntent: {
              onInteraction()
              onIntent($0)
            },
            onOutput: {
              onInteraction()
              store.send(.output($0))
            }, onInteraction: onInteraction
          )
          .id(detail.run.id)
        } else {
          ContentUnavailableView(
            "No Run Selected", systemImage: "checklist",
            description: Text("Select a run to inspect its steps and outputs.")
          )
          .frame(maxWidth: .infinity)
        }
      }
      if let error = store.error {
        Divider()
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
          .lineLimit(3).padding(10)
      }
    }
    .frame(
      width: min(780, (NSScreen.main?.visibleFrame.width ?? 860) - 80),
      height: min(580, (NSScreen.main?.visibleFrame.height ?? 660) - 80)
    )
    .onChange(of: store.selectedScope) { _, _ in onInteraction() }
    .task { store.send(.refresh) }
  }

  private var runList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(store.visibleEntries) { entry in
          Button {
            onInteraction()
            store.send(.select(entry.id))
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              WorkflowHistoryStatusIcon(state: entry.state)
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(2)
                if store.selectedScope == .all {
                  Text(URL(filePath: entry.root).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let relationship = entry.relationship(paneID: store.context.paneID, session: store.context.session) {
                  Text(relationship).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              Spacer(minLength: 0)
            }
            .font(.body)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              store.selectedID == entry.id ? AnyShapeStyle(.selection) : AnyShapeStyle(Color.clear),
              in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("Show steps for \(entry.name)")
        }
        if store.hasMore {
          Button("Load More") {
            onInteraction()
            store.send(.loadMore)
          }.help("Show more workflow runs")
            .padding(8)
        }
        if store.visibleEntries.isEmpty {
          Text("No runs in this scope. Try This Worktree or All Runs.")
            .font(.callout).foregroundStyle(.secondary).padding(8)
        }
      }
      .padding(6)
    }
  }
}
