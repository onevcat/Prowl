import unittest

from check_workflow_naming import violations


class WorkflowNamingTests(unittest.TestCase):
    def test_rejects_stale_public_vocabulary(self):
        for text in (
            "prowl workflow done -", "builtin:git.context", "context.source.pane_id",
            "context.execution.id", "context.run.workflow_id", "context.roles.author.pane",
            "context.action.cwd", "actions.snapshot.result_path", "max_rounds_reached",
            "backend.environment", "expect.verdict", "{{ outputs.brief.path }}",
            "expect: {output: findings, verdict: [clean, issues]}",
            "backend: {type: script, environment: [MY_KEY]}",
            "if: exists(outputs.findings.path)",
            '{"protocol":"prowl.action/v1","context":{"run":{"workflow_id":"review"},"action":{"id":"x","cwd":"/repo"}}}',
            "`workflow list|run|status|done|cancel`",
        ):
            with self.subTest(text=text):
                self.assertTrue(violations(text))

    def test_alternative_protocol_syntax(self):
        for text in (
            '{"steps":[{"id":"review","expect":{"output":"findings","verdict":["clean","issues"]}}]}',
            '{"backend":{"type":"script","environment":["MY_KEY"]}}',
            '{"protocol":"prowl.action/v1","context":{"roles":{"author":{"name":"Pi","pane":"p1"}}}}',
            "expect: # submission\n  output: findings\n  verdict: [clean, issues]",
            "finish with: prowl workflow\n  done -",
            "{{ context['source']['pane_id'] ?? '' }}",
            "{{ context[ 'run' ][ 'directory' ] ?? '' }}",
            "expect: {'output': findings, 'verdict': [clean, issues]}",
            'expect:\n  "output": findings\n  "verdict": [clean, issues]',
        ):
            with self.subTest(text=text):
                self.assertTrue(violations(text))

    def test_custom_data_is_not_reserved(self):
        for text in (
            "{{ inputs.result_path }}",
            "{{ actions.summarize.output.result_path }}",
            "{{ actions.summarize.output.outputs.path }}",
            '{"context":{"source":"git"}}',
            '{"input":{"expect":{"output":"report"},"backend":{"type":"script","environment":[]}}}',

            "{{ actions.snapshot.output.context.source }}",
            "{{ actions.snapshot.output.context.run.directory }}",
            "{{ actions.snapshot.output.expect.verdict }}",
            "{{ actions.snapshot.output.backend.environment }}",
            "steps:\n  - id: snapshot\n    action: local:write-report\n    with:\n"
            "      expect: {output: report}\n      backend: {type: script, environment: [MY_KEY]}",
            "with: {expect: {output: report}, backend: {environment: [MY_KEY]}}",
            "input_schema:\n  properties:\n    expect: {output: report}",
            "output_schema:\n  properties:\n    backend: {environment: [MY_KEY]}",

        ):
            with self.subTest(text=text):
                self.assertFalse(violations(text))

    def test_accepts_current_contract_and_internal_swift_properties(self):
        self.assertFalse(violations("""
prowl workflow deliver -
builtin:collect-worktree-context
context.workflow.id context.run.path context.initiator.pane_id
context.roles.author.pane_id context.action.execution_id
deliveries.brief.path actions.snapshot.output_path backend.inherit_env expect.verdicts
"""))
        self.assertFalse(violations("let source = context.source", swift=True))
        self.assertTrue(violations('let text = "{{ context.source.pane_id }}"', swift=True))


if __name__ == "__main__":
    unittest.main()
