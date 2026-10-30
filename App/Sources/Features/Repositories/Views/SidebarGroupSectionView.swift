import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// A sidebar group: a header with the member rows below it, in one container so
/// the optional color fills behind both (docs-ai 086).
struct SidebarGroupSectionView<Members: View>: View {
  let model: SidebarGroupModel
  let hasTopSpacing: Bool
  /// The key of the top-level entry after this group, for drop destinations.
  let nextKey: String?
  let dragContext: SidebarLayoutDragContext
  let onToggleExpanded: () -> Void
  let store: StoreOf<RepositoriesFeature>
  @ViewBuilder let members: () -> Members
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isExpanded: Bool { model.isExpanded }

  var body: some View {
    let color = model.group.color
    // The gap above and the strip below are drop targets too, so a drag that
    // crosses them keeps its destination.
    VStack(spacing: 0) {
      if hasTopSpacing {
        dropStrip(.aboveGroup(model.id))
      }
      VStack(spacing: 0) {
        header
        if isExpanded {
          content
          if color != nil {
            dropStrip(.groupEnd(model.id, nextKey: nextKey))
          }
        }
      }
      .background {
        if let color {
          groupBackground(color)
        }
      }
    }
    .id(SidebarScrollID.group(model.id))
  }

  private func dropStrip(_ row: SidebarDropRow) -> some View {
    Color.clear
      .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
      .contentShape(.rect)
      .sidebarLayoutDropTarget(row, context: dragContext)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var content: some View {
    if model.members.isEmpty {
      Text("Drag projects here to add them")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12 + SidebarListView.groupMemberIndent)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .sidebarLayoutDropTarget(.groupEnd(model.id, nextKey: nextKey), context: dragContext)
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
      groupIcon
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
    .background {
      // A drop into this group, from the header or a member row.
      if dragContext.targetedDestination.wrappedValue?.groupID == model.id {
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.accentColor.opacity(0.18))
          .padding(.horizontal, 6)
          .accessibilityHidden(true)
      }
    }
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
    .contentShape(.dragPreview, .rect)
    .draggableSidebarItem(.group(model.id), isEnabled: true, context: dragContext)
    .sidebarLayoutDropTarget(.groupHeader(model.id, nextKey: nextKey), context: dragContext)
  }

  /// The user's icon, or a folder that opens with the group. Tintable icons take
  /// the group color, like a repository icon takes the repository color.
  private var groupIcon: some View {
    RepositoryIconImage(
      groupIcon: model.group.icon ?? .sfSymbol(isExpanded ? "folder" : "folder.fill"),
      tintColor: model.group.color?.color ?? .secondary,
      size: 14
    )
  }

  @ViewBuilder
  private var menuItems: some View {
    Button("Rename Group…") {
      store.send(.sidebarGroups(.renameGroupRequested(model.id)))
    }
    .help("Rename this group")
    Menu("Group Color") {
      Button {
        store.send(.sidebarGroups(.setGroupColor(model.id, nil)))
      } label: {
        colorMenuLabel(String(localized: "None"), color: nil)
      }
      .help("Show this group without a color")
      Divider()
      ForEach(RepositoryColorChoice.presets, id: \.self) { color in
        Button {
          store.send(.sidebarGroups(.setGroupColor(model.id, color)))
        } label: {
          colorMenuLabel(color.displayName, color: color.color)
        }
        .help("Show this group with \(color.displayName)")
      }
    }
    .help("Choose the background color of this group")
    Menu("Group Icon") {
      Button("Choose Symbol…") {
        store.send(.sidebarGroups(.chooseGroupSymbolRequested(model.id)))
      }
      .help("Pick an SF Symbol for this group")
      Button("Choose Image…") {
        presentImageImporter()
      }
      .help("Use an image file as the icon of this group")
      if model.group.icon != nil {
        Divider()
        Button("Use Default Icon") {
          store.send(.sidebarGroups(.setGroupIcon(model.id, nil)))
        }
        .help("Show a folder that opens with the group")
      }
    }
    .help("Choose the icon of this group")
    Divider()
    Button("Ungroup") {
      store.send(.sidebarGroups(.ungroup(model.id)))
    }
    .help("Remove the group and keep its repositories in its place")
  }

  private func colorMenuLabel(_ title: String, color: Color?) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(nsImage: Self.colorDot(color))
        .renderingMode(.original)
        .accessibilityHidden(true)
    }
    // A context menu shows only the title of a label with the default style.
    .labelStyle(.titleAndIcon)
  }

  /// Not a template image, so that the menu keeps the color. No color is an empty circle.
  private static func colorDot(_ color: Color?) -> NSImage {
    let fill = color.map { NSColor($0) }
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
      if let fill {
        fill.setFill()
        dot.fill()
      } else {
        NSColor.secondaryLabelColor.setStroke()
        dot.stroke()
      }
      return true
    }
    image.isTemplate = false
    return image
  }

  // Same panel as the repository icon picker. SVG is listed because it does not
  // always conform to `.image`.
  private func presentImageImporter() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .svg]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(localized: "Choose an image to use as this group's icon.")
    let groupID = model.id
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      store.send(.sidebarGroups(.importGroupImage(groupID, url)))
    }
  }
}
