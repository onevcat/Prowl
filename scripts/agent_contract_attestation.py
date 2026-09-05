"""Explicit, scoped publication of a fresh local verify report; never calls a model."""
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

import agent_contracts as core
import agent_contract_expectations as rules
import agent_contract_live as live
import agent_versions as versions


def require(condition, message):
    if not condition:
        raise core.EvidenceError(message)


def read_json(path):
    try:
        with path.open("rb") as stream:
            data = stream.read(4 * 1024 * 1024 + 1)
        require(len(data) <= 4 * 1024 * 1024, 'Evidence JSON exceeds its size limit.')
        return json.loads(data, object_pairs_hook=core.unique_object)
    except core.EvidenceError:
        raise
    except (OSError, ValueError):
        raise core.EvidenceError('Cannot read valid evidence JSON.') from None


def validate_eligibility(report, fingerprint, bridge_hash, now):
    try:
        require(type(report['schema']) is int and report['schema'] == 1 and report['contract_revision'] == rules.REVISION
                and report['mode'] == 'verify', 'Only current-revision verify reports can be published.')
        require(report['contract_passed'] is True and report['source_stable'] is True,
                'The report is not a complete successful contract run.')
        require(report['source_fingerprint'] == report['started_source_fingerprint'] == fingerprint
                and report['bridge_sha256'] == bridge_hash, 'Source or bundled bridge changed; rerun verify.')
        start = datetime.datetime.fromisoformat(report['started_at'])
        end = datetime.datetime.fromisoformat(report['created_at'])
        require(start.tzinfo is not None and end.tzinfo is not None, 'Evidence timestamps require a timezone.')
        require(now - datetime.timedelta(hours=24) <= start <= end <= now + datetime.timedelta(minutes=5),
                'Evidence is older than 24 hours or has invalid future timestamps; rerun verify.')
        rows = report['runtimes']
        names = [row['runtime'] for row in rows]
        require(bool(names) and len(names) == len(set(names)) and set(names) <= set(rules.HEADLESS),
                'Evidence requires distinct supported runtimes.')
        require(core.verify_passed(rows), 'A required scenario failed or was not run.')
    except core.EvidenceError:
        raise
    except (KeyError, TypeError, ValueError):
        raise core.EvidenceError('Malformed verification report.') from None


def validate_current(report, current, policy):
    for row in report['runtimes']:
        runtime = row['runtime']
        actual = current.get(runtime, {})
        require(row.get('inventory', {}).get('status') == 'passed'
                and actual.get('inventory', {}).get('status') == 'passed', 'Runtime inventory is not usable.')
        require(all(row.get(key) == actual.get(key) and row.get(key) for key in
                    ('installed_version', 'executable', 'executable_sha256')), 'Runtime binary/version changed; rerun verify.')
        expected_route = policy.get(runtime)
        require(expected_route is not None and all(row['route'].get(k) == v for k, v in expected_route.items()),
                'Selected model route changed; rerun verify.')


def artifact(report, directory, name):
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.-]+', name) is not None
            and name not in ('.', '..'), 'Invalid evidence artifact name.')
    path = directory / name
    require(not path.is_symlink() and path.is_file(), 'Evidence artifact is missing or a symlink.')
    require(report.get('artifacts', {}).get(name) == core.file_hash(path), 'Evidence artifact changed after verification.')
    return path


