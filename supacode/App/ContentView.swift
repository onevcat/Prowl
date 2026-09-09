//
//  ContentView.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Dependency(FeatureFlags.self) private var featureFlags
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    repositoriesStore = store.scope(state: \.repositories, action: \.repositories)
    self.terminalManager = terminalManager
  }

  var body: some View {
    let isRunScriptPromptPresented = Binding(
      get: { store.isRunScriptPromptPresented },
      set: { store.send(.runScriptPromptPresented($0)) }
    )
    let runScriptDraft = Binding(
      get: { store.runScriptDraft },
      set: { store.send(.runScriptDraftChanged($0)) }
    )
    let deleteWorktreeConfirmationPresented = Binding(
      get: { repositoriesStore.deleteWorktreeConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          repositoriesStore.send(.worktreeLifecycle(.deleteWorktreePromptDismissed))
        }
      }
    )
    let removeWorkspaceConfirmationPresented = Binding(
      get: { repositoriesStore.removeWorkspaceConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          repositoriesStore.send(.repositoryManagement(.removeWorkspacePromptDismissed))
        }
      }
    )
    Group {
      if store.repositories.isInitialLoadComplete {
        mainSplitView
      } else {
        AppLoadingView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
      }
    }
    .environment(\.surfaceBackgroundOpacity, terminalManager.surfaceBackgroundOpacity())
    .onChange(of: mirrors.selectedID) { _, selectedID in
      if selectedID != nil { repositoriesStore.send(.selectWorktree(nil)) }
    }
    .task {
      store.send(.scenePhaseChanged(scenePhase))
    }
    .onChange(of: scenePhase) { _, newValue in
      store.send(.scenePhaseChanged(newValue))
    }
    .fileImporter(
      isPresented: $repositoriesStore.isOpenPanelPresented.sending(\.setOpenPanelPresented),
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        store.send(.repositories(.repositoryManagement(.openRepositories(urls))))
      case .failure:
        store.send(
          .repositories(
            .presentAlert(
              title: "Unable to open folders",
              message: "Prowl could not read the selected folders."
            )
          )
        )
      }
    }
    .alert($repositoriesStore.scope(state: \.alert, action: \.alert))
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(item: $repositoriesStore.scope(state: \.worktreeCreationPrompt, action: \.worktreeCreationPrompt)) {
      promptStore in
      WorktreeCreationPromptView(store: promptStore)
    }
    .sheet(item: $repositoriesStore.scope(state: \.workspaceCreationPrompt, action: \.workspaceCreationPrompt)) {
      promptStore in
      WorkspaceCreationPromptView(store: promptStore)
    }
    .sheet(item: renameBranchPromptRequest) { request in
      RenameBranchPromptView(
        currentName: request.currentName,
        onCancel: {
          repositoriesStore.send(.consumePendingRenameBranchRequest(request.id))
        },
        onSubmit: { newName in
          repositoriesStore.send(.requestRenameBranch(request.worktreeID, newName))
          repositoriesStore.send(.consumePendingRenameBranchRequest(request.id))
        }
      )
      .id(request.id)
    }
    .sheet(isPresented: deleteWorktreeConfirmationPresented) {
      if let confirmation = repositoriesStore.deleteWorktreeConfirmation {
        DeleteWorktreeConfirmationView(
          confirmation: confirmation,
          onDeleteBranchChanged: {
            repositoriesStore.send(.worktreeLifecycle(.deleteWorktreePromptDeleteBranchChanged($0)))
          },
          onCancel: {
            repositoriesStore.send(.worktreeLifecycle(.deleteWorktreePromptDismissed))
          },
          onDelete: {
            repositoriesStore.send(.worktreeLifecycle(.deleteWorktreePromptConfirmed))
          }
        )
      }
    }
    .sheet(isPresented: removeWorkspaceConfirmationPresented) {
      if let confirmation = repositoriesStore.removeWorkspaceConfirmation {
        RemoveWorkspaceConfirmationView(
          confirmation: confirmation,
          onDeleteFilesChanged: {
            repositoriesStore.send(.repositoryManagement(.removeWorkspaceDeleteFilesChanged($0)))
          },
          onDeleteBranchChanged: {
            repositoriesStore.send(.repositoryManagement(.removeWorkspaceDeleteBranchChanged($0, $1)))
          },
          onCancel: {
            repositoriesStore.send(.repositoryManagement(.removeWorkspacePromptDismissed))
          },
          onRemove: {
            repositoriesStore.send(.repositoryManagement(.removeWorkspacePromptConfirmed))
          }
        )
      }
    }
    .sheet(isPresented: isRunScriptPromptPresented) {
      RunScriptPromptView(
        script: runScriptDraft,
        onCancel: {
          store.send(.runScriptPromptPresented(false))
        },
        onSaveAndRun: {
          store.send(.saveRunScriptAndRun)
        }
      )
    }
    .focusedSceneAction(\.toggleLeftSidebarAction, enabled: true) {
      toggleLeftSidebar()
    }
    .focusedSceneValue(\.renameBranchAction, renameBranchAction)
    .focusedSceneValue(\.revealInSidebarAction, revealInSidebarAction.asFocusedAction())
    .overlay {
      CommandPaletteOverlayView(
        store: store.scope(state: \.commandPalette, action: \.commandPalette),
        items: CommandPaletteFeature.commandPaletteItems(
          from: store.repositories,
          customCommands: store.selectedCustomCommands,
          runScriptStatusByWorktreeID: store.runScriptStatusByWorktreeID,
          actionTargetWorktreeID: store.repositories.isShowingCanvas
            ? terminalManager.canvasFocusedWorktreeID
            : nil,
          ghosttyCommands: ghosttyShortcuts.commandPaletteEntries,
          workflowItems: featureFlags.workflowUI ? store.workflowPaletteItems : []
        ),
        resolvedKeybindings: store.resolvedKeybindings
      )
    }
    .overlay {
      if let handoffHudStore = store.scope(state: \.handoffHud, action: \.handoffHud.presented) {
        HandoffHudOverlayView(store: handoffHudStore)
      }
    }
    .overlay {
      if featureFlags.workflowUI, !store.workflowStartFromSettings,
        let workflowStartStore = store.scope(state: \.workflowStart, action: \.workflowStart.presented)
      {
        WorkflowStartOverlayView(store: workflowStartStore)
      }
    }
    .background(WindowTabbingDisabler())
  }

  private var renameBranchPromptRequest: Binding<PendingRenameBranchRequest?> {
    Binding(
      get: { repositoriesStore.pendingRenameBranchRequest },
      set: { newRequest in
        guard newRequest == nil, let request = repositoriesStore.pendingRenameBranchRequest else { return }
        repositoriesStore.send(.consumePendingRenameBranchRequest(request.id))
      }
    )
  }

  private var renameBranchAction: FocusedAction<Void>? {
    guard
      let worktreeID = renameBranchCommandTargetID(
        appState: store.state,
        canvasFocusedWorktreeID: terminalManager.canvasFocusedWorktreeID
      )
    else {
      return nil
    }
    return FocusedAction(isEnabled: true, token: worktreeID) {
      repositoriesStore.send(.requestRenameBranchPrompt(worktreeID))
    }
  }

  private var mainSplitView: some View {
    let visibility = Binding<NavigationSplitViewVisibility>(
      get: { store.leftSidebarVisibility },
      set: { store.send(.setLeftSidebarVisibility($0)) }
    )
    return NavigationSplitView(columnVisibility: visibility) {
      SidebarView(store: repositoriesStore, terminalManager: terminalManager)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      if let client = mirrors.selected {
        RemoteMirrorPaneView(client: client)
      } else {
        WorktreeDetailView(store: store, terminalManager: terminalManager)
      }
    }
    .navigationSplitViewStyle(.automatic)
    .animation(.easeOut(duration: 0.2), value: store.leftSidebarVisibility)
  }

  private func toggleLeftSidebar() {
    store.send(.toggleLeftSidebar)
  }

  private var revealInSidebarAction: (() -> Void)? {
    guard store.repositories.selectedWorktreeID != nil else { return nil }
    return {
      store.send(.showLeftSidebar)
      store.send(.repositories(.revealSelectedWorktreeInSidebar))
    }
  }

}

