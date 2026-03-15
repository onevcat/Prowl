import AppKit
import SwiftUI

struct DashboardCardView: View {
  let repositoryName: String
  let worktreeName: String
  let surfaceView: GhosttySurfaceView
  let isFocused: Bool
  let hasUnseenNotification: Bool
  let cardSize: CGSize
  let onTap: () -> Void
  let onDragCommit: (CGSize) -> Void
  let onResize: (CardResizeEdge, CGSize) -> Void
  let onResizeEnd: () -> Void

  enum CardResizeEdge {
    case leading, trailing, bottom
    case bottomLeading, bottomTrailing
  }

  private let titleBarHeight: CGFloat = 28
  private let cornerRadius: CGFloat = 8

  // Gesture-driven drag state: does NOT trigger body re-evaluation
  @GestureState private var dragTranslation: CGSize = .zero

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      terminalContent
    }
    .frame(width: cardSize.width, height: cardSize.height + titleBarHeight)
    .clipShape(.rect(cornerRadius: cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius)
        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFocused ? 2 : 1)
    }
    .compositingGroup()
    .offset(dragTranslation)
    .overlay { resizeHandles }
    .contentShape(.rect)
    .accessibilityAddTraits(.isButton)
    .onTapGesture { onTap() }
  }

  private var titleBar: some View {
    HStack(spacing: 6) {
      if hasUnseenNotification {
        Circle()
          .fill(Color.orange)
          .frame(width: 6, height: 6)
      }
      Text(repositoryName)
        .font(.caption.bold())
        .lineLimit(1)
      Text("/ \(worktreeName)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
    }
    .padding(.horizontal, 8)
    .frame(height: titleBarHeight)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .gesture(
      DragGesture(coordinateSpace: .global)
        .updating($dragTranslation) { value, state, _ in
          state = value.translation
        }
        .onEnded { value in
          onDragCommit(value.translation)
        }
    )
  }

  private var terminalContent: some View {
    GhosttyTerminalView(surfaceView: surfaceView)
      .frame(width: cardSize.width, height: cardSize.height)
      .allowsHitTesting(isFocused)
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
        cursor: .frameResize(position: .bottom, directions: .all),
        isVertical: false,
        edgeOffset: CGSize(width: 0, height: edgeThickness / 2)
      ) { translation in
        onResize(.bottom, translation)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

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
      x: alignment == .bottomTrailing ? cornerSide / 3 : -cornerSide / 3,
      y: cornerSide / 3
    )
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
      .onDisappear {
        if isHovered {
          isHovered = false
          NSCursor.pop()
        }
      }
  }
}