def validate_artifacts(report, directory):
    require(isinstance(report.get('artifacts'), dict) and bool(report['artifacts']), 'Missing artifact manifest.')
    for name in report['artifacts']:
        artifact(report, directory, name)
    requests = read_json(artifact(report, directory, 'export-input.json'))
    exported = read_json(artifact(report, directory, 'export-output.json'))
    counts = read_json(artifact(report, directory, 'export-test-summary.json'))
    live.validate_export(exported, counts, report.get('export_nonce'), requests)
    expected_pairs = [(row['runtime'], scope) for row in report['runtimes']
                      for scope in (['zero-turn', 'headless'] if row['runtime'] in rules.ZERO_TURN else ['headless'])]
    require([(r['runtime'], r.get('scenario')) for r in requests] == expected_pairs,
            'Exported scenarios do not match the report runtimes.')
    for request, launch in zip(requests, exported['launches']):
        require(launch.get('status') == 'prepared' and launch.get('executable') == request['executable']
                and rules.same_directory(launch.get('cwd'), request['workspace']), 'Prepared launch evidence does not match.')
    for row in report['runtimes']:
        runtime = row['runtime']
        for field, scope in [('live', 'headless')] + ([('lifecycle', 'zero-turn')] if runtime in rules.ZERO_TURN else []):
            evidence = row[field]
            stdout = artifact(report, directory, runtime + '-' + scope + '-stdout.log').read_text()
            stderr = artifact(report, directory, runtime + '-' + scope + '-stderr.log').read_text()
            request = next(r for r in requests if r['runtime'] == runtime and r['scenario'] == scope)
            require(evidence.get('scope') == scope and rules.same_directory(evidence.get('cwd'), request['workspace'])
                    and request['executable'] == row['executable'], 'Scenario launch identity mismatch.')
            required = (rules.ZERO_TURN if scope == 'zero-turn' else rules.HEADLESS)[runtime]
            require(evidence.get('required_events') == [list(pair) for pair in required], 'Required event set changed.')
            require(rules.validate_events(runtime, evidence.get('events'), evidence['cwd'], scope) == 'verified',
                    'Required native events, mappings, session identity, or order are invalid.')
            if scope == 'headless':
                challenge = re.fullmatch(r'Compute ([0-9]+) \+ 1739\. Reply only RESULT: followed immediately by the decimal sum\. Do not use tools\.', request['prompt'])
                require(challenge is not None, 'The model challenge is missing.')
                expected = 'RESULT:' + str(int(challenge[1]) + 1739)
                require(evidence.get('response_expected') == expected and evidence.get('exit_code') == 0
                        and live.verify_response(stdout, expected), 'The successful model response is not proven.')
            else:
                require(request['prompt'] == '' and rules.zero_turn_result(runtime, evidence.get('exit_code'),
                        stdout, stderr, evidence['events'], evidence['cwd']) == 'verified', 'Zero-turn lifecycle evidence failed.')
        if runtime == 'codex':
            preflight = row['preflight']
            require(preflight.get('scenarios') == list(core.CODEX_SCENARIOS)
                    and preflight.get('executed_tests') == 1, 'Required configuration scenarios are incomplete.')
            core.validate_preflight(read_json(artifact(report, directory, 'codex-preflight.json')),
                read_json(artifact(report, directory, 'codex-test-summary.json')), preflight.get('nonce'), row['executable'])


def encode(document):
    return (json.dumps(document, indent=2, sort_keys=True) + '\n').encode()


