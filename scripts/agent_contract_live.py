"""Opt-in real runtime / production hook bridge contracts, outside the live GUI."""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
import secrets
import socket
import struct
import sys
import subprocess
import tempfile
import threading
import time

import agent_contracts as core
import agent_contract_expectations as rules


def same_directory(left, right):
    return isinstance(left, str) and os.path.isabs(left) and os.path.realpath(left) == os.path.realpath(right)


def verify_response(output, expected):
    return bool(re.search(r'RESULT:\s*' + re.escape(expected.split(':')[1]) + r'(?![0-9])', output))


def terminal_signal(signal, cwd):
    return (isinstance(signal, dict) and signal.get('event') == 'turn-ended'
            and signal.get('native_event') not in ('StopFailure', None)
            and same_directory(signal.get('cwd'), cwd) and bool(signal.get('session_id')))


def accept_signal(payload, runtime, token, cwd):
    return (isinstance(payload, dict) and payload.get('runtime') == runtime
            and payload.get('token') == token and terminal_signal(payload.get('signal'), cwd))


def evaluate(returncode, timed_out, response, hook):
    if timed_out:
        return 'runtime_timeout'
    if returncode != 0:
        return 'runtime_failed'
    if not response:
        return 'response_missing'
    if not hook:
        return 'terminal_hook_missing'
    return 'verified'


class Collector:
    """Length-framed CLI transport. No synthetic native events are generated here."""
    def __init__(self, path, runtime, token, cwd, scope="headless"):
        self.runtime, self.token, self.cwd = runtime, token, cwd
        self.scope = scope
        self.complete = threading.Event()
        self.events = []
        self.terminal = False
        self.error = False
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(8)
        self.server.settimeout(0.1)
        self.thread = threading.Thread(target=self.run, daemon=True)

    @staticmethod
    def read(connection, count):
        data = b''
        while len(data) < count:
            part = connection.recv(count - len(data))
            if not part:
                raise ValueError('Incomplete frame')
            data += part
        return data

    def run(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with connection:
                connection.settimeout(0.3)
                try:
                    size = struct.unpack('>I', self.read(connection, 4))[0]
                    if not 0 < size <= core.MAX_CAPTURE_BYTES:
                        raise ValueError('Invalid frame')
                    document = json.loads(self.read(connection, size))
                    payload = document['command']['agentsHook']['_0']
                    if (payload.get('runtime') == self.runtime and payload.get('token') == self.token
                            and same_directory(payload.get('signal', {}).get('cwd'), self.cwd)):
                        signal = payload['signal']
                        self.events.append({key: signal[key] for key in ('event', 'native_event', 'cwd', 'session_id') if key in signal})
                        self.terminal |= accept_signal(payload, self.runtime, self.token, self.cwd)
                        if rules.validate_events(self.runtime, self.events, self.cwd, self.scope) == "verified":
                            self.complete.set()
                    connection.sendall(struct.pack('>I', 2) + b'{}')
                except (OSError, ValueError, KeyError, TypeError):
                    self.error = True

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=1)
        self.server.close()


def write_text(path, text):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
        output.write(text)


