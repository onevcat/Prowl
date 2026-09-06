import AppKit
import ProwlCLIShared
import SwiftUI

struct CanvasCardView: View {
  let repositoryName: String
  let worktreeName: String
  /// User-pinned icon for this card's repository, drawn before the
  /// repo name in the title bar. `nil` keeps the historical text-only
  /// title bar.
  var repositoryIcon: RepositoryIconSource?
  /// User-pinned color for this card's repository. When set, it tints
  /// both the icon (if tintable) and the title-bar background as an
  /// always-on identity strip.
  var repositoryColor: Color?
  /// Repo root URL, needed by `RepositoryIconImage` to resolve user
  /// PNG/SVG filenames against the per-repo icons directory.
  var repositoryRootURL: URL?
  let tree: SplitTree<GhosttySurfaceView>
  let activeSurfaceID: UUID?
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  var splitDivider: (color: Color?, width: CGFloat?) = (nil, nil)
  let isFocused: Bool
  let isSelected: Bool
  let hasUnseenNotification: Bool
  let tabIcon: String?
  let tabId: TerminalTabID
  let tabs: [TerminalTabItem]
  let tabContextMenuActions: TerminalTabContextMenuActions
  let cardSize: CGSize
  /// Whether this card is currently expanded in place (near-fullscreen). When
  /// true the title-bar button restores instead of expands, resize handles and
  /// title-bar dragging are disabled, and the action buttons stay visible.
  let isExpanded: Bool
  /// Tooltip for the expand/restore button, including the bound shortcut (the
  /// parent resolves it since CanvasCardView has no keybindings context).
  let expandHelp: String
  let canvasScale: CGFloat
  /// Whether a terminal link is currently hovered while Command is held, so
  /// the click must reach Ghostty even on non-focused cards (broadcast
  /// followers) instead of falling through to the selection callbacks.
  let linkActivationRequested: Bool
  let showsSelectionShield: Bool
  let onTap: () -> Void
  let onSelectionTap: () -> Void
  let onDragCommit: (CGSize) -> Void
  let onResize: (CardResizeEdge, CGSize) -> Void
  let onResizeEnd: () -> Void
  let onSplitOperation: (TerminalSplitTreeView.Operation) -> Void
  let onTitleBarTap: () -> Void
  let onExpand: () -> Void
  let onClose: () -> Void

  enum CardResizeEdge {
    case leading, trailing, top, bottom
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Sign multipliers for width and height during resize.
    /// +1 = trailing/bottom grows, -1 = leading/top grows, 0 = no change.
    var resizeSigns: (width: Int, height: Int) {
      switch self {
      case .leading: (-1, 0)
      case .trailing: (1, 0)
      case .top: (0, -1)
      case .bottom: (0, 1)
      case .topLeading: (-1, -1)
      case .topTrailing: (1, -1)
      case .bottomLeading: (-1, 1)
      case .bottomTrailing: (1, 1)
      }
    }
  }

  private let titleBarHeight: CGFloat = 28
  private let cornerRadius: CGFloat = 8

