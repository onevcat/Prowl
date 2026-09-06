import ComposableArchitecture
import Foundation
import ProwlCLIShared

/// Settings → Agents → CLI & Skills → Agent Skills (docs-ai 065): the `user`-audience
/// skills bundled in this app, one status chip per detected user target, and one explicit
/// action per skill × target link. Statuses come from the shared installer, so the section
/// always agrees with `prowl skills list`.
@Reducer
struct AgentSkillsFeature {
  @ObservableState
  struct State: Equatable {
    var skills: IdentifiedArrayOf<SkillRow> = []
    /// Why the bundle could not be read (for example a Debug build without staged skills).
    var loadError: String?
    @Presents var alert: AlertState<Alert>?

    /// Skills exist but no agent skill folder was found in the home directory.
    var noTargetsDetected: Bool {
      !skills.isEmpty && skills.allSatisfy { $0.links.isEmpty }
    }
  }

  struct SkillRow: Equatable, Identifiable {
    let skill: BundledSkill
    /// Detected targets only, in `SkillInstallTarget.all` order.
    var links: IdentifiedArrayOf<SkillLink>

    var id: String { skill.id }
  }

  struct SkillLink: Equatable, Identifiable {
    let target: SkillInstallTarget
    let linkPath: String
    var status: SymlinkInstallStatus

    var id: String { target.id }
  }

  enum Action: Equatable {
    case task
    /// Install, Repair, and Replace: every one replaces the slot with a link to this bundle.
    case installLink(skillID: String, targetID: String)
    case removeLink(skillID: String, targetID: String)
    case revealSkillButtonTapped(skillID: String)
    case linkChangeCompleted(Result<LinkChange, SkillInstallError>)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  enum LinkChange: Equatable {
    case installed(skillID: String, targetID: String)
    case removed(skillID: String, targetID: String)
  }

  enum Alert: Equatable {
    case dismiss
  }

  @CasePathable
  enum Delegate: Equatable {
    case linkChanged(AgentSkillsResultMessage)
  }

  @Dependency(SkillInstallClient.self) private var skillInstallClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        reload(&state)
        return .none

      case .installLink(let skillID, let targetID):
        guard let (skill, target) = link(skillID: skillID, targetID: targetID, in: state) else { return .none }
        return .run { [skillInstallClient] send in
          do {
            try await skillInstallClient.install(skill, target)
            await send(.linkChangeCompleted(.success(.installed(skillID: skillID, targetID: targetID))))
          } catch let error as SkillInstallError {
            await send(.linkChangeCompleted(.failure(error)))
          } catch {
            await send(.linkChangeCompleted(.failure(SkillInstallError(message: error.localizedDescription))))
          }
        }

      case .removeLink(let skillID, let targetID):
        guard let (skill, target) = link(skillID: skillID, targetID: targetID, in: state) else { return .none }
        return .run { [skillInstallClient] send in
          do {
            try await skillInstallClient.uninstall(skill, target)
            await send(.linkChangeCompleted(.success(.removed(skillID: skillID, targetID: targetID))))
          } catch let error as SkillInstallError {
            await send(.linkChangeCompleted(.failure(error)))
          } catch {
            await send(.linkChangeCompleted(.failure(SkillInstallError(message: error.localizedDescription))))
          }
        }

      case .revealSkillButtonTapped(let skillID):
        guard let skill = state.skills[id: skillID]?.skill else { return .none }
        return .run { [skillInstallClient] _ in
          skillInstallClient.revealSkill(skill)
        }

      case .linkChangeCompleted(.success(let change)):
        // Targets can alias one folder (synced ~/.claude/skills and ~/.codex/skills), so every
        // chip is recomputed rather than just the one that was acted on.
        reload(&state)
        let message: AgentSkillsResultMessage =
          switch change {
          case .installed(let skillID, let targetID):
            .installed(skill: skillID, target: targetDisplayName(targetID))
          case .removed(let skillID, let targetID):
            .removed(skill: skillID, target: targetDisplayName(targetID))
          }
        return .send(.delegate(.linkChanged(message)))

      case .linkChangeCompleted(.failure(let error)):
        reload(&state)
        state.alert = AlertState {
          TextState("Agent Skills Error")
        } actions: {
          ButtonState(action: .dismiss) { TextState("OK") }
        } message: {
          TextState(error.message)
        }
        return .send(.delegate(.linkChanged(.failed(message: error.message))))

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func reload(_ state: inout State) {
    do {
      let skills = try skillInstallClient.bundledSkills().filter { $0.audience == .user }
      state.skills = IdentifiedArray(
        uniqueElements: skills.map { skill in
          let links = SkillInstallTarget.all.compactMap { target -> SkillLink? in
            let status = skillInstallClient.status(skill, target)
            guard status.detected else { return nil }
            return SkillLink(target: target, linkPath: status.linkPath, status: status.status)
          }
          return SkillRow(skill: skill, links: IdentifiedArray(uniqueElements: links))
        }
      )
      state.loadError = nil
    } catch let error as SkillInstallError {
      state.skills = []
      state.loadError = error.message
    } catch {
      state.skills = []
      state.loadError = error.localizedDescription
    }
  }

  private func link(skillID: String, targetID: String, in state: State) -> (BundledSkill, SkillInstallTarget)? {
    guard let row = state.skills[id: skillID], let link = row.links[id: targetID] else { return nil }
    return (row.skill, link.target)
  }

  private func targetDisplayName(_ targetID: String) -> String {
    SkillInstallTarget.target(id: targetID)?.displayName ?? targetID
  }
}

enum AgentSkillsResultMessage: Equatable {
  case installed(skill: String, target: String)
  case removed(skill: String, target: String)
  case failed(message: String)
}
