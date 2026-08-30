import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// Inline section that drives a repository's icon and color choice.
/// Hosted at the top of `RepositorySettingsView`'s Form. The actual SF
/// Symbol picker is presented as a sheet via `TabIconPickerView`,
/// parameterised with `RepositoryIconPresets.presets` so the shared
/// picker code surfaces repo-flavored vocabulary instead of the
/// terminal one used by tab icons.
///
/// All mutations go through `RepositorySettingsFeature` actions —
/// never via direct `store.appearance.* = ...` writes — so the
/// `store_state_mutation_in_views` SwiftLint rule stays clean and
/// reducer tests can exercise every code path.
struct RepositoryAppearancePickerView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>

  @State private var isHoveringIconTile = false
  /// Retains the AppKit controller that drives the shared color panel for the
  /// custom-color swatch. `NSColorPanel` keeps its target weakly, so this must
  /// outlive each presentation — `@State` ties it to the view's lifetime.
  @State private var colorPanel = ColorPanelController()

  private let previewSize: CGFloat = 40
  /// Diameter of the colored swatch itself.
  private let swatchDotSize: CGFloat = 20
  /// Diameter of the "selected" ring drawn around the swatch. The
  /// (ring − dot) / 2 gap (3pt) lives between the dot's edge and the
  /// ring's inside, matching macOS-native color pickers.
  private let swatchRingSize: CGFloat = 26
  /// Outer slot every swatch occupies in the HStack so the row layout
  /// stays stable whether or not a swatch is selected (without a fixed
  /// slot the selection ring would expand the cell and shove its
  /// neighbors aside on hover/select).
  private let swatchSlotSize: CGFloat = 28
  private let swatchRingLineWidth: CGFloat = 1.5

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      iconRow
      colorRow
      if let message = store.appearanceImportError {
        importErrorBanner(message: message)
      }
    }
    .sheet(isPresented: $store.isSymbolPickerPresented) {
      TabIconPickerView(
        initialIcon: currentSymbolName,
        defaultIcon: TabIconSource(systemSymbol: "folder.fill"),
        title: "Repository Icon",
        subtitle:
          "Pick a preset or enter any SF Symbol name. SVG and SF Symbol icons are tinted "
          + "with the repo color; bitmap formats keep their own colors.",
        presets: RepositoryIconPresets.presets,
        suggestionsSection: { symbolName in
          AnyView(
            RepositorySymbolSuggestionsSection(
              phase: store.symbolSuggestions,
              onSuggest: {
                if case .loaded = store.symbolSuggestions {
                  store.send(.regenerateSuggestionsTapped)
                } else {
                  store.send(.suggestIconTapped)
                }
              },
              onPick: { symbolName.wrappedValue = $0 }
            )
          )
        },
        onApply: { applySymbolFromPicker($0) },
        onCancel: { dismissSymbolPicker() }
      )
    }
  }

  // MARK: - Icon row

  @ViewBuilder
  private var iconRow: some View {
    HStack(alignment: .center, spacing: 12) {
      iconMenu
      VStack(alignment: .leading, spacing: 4) {
        Text("Icon")
          .interfaceFont(.headline)
        Text(iconHelpText)
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  /// Click target + menu trigger for the icon. The whole preview tile
  /// is the action surface — clicking opens a popover menu with the
  /// three options. Drops the trailing button cluster so narrow
  /// Settings windows don't truncate "Choose Symbol…" / "Clear Icon".
  /// Pattern matches macOS native flows (System Settings user picture,
  /// Finder "Get Info" icon).
  ///
  /// Implementation notes — `.buttonStyle(.plain)` (NOT
  /// `.menuStyle(.borderlessButton)`) is critical: the borderless
  /// menu style applies its own padding and a system tint that
  /// silently overrides the icon's `foregroundStyle`, so the user's
  /// chosen color stops appearing on the preview. Plain button style
  /// lets the label render exactly as authored. Hover detection,
  /// overlay border, pointer style, and tooltip all sit on the
  /// **outer** Menu — `.onHover` placed inside the Menu's label is
  /// swallowed by the menu's pointer interception.
  @ViewBuilder
  private var iconMenu: some View {
    Menu {
      Button("Choose Symbol…") {
        store.send(.chooseSymbolTapped)
      }
      Button("Suggest an Icon…") {
        store.send(.suggestIconTapped)
      }
      Button("Choose Image…") {
        presentImageImporter()
      }
      if store.appearance.icon != nil {
        Divider()
        Button("Clear Icon", role: .destructive) {
          store.send(.setAppearanceIcon(nil))
        }
      }
    } label: {
      iconPreviewTile
    }
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          Color.accentColor.opacity(isHoveringIconTile ? 0.65 : 0),
          lineWidth: 1.5
        )
    }
    .onHover { isHoveringIconTile = $0 }
    .pointerStyle(.link)
    .animation(.easeOut(duration: 0.12), value: isHoveringIconTile)
    .help("Click the icon preview to pick a symbol or import an image")
  }

  /// Visual label for the menu trigger. The frame is locked to
  /// `previewSize × previewSize` so the row layout (and the title /
  /// description text alignment to its right) doesn't shift when the
  /// inner content swaps between the user's icon and the
  /// no-icon placeholder. `.contentShape` confines the click hit-test
  /// to the rounded rectangle so clicks just outside the visible
  /// tile don't open the menu.
  ///
  /// When no icon is set, a dashed border replaces the questionmark's
  /// silence with a "drop zone"-style affordance — the same pattern
  /// macOS uses for empty avatar / drag-target slots — so users see
  /// the tile is interactive even before they hover.
  @ViewBuilder
  private var iconPreviewTile: some View {
    let frame = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let fill = Color.secondary.opacity(0.12)
    let hasIcon = store.appearance.icon != nil
    Group {
      if let icon = store.appearance.icon {
        RepositoryIconImage(
          icon: icon,
          repositoryRootURL: store.rootURL,
          tintColor: tintColor,
          size: 22
        )
      } else {
        Image(systemName: "questionmark")
          .interfaceFont(size: 16, weight: .semibold)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .frame(width: previewSize, height: previewSize)
    .background(fill, in: frame)
    .overlay {
      if !hasIcon {
        frame.stroke(
          Color.secondary.opacity(0.55),
          style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
      }
    }
    .contentShape(.rect(cornerRadius: 8, style: .continuous))
    .accessibilityLabel("Icon picker")
  }

  private var iconHelpText: String {
    switch store.appearance.icon {
    case .userImage(let filename) where !filename.lowercased().hasSuffix(".svg"):
      return "Bitmap icons keep their original colors and ignore the repo color."
    case .userImage:
      return "User-provided SVGs are tinted with the repo color."
    case .detectedImage:
      return "Detected automatically from this project's assets. It keeps its original colors."
    case .sfSymbol:
      return "SF Symbols pick up the repo color when one is set."
    case .bundledAsset:
      return "Bundled icons keep their original artwork."
    case nil:
      return "No icon set. Click the icon preview to pick a symbol or import an image."
    }
  }

  private var tintColor: Color {
    store.appearance.color?.color ?? .accentColor
  }

  private var currentSymbolName: String? {
    if case .sfSymbol(let name) = store.appearance.icon {
      return name
    }
    return nil
  }

  // MARK: - Color row

  @ViewBuilder
  private var colorRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 12) {
        Text("Color")
          .interfaceFont(.headline)
          .frame(width: previewSize, alignment: .center)
        HStack(spacing: 6) {
          ForEach(RepositoryColorChoice.presets, id: \.self) { choice in
            colorSwatch(for: choice)
          }
          customColorSwatch
          noColorSwatch
          Spacer(minLength: 0)
        }
      }
      Text(
        "Tints the row in the sidebar, the shelf spine background, and the canvas card title bar."
      )
      .interfaceFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.leading, previewSize + 12)
    }
  }

  @ViewBuilder
  private func colorSwatch(for choice: RepositoryColorChoice) -> some View {
    let isSelected = store.appearance.color == choice
    Button {
      store.send(.setAppearanceColor(choice))
    } label: {
      swatchSlot(isSelected: isSelected) {
        Circle()
          .fill(choice.color)
          .frame(width: swatchDotSize, height: swatchDotSize)
      }
      .help(choice.displayName)
      .accessibilityLabel(choice.displayName)
      .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
    .buttonStyle(.plain)
  }

  /// Trailing swatch for a free, user-picked color, styled like iOS's color
  /// picker: a rainbow ring (the "any color" affordance) around the chosen
  /// color. macOS has no built-in style for this, so the wheel is hand-drawn;
  /// tapping opens the system color panel via `ColorPanelController`, which
  /// streams the picked color back through `setAppearanceColor`.
  @ViewBuilder
  private var customColorSwatch: some View {
    let isSelected = isCustomColorSelected
    Button {
      colorPanel.onColorChange = { newColor in
        store.send(.setAppearanceColor(.custom(TintColor(newColor))))
      }
      colorPanel.present(initialColor: currentCustomColor)
    } label: {
      swatchSlot(isSelected: isSelected) {
        customColorWheel
      }
      .help("Custom color — pick any color")
      .accessibilityLabel("Custom color")
      .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
    .buttonStyle(.plain)
  }

  /// A solid rainbow dot when no custom color is set (the "pick any color"
  /// affordance); once a custom color is chosen, that color sits in the middle
  /// with a small gap to a thin rainbow rim.
  @ViewBuilder
  private var customColorWheel: some View {
    let rainbow = AngularGradient(
      colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
      center: .center
    )
    if case .custom(let tint) = store.appearance.color {
      ZStack {
        Circle()
          .strokeBorder(rainbow, lineWidth: 2)
          .frame(width: swatchDotSize, height: swatchDotSize)
        Circle()
          .fill(tint.color)
          .frame(width: swatchDotSize - 8, height: swatchDotSize - 8)
      }
    } else {
      Circle()
        .fill(rainbow)
        .frame(width: swatchDotSize, height: swatchDotSize)
    }
  }

  private var isCustomColorSelected: Bool {
    if case .custom = store.appearance.color { return true }
    return false
  }

  /// Seeds the system color panel: the current custom color, or — for a repo
  /// that has never used a custom color — the currently selected preset color,
  /// falling back to the accent tint when no color is set at all.
  private var currentCustomColor: Color {
    store.appearance.color?.color ?? .accentColor
  }

  @ViewBuilder
  private var noColorSwatch: some View {
    let isSelected = store.appearance.color == nil
    Button {
      store.send(.setAppearanceColor(nil))
    } label: {
      swatchSlot(isSelected: isSelected) {
        Circle()
          .stroke(
            Color.secondary.opacity(0.5),
            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
          )
          .frame(width: swatchDotSize, height: swatchDotSize)
          .overlay {
            Image(systemName: "slash.circle")
              .interfaceFont(size: 11)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
      }
      .help("No color")
      .accessibilityLabel("No color")
      .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
    .buttonStyle(.plain)
  }

  /// Centers the swatch content in a fixed-size slot and overlays a
  /// selection ring on top, sized larger than the swatch so a 3pt
  /// transparent gap separates the swatch's edge from the ring's
  /// inside — mirroring macOS-native color picker selection chrome.
  /// The slot bounds stay constant whether selected or not so swatch
  /// row layout doesn't reflow on selection change.
  @ViewBuilder
  private func swatchSlot<Content: View>(
    isSelected: Bool, @ViewBuilder content: () -> Content
  ) -> some View {
    ZStack {
      content()
      if isSelected {
        Circle()
          .stroke(Color.primary, lineWidth: swatchRingLineWidth)
          .frame(width: swatchRingSize, height: swatchRingSize)
      }
    }
    .frame(width: swatchSlotSize, height: swatchSlotSize)
  }

  // MARK: - Error banner

  @ViewBuilder
  private func importErrorBanner(message: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
        .interfaceFont(.caption)
        .foregroundStyle(.primary)
      Spacer(minLength: 0)
      Button("Dismiss") {
        store.send(.dismissAppearanceImportError)
      }
      .buttonStyle(.plain)
      .interfaceFont(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.orange.opacity(0.12))
    )
  }

  // MARK: - Actions

  private func applySymbolFromPicker(_ name: String?) {
    dismissSymbolPicker()
    if let name {
      store.send(.setAppearanceIcon(.sfSymbol(name)))
    } else {
      store.send(.setAppearanceIcon(nil))
    }
  }

  /// Dismissal goes through the reducer so an in-flight suggestion run
  /// is cancelled in one place.
  private func dismissSymbolPicker() {
    store.send(.symbolPickerDismissed)
  }

  // Uses `NSOpenPanel` (rather than SwiftUI's `.fileImporter`) so the
  // panel can open at the repo's working directory — most users keep
  // their icon assets next to the project. Accepts any image UTType —
  // PNG / JPEG / WebP / HEIC / TIFF / GIF / etc. all flow through the
  // same `NSImage(contentsOf:)` render path. SVG is listed explicitly
  // because it's a structured-text format that doesn't always conform
  // to `.image` in older UTType conformance tables. Anything that fails
  // to decode falls back to the dashed placeholder at render time.
  private func presentImageImporter() {
    let panel = NSOpenPanel()
    panel.directoryURL = store.rootURL
    panel.allowedContentTypes = [.image, .svg]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose an image to use as this repository's icon."

    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      store.send(.importUserImage(url))
    }
  }
}

/// Thin AppKit controller that opens the shared `NSColorPanel` for the custom
/// color swatch and forwards live color changes back to SwiftUI. macOS has no
/// SwiftUI API to present the color panel from an arbitrary control, so this
/// drives it directly. `NSColorPanel` holds its target weakly, so the owner
/// must keep this controller alive (see `RepositoryAppearancePickerView`).
@MainActor
private final class ColorPanelController: NSObject {
  /// Invoked continuously while the user adjusts the panel's color.
  var onColorChange: ((Color) -> Void)?

  func present(initialColor: Color) {
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.color = NSColor(initialColor)
    panel.setTarget(self)
    panel.setAction(#selector(colorDidChange(_:)))
    panel.makeKeyAndOrderFront(nil)
  }

  @objc private func colorDidChange(_ sender: NSColorPanel) {
    onColorChange?(Color(nsColor: sender.color))
  }
}