private struct SurfaceBackgroundOpacityKey: EnvironmentKey {
  static let defaultValue: Double = 1
}

extension EnvironmentValues {
  var surfaceBackgroundOpacity: Double {
    get { self[SurfaceBackgroundOpacityKey.self] }
    set { self[SurfaceBackgroundOpacityKey.self] = newValue }
  }

  var surfaceTopChromeBackgroundOpacity: Double {
    get {
      if surfaceBackgroundOpacity < 1 {
        let proportionalOpacity = surfaceBackgroundOpacity * 0.56
        return min(max(proportionalOpacity, 0.36), 0.62)
      }
      return 1
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }

  var surfaceBottomChromeBackgroundOpacity: Double {
    get {
      if surfaceBackgroundOpacity < 1 {
        let proportionalOpacity = surfaceBackgroundOpacity * 0.78
        return min(max(proportionalOpacity, 0.52), 0.82)
      }
      return 1
    }
    set {
      surfaceBackgroundOpacity = newValue
    }
  }
}

private struct RunScriptPromptView: View {
  @Binding var script: String
  let onCancel: () -> Void
  let onSaveAndRun: () -> Void

  private var canSave: Bool {
    !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Run")
          .font(.title3)
        Text("Enter a command to run in this worktree. It will be saved to repository settings.")
          .foregroundStyle(.secondary)
      }

      PlainTextEditor(
        text: $script,
        isMonospaced: true,
        placeholder: "npm run dev"
      )
      .frame(minHeight: 160)

      HStack {
        Spacer()
        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")

        Button("Save and Run") {
          onSaveAndRun()
        }
        .keyboardShortcut(.defaultAction)
        .help("Save and Run (↩)")
        .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(minWidth: 520)
  }
}