def replace_file(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix='.contract-', dir=path.parent)
    try:
        os.fchmod(descriptor, (path.stat().st_mode & 0o777) if path.exists() else 0o644)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_publication(report, baseline_path, matrix_path):
    baseline = read_json(baseline_path)
    require(baseline.get('schema') == 1, 'Unsupported baseline schema.')
    existing = versions.load_attestation(baseline_path)
    require({r.runtime for r in existing} == set(rules.HEADLESS), 'Baseline runtime set is incomplete.')
    # Publish only a whitelist: no transcripts, local paths, account credentials, or hook tokens.
    receipt = {'schema': 1, 'scope': 'headless-contract', 'contract_revision': rules.REVISION,
               'checked_on': report['created_at'], 'source_fingerprint': report['source_fingerprint'],
               'bridge_sha256': report['bridge_sha256'], 'interactive_verified': False, 'runtimes': []}
    for row in report['runtimes']:
        scenarios = {'headless': {'status': 'passed', 'required_events': row['live']['required_events']},
                     'zero_turn_lifecycle': ({'status': 'passed', 'required_events': row['lifecycle']['required_events']}
                                            if row['runtime'] in rules.ZERO_TURN else
                                            {'status': 'not_applicable', 'reason': rules.ZERO_TURN_UNSUPPORTED[row['runtime']]})}
        if row['runtime'] == 'codex':
            scenarios['configuration'] = {'status': 'passed', 'scenarios': list(core.CODEX_SCENARIOS)}
        receipt['runtimes'].append({'runtime': row['runtime'], 'version': row['installed_version'],
            'executable_sha256': row['executable_sha256'], 'route': {k: row['route'][k] for k in sorted(core.ROUTE_KEYS)},
            'scenarios': scenarios})
    data = encode(receipt)
    relative = 'attestations/' + hashlib.sha256(data).hexdigest() + '.json'
    receipt_path = baseline_path.parent / relative
    selected = {row['runtime']: row for row in report['runtimes']}
    for row in baseline['runtimes']:
        if row['runtime'] in selected:
            row.update(attested_version=selected[row['runtime']]['installed_version'],
                       attested_on=report['created_at'][:10], record=relative)
    baseline['description'] = ('Managed-hook version baseline. Each linked record states its tested scope; headless '
        'verification does not imply GUI or interactive coverage. The original interactive baseline is preserved in '
        'agent-attestation-interactive.json. See agent-contracts-runbook.md for explicit verification/publication.')
    entries = [versions.AttestedRuntime.from_json(row) for row in baseline['runtimes']]
    lines = matrix_path.read_text().split('\n')
    indexes = [i for i, line in enumerate(lines) if line.startswith(versions.MATRIX_LINE_PREFIX)]
    require(len(indexes) == 1, 'Research matrix must contain exactly one generated baseline line.')
    lines[indexes[0]] = versions.render_matrix_line(entries)
    snapshot = baseline_path.parent / 'agent-attestation-interactive.json'
    require(snapshot.is_file(), 'The legacy interactive baseline must be preserved before publication.')
    if receipt_path.exists():
        require(not receipt_path.is_symlink() and receipt_path.read_bytes() == data, 'Immutable receipt collision.')
    writes = {receipt_path: data, baseline_path: encode(baseline), matrix_path: '\n'.join(lines).encode()}
    original = {path: path.read_bytes() if path.exists() else None for path in writes}
    receipt_path.parent.mkdir(exist_ok=True)
    changed = []
    try:
        for path, content in writes.items():
            if original[path] != content:
                replace_file(path, content)
                changed.append(path)
    except OSError:
        for path in reversed(changed):
            if original[path] is None:
                path.unlink()
            else:
                replace_file(path, original[path])
        raise core.EvidenceError('Publication write failed; completed writes were rolled back.') from None
    return {'record': str(receipt_path), 'updated_runtimes': sorted(selected), 'scope': receipt['scope']}


def _publish(report_path, policy):
    report_path = report_path.absolute()
    report = read_json(report_path)
    require(isinstance(report, dict) and report.get("contract_revision") == rules.REVISION
            and report.get("mode") == "verify", "Only current-revision verify reports can be published.")
    validate_eligibility(report, core.source_fingerprint(), core.file_hash(core.ROOT / 'Resources/prowl-cli/prowl'),
                         datetime.datetime.now(datetime.timezone.utc))
    validate_artifacts(report, report_path.parent)
    bundles = [('export.xcresult', 'export-test-summary.json')]
    if any(row['runtime'] == 'codex' for row in report['runtimes']):
        bundles.append(('codex-preflight.xcresult', 'codex-test-summary.json'))
    for bundle, summary in bundles:
        path = report_path.parent / bundle
        require(path.is_dir() and not path.is_symlink(), 'The original Xcode result bundle is missing.')
        result = core.run_process(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                  '--path', str(path), '--compact'], os.environ.get('PATH', '/usr/bin:/bin'), 30)
        require(result.returncode == 0 and json.loads(result.stdout) == read_json(report_path.parent / summary),
                'The original Xcode result bundle does not match its recorded summary.')
    entries = [r for r in versions.load_attestation(versions.ATTESTATION_PATH)
               if r.runtime in {row['runtime'] for row in report['runtimes']}]
    current = core.inventory(entries, {}, {})
    for row in current:
        if row['executable']:
            row['executable_sha256'] = core.file_hash(Path(row['executable']))
    validate_current(report, {row['runtime']: row for row in current}, policy)
    return write_publication(report, versions.ATTESTATION_PATH, versions.MATRIX_PATH)


def publish(report_path, policy):
    try:
        return _publish(report_path, policy)
    except core.EvidenceError:
        raise
    except (OSError, KeyError, TypeError, ValueError, AttributeError):
        raise core.EvidenceError('Cannot publish incomplete or malformed evidence; baseline not advanced.') from None
