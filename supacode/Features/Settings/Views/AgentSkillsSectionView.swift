import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

/// Settings → Agents → CLI & Skills → Agent Skills: one row per bundled `user`
/// skill, with one full-width line per detected target (status, link folder, action).
/// Link behavior stays in `AgentSkillsFeature`; this view only presents it.
struct AgentSkillsSectionView: View {
  @Dependency(FeatureFlags.self) private var featureFlags
  @Bindable var store: StoreOf<AgentSkillsFeature>

  private var visibleSkills: [AgentSkillsFeature.SkillRow] {
    store.skills.filter { featureFlags.showsSkill($0.id) }
  }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task { store.send(.task) }
      .alert($store.scope(state: \.alert, action: \.alert))
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Agent Skills")
        Text(
          "Link the skills bundled in this app into your agents' skill folders, so every agent "
            + "reads the version that matches the installed app. Same status as prowl skills list."
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let loadError = store.loadError {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .accessibilityLabel("Unavailable")
        VStack(alignment: .leading, spacing: 2) {
          Text("Bundled skills are unavailable.")
          Text(loadError)
            .foregroundStyle(.secondary)
        }
      }
      .font(.callout)
    } else if visibleSkills.isEmpty {
      Text("This app bundles no installable skills.")
        .foregroundStyle(.secondary)
        .font(.callout)
    } else {
      if store.noTargetsDetected {
        Text(
          "No agent skill folder was found in your home directory. Run Claude Code, Codex, or another "
            + "agent once so it creates its folder, or create one from a terminal with "
            + "prowl skills install --target claude|codex|agents."
        )
        .foregroundStyle(.secondary)
        .font(.callout)
      }
      ForEach(visibleSkills) { row in
        skillRow(row)
        if row.id != visibleSkills.last?.id {
          Divider()
        }
      }
    }
  }

  private func skillRow(_ row: AgentSkillsFeature.SkillRow) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.skill.name)
          .font(.headline)
        if row.skill.name != row.skill.id {
          Text(row.skill.id)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Reveal") {
          store.send(.revealSkillButtonTapped(skillID: row.id))
        }
        .help("Show the bundled \(row.skill.id) skill folder in Finder")
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      // The frontmatter description carries agent trigger phrasing; the summary is the
      // human-facing text, so it wins whenever the skill provides one.
      Text(row.skill.summary ?? row.skill.description)
        .foregroundStyle(.secondary)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      if !row.links.isEmpty {
        linkTable(row)
      }
    }
  }

  /// One line per detected target. A grid keeps the target, folder, status, and action columns
  /// aligned across lines, so every line spans the row instead of sizing to its own text.
  private func linkTable(_ row: AgentSkillsFeature.SkillRow) -> some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
      ForEach(row.links) { link in
        if link.id != row.links.first?.id {
          Divider()
        }
        linkLine(skill: row.skill, link: link)
      }
    }
    .font(.callout)
  }

  private func linkLine(skill: BundledSkill, link: AgentSkillsFeature.SkillLink) -> some View {
    GridRow {
      HStack(spacing: 6) {
        statusIcon(link.status)
        Text(link.target.displayName)
      }
      VStack(alignment: .leading, spacing: 2) {
        pathText(abbreviated(link.linkPath))
        if let detail = detail(for: link.status) {
          if detail.isPath {
            pathText(detail.text)
          } else {
            Text(detail.text)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(link.status.destination.map { "\(link.linkPath) → \($0)" } ?? link.linkPath)
      Text(statusText(link.status))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      actionButton(skill: skill, link: link)
        .gridColumnAlignment(.trailing)
    }
  }

  @ViewBuilder
  private func actionButton(skill: BundledSkill, link: AgentSkillsFeature.SkillLink) -> some View {
    switch link.status {
    case .notInstalled:
      Button("Install") {
        store.send(.installLink(skillID: skill.id, targetID: link.id))
      }
      .help("Link the bundled \(skill.id) skill into \(link.linkPath)")
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .installed:
      Button("Remove") {
        store.send(.removeLink(skillID: skill.id, targetID: link.id))
      }
      .help("Remove the \(skill.id) skill link at \(link.linkPath); the bundled skill stays in the app")
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .broken:
      Button("Repair") {
        store.send(.installLink(skillID: skill.id, targetID: link.id))
      }
      .help("Replace the broken link at \(link.linkPath) with this app's bundled \(skill.id) skill")
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .installedDifferentSource(_, let destination):
      if destination != nil {
        Button("Replace") {
          store.send(.installLink(skillID: skill.id, targetID: link.id))
        }
        .help("Replace the link to another Prowl build at \(link.linkPath) with this app's bundled \(skill.id) skill")
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func statusIcon(_ status: SymlinkInstallStatus) -> some View {
    switch status {
    case .installed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Installed")
    case .notInstalled:
      Image(systemName: "xmark.circle")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Not installed")
    case .installedDifferentSource, .broken:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .accessibilityLabel(statusText(status))
    }
  }

  private func statusText(_ status: SymlinkInstallStatus) -> String {
    switch status {
    case .installed: "Installed"
    case .notInstalled: "Not installed"
    case .installedDifferentSource(_, let destination):
      destination == nil ? "Real file or directory" : "Linked elsewhere"
    case .broken: "Broken link"
    }
  }

  /// The second folder line: where a foreign or dangling link points, or why a real file or
  /// directory gets no action.
  private func detail(for status: SymlinkInstallStatus) -> (text: String, isPath: Bool)? {
    switch status {
    case .installed, .notInstalled:
      nil
    case .installedDifferentSource(_, let destination):
      destination.map { ("→ \(abbreviated($0))", true) }
        ?? ("Not a symlink — Prowl never deletes it. Remove it manually to link here.", false)
    case .broken(_, let destination):
      ("→ \(abbreviated(destination))", true)
    }
  }

  /// Paths keep one line and truncate in the middle so the skill folder name stays visible.
  private func pathText(_ path: String) -> some View {
    Text(path)
      .font(.callout.monospaced())
      .lineLimit(1)
      .truncationMode(.middle)
  }

  private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}
