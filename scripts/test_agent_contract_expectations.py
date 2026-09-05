"""Required native events must not shrink with the production decoder's capabilities."""
import unittest
import agent_contract_expectations as rules


def event(native, mapped, session='one'):
    return {'native_event': native, 'event': mapped, 'session_id': session, 'cwd': '/private/probe'}


class EventTests(unittest.TestCase):
    def test_complete_session(self):
        events = [event('SessionStart', 'session-start'), event('Stop', 'turn-ended'), event('SessionEnd', 'session-end')]
        self.assertEqual(rules.validate_events('claude', events, '/private/probe'), 'verified')

    def test_missing_wrong_mapping_wrong_session_and_order(self):
        cases = [
            [event('Stop', 'turn-ended')],
            [event('SessionStart', 'session-start'), event('StopFailure', 'turn-ended'), event('SessionEnd', 'session-end')],
            [event('SessionStart', 'session-start'), event('Stop', 'turn-ended', 'two'), event('SessionEnd', 'session-end')],
            [event('SessionEnd', 'session-end'), event('SessionStart', 'session-start'), event('Stop', 'turn-ended')],
            [event('SessionStart', 'turn-ended'), event('Stop', 'turn-ended'), event('SessionEnd', 'session-end')],
        ]
        for events in cases:
            with self.subTest(events=events):
                self.assertNotEqual(rules.validate_events('claude', events, '/private/probe'), 'verified')

    def test_single_event_runtimes_do_not_fabricate_lifecycle(self):
        self.assertEqual(rules.validate_events('codex', [event('agent-turn-complete', 'turn-ended')], '/private/probe'), 'verified')
        self.assertEqual(rules.validate_events('opencode', [event('session.idle', 'turn-ended')], '/private/probe'), 'verified')


class ZeroTurnTests(unittest.TestCase):
    def test_expected_empty_prompt_results(self):
        for runtime, code, message in [('claude', 1, 'Input must be provided either through stdin or as a prompt argument'),
                                       ('pi', 0, '')]:
            events = [event(native, mapped) for native, mapped in rules.ZERO_TURN[runtime]]
            self.assertEqual(rules.zero_turn_result(runtime, code, '', message, events, '/private/probe'), 'verified')
            self.assertNotEqual(rules.zero_turn_result(runtime, 42, '', message, events, '/private/probe'), 'verified')
            self.assertNotEqual(rules.zero_turn_result(runtime, code, 'answer', message, events, '/private/probe'), 'verified')
            self.assertNotEqual(rules.zero_turn_result(runtime, code, '', message, events[:1], '/private/probe'), 'verified')

    def test_omp_empty_prompt_is_not_a_zero_inference_probe(self):
        self.assertNotIn('omp', rules.ZERO_TURN)
        self.assertEqual(rules.ZERO_TURN_UNSUPPORTED['omp'], 'empty_prompt_can_start_model_turn')
