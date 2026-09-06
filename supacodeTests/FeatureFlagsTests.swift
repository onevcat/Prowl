import ComposableArchitecture
import Testing

@testable import supacode

@MainActor
struct FeatureFlagsTests {
  @Test func workflowUIIsEnabledByDefaultAndCanBeDisabled() {

    #expect(FeatureFlags(environment: [:]).workflowUI)
    for environment in [["PROWL_WORKFLOW_UI": ""], ["PROWL_WORKFLOW_UI": "0"], ["PROWL_WORKFLOW_UI": "true"]] {
      #expect(!FeatureFlags(environment: environment).workflowUI)
    }
    #expect(FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "1"]).workflowUI)
  }

  @Test func hiddenWorkflowSettingsCannotBeSelected() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.featureFlags = FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "0"])
    }
    await store.send(.setSelection(.workflows)) {
      $0.selection = .profiles
    }
    #expect(store.state.workflows == nil)
  }

  @Test func workflowSkillVisibilityDoesNotHideOtherSkills() {
    let flags = FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "0"])
    #expect(!flags.showsSkill("prowl-workflow"))
    #expect(flags.showsSkill("prowl-cli"))
    #expect(FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "1"]).showsSkill("prowl-workflow"))
  }
}
