import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// The folder browser of the Add Remote Folder sheet. Return or a double click opens a
/// folder, → and ⌘↓ too; ← and ⌘↑ go to the enclosing folder.
struct RemoteFolderBrowserView: View {
  let store: StoreOf<RemoteFolderBrowserFeature>
  @FocusState private var isListFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(height: 260)
    .background(.background)
    .clipShape(.rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.separator)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Folders on the host")
    .accessibilityIdentifier("remote-folder-browser")
    // Each folder that is shown takes the focus, so the keyboard works after a click in the
    // path bar too. An empty list cannot take it before the first folder arrives.
    .onChange(of: store.listing?.path, initial: true) { isListFocused = true }
  }

  private var header: some View {
    HStack(spacing: 4) {
      Button {
        store.send(.parentFolderOpened)
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Enclosing Folder")
      }
      .buttonStyle(.borderless)
      .disabled(store.parentPath == nil)
      .help("Go to the enclosing folder (⌘↑)")

      ScrollView(.horizontal) {
        HStack(spacing: 2) {
          ForEach(store.pathComponents) { component in
            if component.id != store.pathComponents.first?.id {
              Image(systemName: "chevron.compact.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
            let isLast = component.id == store.pathComponents.last?.id
            Button {
              store.send(.folderOpened(component.path))
            } label: {
              Text(verbatim: component.title)
                .fontWeight(isLast ? .semibold : .regular)
                .foregroundStyle(isLast ? .primary : .secondary)
                .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: component.path))
          }
        }
        .padding(.horizontal, 2)
      }
      .scrollIndicators(.never)
      // A long path shows its end; a short one stays at the leading edge.
      .defaultScrollAnchor(.trailing, for: .initialOffset)
      .defaultScrollAnchor(.trailing, for: .sizeChanges)
      .defaultScrollAnchor(.leading, for: .alignment)

      if store.isLoading {
        ProgressView()
          .controlSize(.small)
      }
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  /// The list stays in place in every state, so it keeps the keyboard focus when a folder
  /// has no subfolders or fails to load.
  private var content: some View {
    folderList
      .overlay {
        if let errorMessage = store.errorMessage {
          VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
              .font(.title2)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
              store.send(.retryButtonTapped)
            }
            .controlSize(.small)
            .help("List the folder again")
          }
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
        } else if store.listing == nil {
          VStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Connecting to the host…")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } else if store.visibleEntries.isEmpty {
          Text("No folders")
            .font(.callout)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
      }
  }

  private var folderList: some View {
    List(selection: Binding(get: { store.selectedName }, set: { store.send(.selectionChanged($0)) })) {
      ForEach(store.visibleEntries) { entry in
        row(entry)
          .tag(entry.name)
          .selectionDisabled(!entry.isAccessible)
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .alternatingRowBackgrounds()
    .scrollContentBackground(.hidden)
    .opacity(store.isLoading ? 0.5 : 1)
    .focused($isListFocused)
    .contextMenu(forSelectionType: String.self) { _ in
    } primaryAction: { names in
      if let name = names.first { store.send(.entryOpened(name)) }
    }
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
      let command = press.modifiers.contains(.command)
      if press.key == .leftArrow || (press.key == .upArrow && command) {
        store.send(.parentFolderOpened)
        return .handled
      }
      if press.key == .rightArrow || (press.key == .downArrow && command), let name = store.selectedName {
        store.send(.entryOpened(name))
        return .handled
      }
      return .ignored
    }
    .accessibilityIdentifier("remote-folder-browser-list")
  }

  private func row(_ entry: RemoteFolderListing.Entry) -> some View {
    HStack(spacing: 6) {
      Image(nsImage: NSWorkspace.shared.icon(for: .folder))
        .resizable()
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      Text(verbatim: entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if entry.isRepository {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(.secondary)
          .help("Git repository")
          .accessibilityLabel("Git repository")
      }
      if !entry.isAccessible {
        Image(systemName: "lock")
          .foregroundStyle(.secondary)
          .help("Prowl cannot open this folder")
          .accessibilityLabel("Cannot open")
      }
    }
    .opacity(entry.isAccessible ? 1 : 0.5)
  }

  private var footer: some View {
    HStack {
      Toggle(
        "Show Hidden Folders",
        isOn: Binding(get: { store.showsHiddenFolders }, set: { _ in store.send(.showsHiddenFoldersToggled) })
      )
      .toggleStyle(.checkbox)
      .help("Show folders whose names start with a dot")
      Spacer()
      if let omittedCount = store.listing?.omittedCount, omittedCount > 0 {
        Text("\(omittedCount) more folders are not shown.")
          .foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}