  // Gesture-driven drag state: does NOT trigger body re-evaluation
  @GestureState private var dragTranslation: CGSize = .zero
  @State private var isHoveringTitleBar: Bool = false

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      terminalContent
    }
    .frame(width: cardSize.width, height: cardSize.height + titleBarHeight)
    .background(cardBackground)
    .clipShape(.rect(cornerRadius: cornerRadius))
    .overlay {
      ZStack {
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(borderColor, lineWidth: borderLineWidth)
        if !showsSelectionShield && !isExpanded {
          resizeHandles
        }
        if showsSelectionShield {
          selectionShield
        }
      }
    }
    .compositingGroup()
    .contentShape(.rect)
    .accessibilityAddTraits(.isButton)
    .onTapGesture { onTap() }
    .offset(
      x: dragTranslation.width / canvasScale,
      y: dragTranslation.height / canvasScale
    )
  }

  private var borderColor: Color {
    if isFocused {
      .accentColor
    } else if isSelected {
      .accentColor.opacity(0.65)
    } else {
      .secondary.opacity(0.3)
    }
  }

  private var borderLineWidth: CGFloat {
    if isFocused {
      2
    } else if isSelected {
      1.5
    } else {
      1
    }
  }

  @ViewBuilder
  private var cardBackground: some View {
    if isSelected && !isFocused {
      Color.accentColor.opacity(0.08)
    } else {
      Color.clear
    }
  }

  private var titleBar: some View {
    HStack(spacing: 6) {
      if let repositoryIcon, let repositoryRootURL {
        RepositoryIconImage(
          icon: repositoryIcon,
          repositoryRootURL: repositoryRootURL,
          tintColor: repositoryColor,
          size: 12
        )
      }
      Text(repositoryName)
        .font(.caption.bold())
        .lineLimit(1)
      HStack(spacing: 3) {
        Text("/")
        if let tabIcon {
          TabIconImage(rawName: tabIcon, pointSize: 10)
        }
        Text(worktreeName)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      Spacer()
      titleBarActions
    }
    .padding(.horizontal, 8)
    .frame(height: titleBarHeight)
    .frame(maxWidth: .infinity)
    .background(titleBarBackground)
    .accessibilityAddTraits(.isButton)
    .onTapGesture { onTitleBarTap() }
    .onHover { hovering in
      isHoveringTitleBar = hovering
    }
    .gesture(
      DragGesture(coordinateSpace: .global)
        .updating($dragTranslation) { value, state, _ in
          state = value.translation
        }
        .onEnded { value in
          onDragCommit(
            CGSize(
              width: value.translation.width / canvasScale,
              height: value.translation.height / canvasScale
            ))
        },
      isEnabled: !isExpanded
    )
    .terminalTabContextMenu(
      tabId: tabId,
      tabs: tabs,
      actions: tabContextMenuActions,
      variant: .canvas
    )
  }

  private var titleBarActions: some View {
    HStack(spacing: 2) {
      Button {
        onExpand()
      } label: {
        Image(
          systemName: isExpanded
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
        .font(.caption2.weight(.semibold))
        .frame(width: 18, height: 18)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(expandHelp)
      .accessibilityLabel(isExpanded ? "Restore card size" : "Expand card")

      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .frame(width: 18, height: 18)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Close card")
      .accessibilityLabel("Close card")
    }
    .opacity(isExpanded || isHoveringTitleBar ? 1 : 0)
    .allowsHitTesting(isExpanded || isHoveringTitleBar)
    .animation(.easeInOut(duration: 0.15), value: isHoveringTitleBar)
  }

  @ViewBuilder
  private var titleBarBackground: some View {
    // Layering, back-to-front:
    //
    //  1. selected-but-unfocused accent (subtle, sits under the bar
    //     material — same behavior as before this feature shipped)
    //  2. `.bar` material substrate
    //  3. **either** the notification orange **or** the repo color
    //     identity strip — never both. Without this mutual exclusion
    //     the orange used to muddle into the repo color (e.g. a blue
    //     repo's notification looked brownish-grey instead of the
    //     intended attention-grabbing orange). The notification wins
    //     on top with a much higher alpha (0.55) than the previous
    //     under-bar 0.3 so the unread signal actually pops.
    ZStack {
      if isSelected && !isFocused {
        Color.accentColor.opacity(0.12)
      }
      Rectangle()
        .fill(.bar)
        .opacity(0.9)
      if hasUnseenNotification {
        Color.orange.opacity(0.55)
      } else if let repositoryColor {
        repositoryColor.opacity(isFocused ? 0.18 : 0.10)
      }
    }
  }

  private var terminalContent: some View {
    AnimatedTerminalSplitTreeView(
      tree: tree,
      size: cardSize,
      activeSurfaceID: activeSurfaceID,
      unfocusedSplitOverlay: unfocusedSplitOverlay,
      splitDivider: splitDivider,
      hasNotification: { _ in false },
      action: onSplitOperation
    )
    // No own size animation: the canvas drives every size change inside a
    // withAnimation (expand/restore, resize commit, arrange), so the terminal
    // refit stays in lock-step with the card's offset/scale. Without a wrapping
    // animation (live resize drag) the size tracks the gesture 1:1.
    .allowsHitTesting(
      CanvasInteractionPolicy.terminalHitTestingEnabled(
        isFocused: isFocused,
        linkActivationRequested: linkActivationRequested,
        showsSelectionShield: showsSelectionShield
      )
    )
  }

  private var selectionShield: some View {
    Color.clear
      .contentShape(.rect)
      .accessibilityAddTraits(.isButton)
      .onTapGesture { onSelectionTap() }
  }

  // MARK: - Resize Handles

  private let edgeThickness: CGFloat = 10
  private let cornerSide: CGFloat = 18

  private var resizeHandles: some View {
    ZStack {
      edgeHandle(
        cursor: .frameResize(position: .left, directions: .all),
        isVertical: true,
        edgeOffset: CGSize(width: -edgeThickness / 2, height: 0)
      ) { translation in
        onResize(.leading, translation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

      edgeHandle(
        cursor: .frameResize(position: .right, directions: .all),
        isVertical: true,
        edgeOffset: CGSize(width: edgeThickness / 2, height: 0)
      ) { translation in
        onResize(.trailing, translation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

      edgeHandle(
        cursor: .frameResize(position: .top, directions: .all),
        isVertical: false,
        edgeOffset: CGSize(width: 0, height: -edgeThickness / 2)
      ) { translation in
        onResize(.top, translation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      edgeHandle(
        cursor: .frameResize(position: .bottom, directions: .all),
        isVertical: false,
        edgeOffset: CGSize(width: 0, height: edgeThickness / 2)
      ) { translation in
        onResize(.bottom, translation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

      cornerHandle(
        cursor: .frameResize(position: .topLeft, directions: .all),
        alignment: .topLeading
      ) { translation in
        onResize(.topLeading, translation)
      }

      cornerHandle(
        cursor: .frameResize(position: .topRight, directions: .all),
        alignment: .topTrailing
      ) { translation in
        onResize(.topTrailing, translation)
      }

      cornerHandle(
        cursor: .frameResize(position: .bottomLeft, directions: .all),
        alignment: .bottomLeading
      ) { translation in
        onResize(.bottomLeading, translation)
      }

      cornerHandle(
        cursor: .frameResize(position: .bottomRight, directions: .all),
        alignment: .bottomTrailing
      ) { translation in
        onResize(.bottomTrailing, translation)
      }
    }
  }

  private func edgeHandle(
    cursor: NSCursor,
    isVertical: Bool,
    edgeOffset: CGSize,
    onChange: @escaping (CGSize) -> Void
  ) -> some View {
    ResizeCursorView(cursor: cursor) {
      Color.clear
        .frame(
          width: isVertical ? edgeThickness : nil,
          height: isVertical ? nil : edgeThickness
        )
        .frame(
          maxWidth: isVertical ? nil : .infinity,
          maxHeight: isVertical ? .infinity : nil
        )
        .contentShape(.rect)
        .gesture(
          DragGesture(coordinateSpace: .global)
            .onChanged { value in onChange(value.translation) }
            .onEnded { _ in onResizeEnd() }
        )
    }
    .offset(edgeOffset)
  }

  private func cornerHandle(
    cursor: NSCursor,
    alignment: Alignment,
    onChange: @escaping (CGSize) -> Void
  ) -> some View {
    ResizeCursorView(cursor: cursor) {
      Color.clear
        .frame(width: cornerSide, height: cornerSide)
        .contentShape(.rect)
        .gesture(
          DragGesture(coordinateSpace: .global)
            .onChanged { value in onChange(value.translation) }
            .onEnded { _ in onResizeEnd() }
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    .offset(
      x: (alignment == .bottomTrailing || alignment == .topTrailing) ? cornerSide / 3 : -cornerSide / 3,
      y: (alignment == .topLeading || alignment == .topTrailing) ? -cornerSide / 3 : cornerSide / 3
    )
  }
}

private struct AnimatedTerminalSplitTreeView: View, Animatable {
  let tree: SplitTree<GhosttySurfaceView>
  var size: CGSize
  let activeSurfaceID: UUID?
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  var splitDivider: (color: Color?, width: CGFloat?)
  let hasNotification: (UUID) -> Bool
  let action: (TerminalSplitTreeView.Operation) -> Void

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(size.width, size.height) }
    set {
      size = CGSize(width: newValue.first, height: newValue.second)
    }
  }

  var body: some View {
    TerminalSplitTreeView(
      tree: tree,
      pinnedSize: size,
      activeSurfaceID: activeSurfaceID,
      unfocusedSplitOverlay: unfocusedSplitOverlay,
      splitDivider: splitDivider,
      hasNotification: hasNotification,
      action: action
    )
    .frame(width: size.width, height: size.height)
  }
}

private struct ResizeCursorView<Content: View>: View {
  let cursor: NSCursor
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    content
      .onHover { hovering in
        guard hovering != isHovered else { return }
        isHovered = hovering
        if hovering {
          cursor.push()
        } else {
          NSCursor.pop()
        }
      }
  }
}
