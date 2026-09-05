"""Independent required scenarios for #726; never infer requirements from received events."""
import os

REVISION = 2
START_STOP_END = (('SessionStart', 'session-start'), ('Stop', 'turn-ended'), ('SessionEnd', 'session-end'))
HEADLESS = {
    'claude': START_STOP_END,
    'codex': (('agent-turn-complete', 'turn-ended'),),
    'copilot': START_STOP_END,
    'droid': START_STOP_END,
    'qodercli': START_STOP_END,
    'pi': (('session_start', 'session-start'), ('agent_settled', 'turn-ended'), ('session_shutdown', 'session-end')),
    'omp': (('session_start', 'session-start'), ('session_stop', 'turn-ended')),
    'opencode': (('session.idle', 'turn-ended'),),
}
ZERO_TURN = {
    'claude': (('SessionStart', 'session-start'), ('SessionEnd', 'session-end')),
    'pi': (('session_start', 'session-start'), ('session_shutdown', 'session-end')),
}
ZERO_TURN_UNSUPPORTED = {
    'codex': 'native_notifier_has_no_session_lifecycle',
    'copilot': 'empty_prompt_rejected_before_session',
    'droid': 'empty_prompt_exits_without_lifecycle',
    'qodercli': 'empty_prompt_has_no_session_start',
    'omp': 'empty_prompt_can_start_model_turn',
    'opencode': 'native_plugin_has_no_session_lifecycle',
}


def same_directory(left, right):
    return isinstance(left, str) and os.path.isabs(left) and os.path.realpath(left) == os.path.realpath(right)


def validate_events(runtime, events, cwd, scope='headless'):
    required = (ZERO_TURN if scope == 'zero-turn' else HEADLESS).get(runtime)
    if required is None or not isinstance(events, list):
        return 'unsupported_event_scope'
    allowed = dict(required)
    # OMP's one-shot host may exit before its queued shutdown relay starts. Validate it when
    # delivered, but require only the reproducible start/settled contract (064.016).
    if runtime == 'omp' and scope == 'headless':
        allowed['session_shutdown'] = 'session-end'
    order = {native: index for index, native in enumerate(allowed)}
    seen, sessions, ranks = set(), set(), []
    for item in events:
        if not isinstance(item, dict):
            return 'malformed_event'
        native, session = item.get('native_event'), item.get('session_id')
        if not isinstance(native, str) or native not in allowed or item.get('event') != allowed[native]:
            return 'unexpected_native_event_or_mapping'
        if not isinstance(session, str) or not session.strip() or not same_directory(item.get('cwd'), cwd):
            return 'event_identity_mismatch'
        seen.add(native)
        sessions.add(session)
        ranks.append(order[native])
    if len(sessions) > 1:
        return 'session_changed'
    if ranks != sorted(ranks):
        return 'event_order_mismatch'
    if not set(dict(required)).issubset(seen):
        return 'required_event_missing'
    return 'verified'


def zero_turn_result(runtime, code, stdout, stderr, events, cwd):
    if runtime not in ZERO_TURN:
        return 'unsupported_event_scope'
    expected_exit = (code == 0 if runtime == 'pi' else
                     code == 1 and 'Input must be provided either through stdin or as a prompt argument' in stderr)
    if not expected_exit or stdout.strip():
        return 'unexpected_zero_turn_result'
    return validate_events(runtime, events, cwd, 'zero-turn')