def runtime_configuration(runtime, route, directory):
    """Explicit provider routes with temporary state; values are credential references only."""
    expected_wire = {'codex': 'responses', 'claude': 'anthropic-messages', 'qodercli': 'runtime-managed'}
    if route['wire_api'] != expected_wire.get(runtime, 'chat-completions'):
        raise core.PolicyError('The live recipe does not support the selected wire protocol.')
    if runtime != 'qodercli' and route['api_key_env'] is None:
        raise core.PolicyError('The live recipe requires an explicit credential reference.')
    model, base, key = route['model'], route['base_url'], route['api_key_env']
    environment, arguments = {}, []
    state = directory / 'state'
    state.mkdir(mode=0o700)
    if runtime == 'codex':
        environment['CODEX_HOME'] = str(state)
        write_text(state / 'config.toml', '\n'.join([
            'model_provider = "contract"', 'model_reasoning_effort = "low"',
            'model_reasoning_summary = "none"', 'web_search = "disabled"',
            '[model_providers.contract]', 'name = "Contract provider"',
            'base_url = ' + json.dumps(base), 'wire_api = "responses"',
            'env_key = ' + json.dumps(key), 'request_max_retries = 0', 'stream_max_retries = 0',
        ]) + '\n')
        arguments = ['--skip-git-repo-check', '--ephemeral', '--sandbox', 'read-only']
    elif runtime == 'claude':
        environment.update(CLAUDE_CONFIG_DIR=str(state), ANTHROPIC_BASE_URL=base,
                           ANTHROPIC_MODEL=model, ANTHROPIC_DEFAULT_HAIKU_MODEL=model,
                           ANTHROPIC_DEFAULT_SONNET_MODEL=model, ANTHROPIC_DEFAULT_OPUS_MODEL=model,
                           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
                           CLAUDE_CODE_MAX_OUTPUT_TOKENS='512', MAX_THINKING_TOKENS='0', API_MAX_RETRIES='0')
        arguments = ['--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                     '--no-session-persistence', '--max-turns', '1', '--system-prompt', 'Answer the arithmetic question.']
    elif runtime == 'copilot':
        environment.update(COPILOT_HOME=str(state), COPILOT_PROVIDER_TYPE='openai',
                           COPILOT_PROVIDER_BASE_URL=base, COPILOT_PROVIDER_WIRE_API='completions',
                           COPILOT_PROVIDER_MODEL=model, COPILOT_PROVIDER_MAX_OUTPUT_TOKENS='512',
                           COPILOT_OFFLINE='true')
        arguments = ['--no-custom-instructions', '--no-auto-update', '--no-remote', '--no-ask-user',
                     '--available-tools=', '--disable-builtin-mcps', '--stream', 'off']
    elif runtime == 'droid':
        config = state / 'settings.json'
        core.write_json(config, {'customModels': [{'model': model, 'displayName': 'Contract Flash',
            'baseUrl': base, 'apiKey': '${' + key + '}', 'provider': 'generic-chat-completion-api',
            'maxOutputTokens': 512, 'extraArgs': {'thinking': {'type': 'disabled'}}}]})
        arguments = ['--settings', str(config), '-m', 'custom:' + model, '--enabled-tools', '', '--disable-builtin-skills']
        # Factory credentials remain in its normal home: BYOK may still require a Factory account.
    elif runtime in ('pi', 'omp'):
        environment['PI_CODING_AGENT_DIR'] = str(state)
        model_config = {'providers': {'contract': {'baseUrl': base, 'api': 'openai-completions',
            'apiKey': ('${' + key + '}' if runtime == 'pi' else key), 'models': [{'id': model, 'name': 'Contract Flash', 'reasoning': False,
                'input': ['text'], 'contextWindow': 65536, 'maxTokens': 512,
                'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}
        # YAML is a superset of JSON; this avoids a new parser dependency for OMP's models.yml.
        core.write_json(state / ('models.json' if runtime == 'pi' else 'models.yml'), model_config)
        model = 'contract/' + model
        arguments = ['--no-extensions', '--no-tools', '--no-skills', '--no-session', '--thinking', 'off']
        if runtime == 'omp':
            arguments += ['--no-lsp', '--max-time', '90']
    elif runtime == 'qodercli':
        arguments = ['--tools', '', '--max-output-tokens', '512', '--max-model-request-retries', '0',
                     '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--no-session-persistence']
    elif runtime == 'opencode':
        environment.update(XDG_CONFIG_HOME=str(state / 'config'), XDG_DATA_HOME=str(state / 'data'),
                           XDG_CACHE_HOME=str(state / 'cache'), XDG_STATE_HOME=str(state / 'runtime'),
                           OPENCODE_DISABLE_AUTOUPDATE='true', OPENCODE_DISABLE_DEFAULT_PLUGINS='true')
        environment['OPENCODE_CONFIG_CONTENT'] = json.dumps({
            'provider': {'contract': {'npm': '@ai-sdk/openai-compatible', 'name': 'Contract',
                'options': {'baseURL': base, 'apiKey': '{env:' + key + '}'},
                'models': {model: {'name': 'Contract Flash', 'limit': {'context': 65536, 'output': 512}}}}},
            'permission': {'*': 'deny'}, 'share': 'disabled', 'autoupdate': False,
        })
        model = 'contract/' + model
        arguments = ['--format', 'json']
    else:
        raise core.PolicyError('This runtime has no verified direct-provider configuration recipe.')
    return model, arguments, environment


def validate_export(exported, counts, nonce, requests):
    expected = [item['runtime'] for item in requests]
    try:
        valid = (type(exported['schema']) is int and exported['schema'] == 1
                 and isinstance(nonce, str) and bool(nonce) and exported['nonce'] == nonce and counts['result'] == 'Passed'
                 and all(type(counts[k]) is int and counts[k] == v for k, v in
                         [('totalTestCount', 1), ('passedTests', 1), ('failedTests', 0), ('skippedTests', 0)])
                 and [item['runtime'] for item in exported['launches']] == expected)
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise core.EvidenceError('Production launch export lacks a matching executed-test receipt.')


def export_launches(requests, directory, search_path, timeout):
    nonce = secrets.token_hex(16)
    source, receipt = directory / 'export-input.json', directory / 'export-output.json'
    result = directory / 'export.xcresult'
    core.write_json(source, requests)
    environment = core.probe_environment(os.environ, search_path)
    environment.update(PROWL_CONTRACT_EXPORT_INPUT=str(source), PROWL_CONTRACT_EXPORT_OUTPUT=str(receipt),
                       PROWL_CONTRACT_NONCE=nonce, PROWL_CONTRACT_RESULT=str(result))
    if os.environ.get('PROWL_DEVELOPMENT_TEAM'):
        environment['PROWL_DEVELOPMENT_TEAM'] = os.environ['PROWL_DEVELOPMENT_TEAM']
    process = core.run_process(['/usr/bin/make', '_test-agent-contract-export'], search_path, timeout, environment)
    write_text(directory / 'export-build.log', process.stdout + process.stderr)
    if process.timed_out or process.returncode != 0:
        raise core.EvidenceError('Production launch export build/test failed; inspect export-build.log.')
    summary = core.run_process(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                               '--path', str(result), '--compact'], search_path, 30)
    try:
        counts = json.loads(summary.stdout)
        exported = json.loads(receipt.read_text())
        validate_export(exported, counts, nonce, requests)
    except (OSError, ValueError, KeyError):
        raise core.EvidenceError('Production launch export lacks a matching executed-test receipt.') from None
    core.write_json(directory / 'export-test-summary.json', counts)
    return exported['launches'], nonce


def run_one(launch, request, row, environment, path, directory, timeout, expected):
    runtime = row['runtime']
    scope = request.get('scenario', 'headless')
    log_name = runtime + '-' + scope
    token = secrets.token_hex(24)
    child_environment = core.probe_environment(environment, path)
    child_environment.update(request['environment'])
    child_environment.update(launch['environment'])
    key_name = row['route']['api_key_env']
    key = environment.get(key_name, '') if key_name else ''
    if key_name:
        child_environment[key_name] = key
    if runtime == 'claude':
        child_environment['ANTHROPIC_AUTH_TOKEN'] = key
    if runtime == 'copilot':
        child_environment['COPILOT_PROVIDER_API_KEY'] = key
    started = time.monotonic()
    # Unix sockaddr_un on macOS is short; do not place sockets in long checkout paths.
    with tempfile.TemporaryDirectory(prefix='pwl-', dir='/tmp') as short:
        socket_path = Path(short) / 's'
        child_environment.update(PROWL_AGENT_HOOK_TOKEN=token, PROWL_CLI_SOCKET=str(socket_path))
        with Collector(socket_path, runtime, token, launch['cwd'], scope) as collector:
            with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
                process = subprocess.Popen([launch['executable'], *launch['arguments']],
                    cwd=launch['cwd'], env=child_environment, stdin=subprocess.DEVNULL,
                    stdout=stdout, stderr=stderr, start_new_session=True)
                timed_out = False
                try:
                    process.wait(timeout=timeout)
                    collector.complete.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    timed_out = True
                finally:
                    core.stop_group(process)
                stdout.seek(0)
                stderr.seek(0)
                out = stdout.read(core.MAX_CAPTURE_BYTES).decode('utf-8', errors='replace')
                err = stderr.read(core.MAX_CAPTURE_BYTES).decode('utf-8', errors='replace')
            response = verify_response(out, expected)
            if scope == 'zero-turn':
                reason = 'runtime_timeout' if timed_out else rules.zero_turn_result(
                    runtime, process.returncode, out, err, collector.events, launch['cwd'])
            else:
                reason = evaluate(process.returncode, timed_out, response, collector.terminal)
                if reason == 'verified':
                    reason = rules.validate_events(runtime, collector.events, launch['cwd'])
            if reason == 'verified' and collector.error:
                reason = 'capture_protocol_error'
            events = list(collector.events)
    # Raw stdout may echo prompt/config. Persist only after replacing known launch secrets.
    for value in (key, token):
        if value:
            out, err = out.replace(value, '[REDACTED]'), err.replace(value, '[REDACTED]')
    write_text(directory / (log_name + '-stdout.log'), out)
    write_text(directory / (log_name + '-stderr.log'), err)
    return {'status': 'passed' if reason == 'verified' else ('timed_out' if timed_out else 'contract_failed'),
            'reason': reason, 'response_verified': response, 'events': events,
            'exit_code': process.returncode, 'elapsed_seconds': round(time.monotonic() - started, 3),
            'scope': scope, 'cwd': launch['cwd'], 'response_expected': expected,
            'required_events': [list(pair) for pair in (rules.ZERO_TURN if scope == 'zero-turn' else rules.HEADLESS)[runtime]], 'stdout': str(directory / (log_name + '-stdout.log')),
            'stderr': str(directory / (log_name + '-stderr.log'))}


def run_suite(rows, directory, resolver, environment, timeout, build_timeout, verify=False):
    requests, selected = [], []
    with tempfile.TemporaryDirectory(prefix='prowl-contract-') as scratch:
        root = Path(scratch).resolve()
        resources = core.ROOT / 'Resources'
        for row in rows:
            row['live'] = {'status': 'blocked', 'reason': 'route_not_configured'}
            if row['runtime'] == 'qodercli' and row['route'].get('wire_api') != 'runtime-managed':
                row['live']['reason'] = 'custom_provider_requires_account_model_registration'
                continue
            if row['inventory']['status'] != 'passed':
                row['live']['reason'] = row['inventory']['reason']
                continue
            if row['route']['status'] != 'configured':
                row['live']['reason'] = row['route']['status']
                continue
            binary = resolver(row['runtime'])
            if not binary or binary.path != row['executable']:
                row['live']['reason'] = 'binary_changed'
                continue
            scopes = (['zero-turn', 'headless'] if verify and row['runtime'] in rules.ZERO_TURN else ['headless'])
            row['lifecycle'] = ({'status': 'not_run'} if row['runtime'] in rules.ZERO_TURN else
                                {'status': 'not_applicable', 'reason': rules.ZERO_TURN_UNSUPPORTED[row['runtime']]})
            for scope in scopes:
                workspace = root / (row['runtime'] + '-' + scope)
                workspace.mkdir(mode=0o700)
                try:
                    model, arguments, config = runtime_configuration(row['runtime'], row['route'], workspace)
                except core.PolicyError:
                    row['live']['reason'] = 'unsupported_live_route'
                    continue
                number = 10000 + secrets.randbelow(80000)
                answer = 'RESULT:' + str(number + 1739)
                prompt = (f'Compute {number} + 1739. Reply only RESULT: followed immediately by the decimal sum. Do not use tools.'
                          if scope == 'headless' else '')
                requests.append({'runtime': row['runtime'], 'executable': binary.path, 'workspace': str(workspace),
                    'resources': str(resources), 'model': model, 'arguments': arguments, 'scenario': scope,
                    'environment': {**config, 'HOME': str(Path.home())}, 'prompt': prompt})
                selected.append((row, binary.search_path, answer))
        if not requests:
            return
        try:
            launches, nonce = export_launches(requests, directory, selected[0][1], build_timeout)
        except core.EvidenceError as error:
            for row, _, _ in selected:
                row['live'] = {'status': 'blocked', 'reason': 'production_export_failed'}
            print(str(error), file=sys.stderr, flush=True)
            return
        for launch, request, (row, path, answer) in zip(launches, requests, selected):
            field = "lifecycle" if request["scenario"] == "zero-turn" else "live"
            if launch['status'] != 'prepared':
                row[field] = launch
                continue
            print(request['scenario'] + ' contract: ' + row['runtime'], file=sys.stderr, flush=True)
            try:
                row[field] = run_one(launch, request, row, environment, path, directory, timeout, answer)
            except OSError:
                row[field] = {'status': 'blocked', 'reason': 'runtime_or_capture_io_failed'}
            print(row['runtime'] + ': ' + row[field]['reason'], file=sys.stderr, flush=True)

        return nonce
