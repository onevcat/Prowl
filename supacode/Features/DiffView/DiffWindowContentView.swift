import ComposableArchitecture
import SwiftUI
import YiTong

struct DiffWindowContentView: View {
  var state: DiffWindowState
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
  @AppStorage("diffViewStyle") private var diffStyleRaw = DiffStyle.split.rawValue
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Shared(.settingsFile) private var settingsFile
  @Environment(\.colorScheme) private var colorScheme

  private var diffStyle: DiffStyle {
    DiffStyle(rawValue: diffStyleRaw) ?? .split
  }

  private var emptyState: (title: String, description: String) {
    switch state.mode {
    case .uncommitted:
      ("No Changes", "Working directory is clean")
    case .outgoing:
      ("No Outgoing Changes", outgoingEmptyDescription)
    }
  }

  private var outgoingEmptyDescription: String {
    guard let base = state.outgoingBase else {
      return "This branch has no committed changes relative to its base"
    }
    return "This branch has no committed changes relative to \(base.displayName) (\(base.source.label))"
  }

  private var modeSelection: Binding<DiffMode> {
    Binding(
      get: { state.mode },
      set: { state.setMode($0) },
    )
  }

  private var resolvedDiffAppearance: DiffAppearance {
    switch settingsFile.global.appearanceMode {
    case .system: colorScheme == .dark ? .dark : .light
    case .light: .light
    case .dark: .dark
    }
  }

  private var selectedFileID: Binding<String?> {
    Binding(
      get: { state.selectedFile?.id },
      set: { id in
        if let id, let file = state.changedFiles.first(where: { $0.id == id }) {
          state.selectFile(file)
        }
      },
    )
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      fileListSidebar
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
    } detail: {
      diffDetail
    }
    .focusedSceneAction(\.toggleLeftSidebarAction, enabled: true) {
      toggleSidebar()
    }
    .toolbar(id: "diffToolbar") {
      ToolbarItem(id: "sidebarToggle", placement: .navigation) {
        Button {
          toggleSidebar()
        } label: {
          Image(systemName: "sidebar.left")
            .accessibilityLabel("Toggle Sidebar")
        }
        .help(
          AppShortcuts.helpText(
            title: "Toggle Sidebar",
            commandID: AppShortcuts.CommandID.toggleLeftSidebar,
            in: resolvedKeybindings
          ))
      }
      ToolbarItem(id: "diffMode", placement: .principal) {
        Picker("Diff Mode", selection: modeSelection) {
          Text("Uncommitted")
            .tag(DiffMode.uncommitted)
            .help(
              AppShortcuts.helpText(
                title: "Show uncommitted changes",
                commandID: AppShortcuts.CommandID.showDiff,
                in: resolvedKeybindings
              ))
          Text("Outgoing")
            .tag(DiffMode.outgoing)
            .help(
              AppShortcuts.helpText(
                title: "Show outgoing changes",
                commandID: AppShortcuts.CommandID.outgoingChanges,
                in: resolvedKeybindings
              ))
        }
        .pickerStyle(.segmented)
        .disabled(!state.canSwitchModes)
        .help("Switch between uncommitted and outgoing changes")
      }
      ToolbarItem(id: "diffStyle", placement: .primaryAction) {
        Picker("Diff Style", selection: $diffStyleRaw) {
          Image(systemName: "square.split.2x1")
            .accessibilityLabel("Split")
            .tag(DiffStyle.split.rawValue)
            .help("Split")
          Image(systemName: "text.justify.left")
            .accessibilityLabel("Unified")
            .tag(DiffStyle.unified.rawValue)
            .help("Unified")
        }
        .pickerStyle(.segmented)
        .help("Diff Style")
      }
    }
    .background {
      WindowAppearanceSetter(colorScheme: settingsFile.global.appearanceMode.colorScheme)
    }
  }

  private func toggleSidebar() {
    withAnimation {
      columnVisibility = columnVisibility == .detailOnly ? .automatic : .detailOnly
    }
  }

  // MARK: - File List

  private var fileListSidebar: some View {
    List(selection: selectedFileID) {
      if let base = state.outgoingBase {
        Section {
          fileRows
        } header: {
          Text("vs \(base.displayName) · \(base.source.label)")
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Comparing committed changes against \(base.displayName) (\(base.source.label))")
        }
      } else {
        fileRows
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if state.isLoadingFiles && state.changedFiles.isEmpty {
        ProgressView()
      } else if let loadError = state.loadError {
        ContentUnavailableView(
          "Unable to Load Changes",
          systemImage: "exclamationmark.triangle",
          description: Text(loadError),
        )
      } else if !state.isLoadingFiles && state.changedFiles.isEmpty {
        ContentUnavailableView(
          emptyState.title,
          systemImage: "checkmark.circle",
          description: Text(emptyState.description),
        )
      }
    }
  }

  private var fileRows: some View {
    ForEach(state.changedFiles) { file in
      FileRowView(file: file)
        .tag(file.id)
    }
  }

  // MARK: - Diff Detail

  private var diffDetail: some View {
    Group {
      if let document = state.diffDocument {
        DiffView(
          document: document,
          configuration: DiffConfiguration(
            appearance: resolvedDiffAppearance,
            style: diffStyle,
            showsFileHeaders: false,
          ),
          onEvent: { event in
            switch event {
            case .didRender:
              state.markDiffRendered()
            case .didFail(let error):
              state.markDiffFailed(error)
            default:
              break
            }
          }
        )
        // YiTong skips re-rendering a value-equal document, so retrying after a
        // render failure works by recreating the view with a new identity.
        .id(state.renderGeneration)
        .overlay {
          switch state.renderState {
          case .rendering:
            ProgressView()
              .controlSize(.small)
              .padding(12)
              .background(.regularMaterial, in: Circle())
              .transition(.opacity)
          case .failed(let renderError):
            VStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
              Text(renderError.message)
                .interfaceFont(.caption)
                .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
          case .idle:
            EmptyView()
          }
        }
        .animation(.easeInOut(duration: 0.15), value: state.renderState)
      } else if let loadError = state.loadError {
        ContentUnavailableView(
          "Unable to Load Changes",
          systemImage: "exclamationmark.triangle",
          description: Text(loadError),
        )
      } else if state.isLoadingFiles {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "Select a File",
          systemImage: "doc.text",
          description: Text("Choose a file from the sidebar to view changes"),
        )
      }
    }
  }
}

// MARK: - Status Color

extension DiffFileStatus {
  var color: Color {
    switch self {
    case .modified: .orange
    case .added: .green
    case .deleted: .red
    case .renamed: .blue
    case .copied: .blue
    case .unknown: .secondary
    }
  }
}

// MARK: - File Row

private struct FileRowView: View {
  let file: DiffChangedFile

  var body: some View {
    HStack(spacing: 6) {
      Text(file.statusSymbol)
        .interfaceFont(.caption)
        .monospaced()
        .foregroundStyle(file.status.color)
        .frame(width: 14, alignment: .center)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.displayName)
          .interfaceFont(.body)
          .lineLimit(1)
        if !file.directoryPath.isEmpty {
          Text(file.directoryPath)
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
    }
  }
}
