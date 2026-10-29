import ComposableArchitecture
import SwiftUI

/// A sidebar group: a header with the member rows below it, in one container so
/// the optional color fills behind both (docs-ai 086).
struct SidebarGroupSectionView<Members: View>: View {
  let model: SidebarGroupModel
  let hasTopSpacing: Bool
  let onToggleExpanded: () -> Void
  let store: StoreOf<RepositoriesFeature>
  @ViewBuilder let members: () -> Members
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isExpanded: Bool { model.isExpanded }

  var body: some View {
    let color = model.group.color
    VStack(spacing: 0) {
      header
      if isExpanded {
        content
      }
    }
    .padding(.bottom, isExpanded && color != nil ? 4 : 0)
    .background {
      if let color {
        groupBackground(color)
      }
    }
    .padding(.top, hasTopSpacing ? 4 : 0)
    .id(SidebarScrollID.group(model.id))
  }

  @ViewBuilder
  private var content: some View {
    if model.members.isEmpty {
      Text("No repositories")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    } else {
      members()
    }
  }

  private func groupBackground(_ color: RepositoryColorChoice) -> some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(color.color.opacity(0.08))
      .padding(.horizontal, 4)
      .accessibilityHidden(true)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(model.group.title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(model.memberCount, format: .number)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
        .accessibilityLabel(Text("^[\(model.memberCount) repository](inflect: true)"))
      Spacer(minLength: 0)
      if isHovering {
        Menu {
          menuItems
        } label: {
          Label("Group options", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Group options")
      }
      Button {
        onToggleExpanded()
      } label: {
        Image(systemName: "chevron.right")
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(maxHeight: .infinity)
          .contentShape(.rect)
          .accessibilityLabel(isExpanded ? "Collapse Group" : "Expand Group")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(isExpanded ? "Collapse Group" : "Expand Group")
    }
    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    .padding(.horizontal, 12)
    .contentShape(.interaction, .rect)
    .onHover { hovering in
      if reduceMotion {
        isHovering = hovering
      } else {
        withAnimation(.easeOut(duration: 0.15)) {
          isHovering = hovering
        }
      }
    }
    // Same tap pattern as the repository header: the chevron and the options
    // menu are buttons inside the header, so the header itself cannot be one.
    .onTapGesture {
      onToggleExpanded()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(model.group.title))
    .accessibilityAddTraits([.isHeader, .isButton])
    .accessibilityAction {
      onToggleExpanded()
    }
    .contextMenu {
      menuItems
    }
  }

  @ViewBuilder
  private var menuItems: some View {
    Button("Rename Group…") {
      store.send(.sidebarGroups(.renameGroupRequested(model.id)))
    }
    .help("Rename this group")
    Menu("Group Color") {
      Button("None") {
        store.send(.sidebarGroups(.setGroupColor(model.id, nil)))
      }
      .help("Show this group without a color")
      Divider()
      ForEach(RepositoryColorChoice.presets, id: \.self) { color in
        Button(color.displayName) {
          store.send(.sidebarGroups(.setGroupColor(model.id, color)))
        }
        .help("Show this group with \(color.displayName)")
      }
    }
    .help("Choose the background color of this group")
    Divider()
    Button("Ungroup") {
      store.send(.sidebarGroups(.ungroup(model.id)))
    }
    .help("Remove the group and keep its repositories in its place")
  }
}
