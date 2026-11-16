from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'scripts/review-runtime.sh'


class ModelConfigurationTests(unittest.TestCase):
    def invoke(self, model: str, effort: str) -> tuple[list[str], str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'codex'
            executable.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            executable.chmod(0o755)
            result = subprocess.run(
                ['bash', '-c', 'source "$1"; MODEL="$2"; REASONING_EFFORT="$3"; '
                 'normalize_review_model_inputs; execute_review_codex --sandbox read-only "prompt text"',
                 'test', str(RUNTIME), model, effort],
                env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                capture_output=True, text=True, check=True,
            )
            return json.loads(result.stdout), result.stderr

    def test_defaults_and_explicit_values_reach_cli_as_single_arguments(self) -> None:
        for model, effort in [('', ''), ('gpt-6-luna', 'max'), ('gpt-6.1-sol', 'high')]:
            with self.subTest(model=model, effort=effort):
                args, err = self.invoke(model, effort)
                self.assertEqual(args, ['exec', '--ignore-user-config', '--model', model or 'gpt-6-luna',
                                       '-c', f'model_reasoning_effort="{effort or "max"}"',
                                       '--sandbox', 'read-only', 'prompt text'])
                self.assertEqual(err, '')

    def test_invalid_values_cannot_inject_flags_or_config(self) -> None:
        for model, effort in [('--dangerously-bypass-approvals-and-sandbox', 'max'),
                              ('x' * 129, 'max'), ('x y', 'high'),
                              ('$(touch /tmp/model-injection)', 'max'),
                              ('gpt-6-luna', 'max"\nnetwork_access=true')]:
            with self.subTest(model=model, effort=effort):
                args, err = self.invoke(model, effort)
                self.assertIn('invalid', err)
                self.assertEqual(args[args.index('--model') + 1],
                                 'gpt-6-luna')
                self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', args)
                if effort.startswith('max"'):
                    self.assertIn('model_reasoning_effort="max"', args)

    def test_both_execution_paths_use_the_validated_configuration(self) -> None:
        script = (ROOT / 'scripts/run-review.sh').read_text()
        self.assertEqual(script.count('execute_review_codex \\'), 2)
        self.assertIn('normalize_review_model_inputs', script)
        self.assertIn('GITHUB_STEP_SUMMARY', script)

    def test_canary_validates_exact_revision_before_runner_allocation(self) -> None:
        text = (ROOT / '.github/workflows/canary-review-action.yml').read_text()
        self.assertEqual(text.count("github.repository == 'mobilint/codex-review-action'"), 2)
        self.assertEqual(text.count('github.event.repository.default_branch'), 3)
        for fragment in ('needs: verify', '^[0-9a-f]{40}$', 'uses: ./candidate',
                         'ref: ${{ needs.verify.outputs.action_sha }}',
                         'persist-credentials: false', 'mode: [auto, mention]',
                         'allow_unsafe_no_sandbox_fallback: false'):
            self.assertIn(fragment, text)

    def test_canary_source_comment_passes_the_real_mention_parser(self) -> None:
        text = (ROOT / '.github/workflows/canary-review-action.yml').read_text()
        match = re.search(r"-f body='([^']*)'", text)
        self.assertIsNotNone(match)
        body = match.group(1)
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / 'comment.json'
            for candidate, expected in [(body, 0), (body.replace('@mobilint-review ', ''), 1)]:
                payload.write_text(json.dumps({'body': candidate}))
                result = subprocess.run(['python3', str(ROOT / 'scripts/comment-mentions.py'),
                                         '--input', str(payload)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_canary_preflight_has_no_write_scopes(self) -> None:
        text = (ROOT / '.github/workflows/canary-review-action.yml').read_text()
        verify = text.split('  verify:', 1)[1].split('  canary:', 1)[0]
        self.assertIn('permissions: {}', text.split('jobs:', 1)[0])
        self.assertNotIn(': write', verify)
        self.assertIn('contents: read', verify)
        self.assertIn('pull-requests: read', verify)
        canary = text.split('  canary:', 1)[1]
        self.assertIn('issues: write', canary)
        self.assertIn('pull-requests: write', canary)

    def test_canary_preflight_enforces_trusted_target_and_revision(self) -> None:
        text = (ROOT / '.github/workflows/canary-review-action.yml').read_text()
        script = textwrap.dedent(text.split('        run: |\n', 1)[1].split('\n  canary:', 1)[0])
        trusted = {
            'state': 'open', 'user': {'login': 'operator'},
            'head': {'repo': {'full_name': 'mobilint/codex-review-action'},
                     'ref': 'test/reviewer-release-canary'},
            'base': {'ref': 'main'},
        }
        cases = [(trusted, 'ahead', True), (trusted, 'identical', True),
                 (trusted, 'diverged', False), (trusted, 'behind', False)]
        for field, value in [('state', 'closed'), ('user', {'login': 'someone-else'}),
                             ('head', {'repo': {'full_name': 'attacker/fork'}, 'ref': 'test/reviewer-release-canary'}),
                             ('head', {'repo': {'full_name': 'mobilint/codex-review-action'}, 'ref': 'untrusted'}),
                             ('base', {'ref': 'other'})]:
            cases.append(({**trusted, field: value}, 'ahead', False))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'gh'
            fake.write_text('#!/usr/bin/python3\nimport json,os,sys\n'
                            'print(json.dumps({"base_commit":{"sha":os.environ["ACTION_SHA"]},'
                            '"status":os.environ["COMPARISON_STATUS"]}) if "/compare/" in sys.argv[2] '
                            'else os.environ["TARGET_JSON"])\n')
            fake.chmod(0o755)
            for target, status, allowed in cases:
                with self.subTest(target=target, status=status):
                    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                        env={**os.environ, 'PATH': directory + ':' + os.environ['PATH'],
                             'ACTION_SHA': 'a' * 40, 'PR_NUMBER': '18', 'OPERATOR': 'operator',
                             'GITHUB_REPOSITORY': 'mobilint/codex-review-action',
                             'DEFAULT_BRANCH': 'main', 'GITHUB_OUTPUT': str(root / 'output'),
                             'TARGET_JSON': json.dumps(target), 'COMPARISON_STATUS': status})
                    self.assertEqual(result.returncode == 0, allowed, result.stderr)

    def test_canary_checkout_is_an_immutable_v6_revision(self) -> None:
        text = (ROOT / '.github/workflows/canary-review-action.yml').read_text()
        self.assertIn('actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6', text)
        self.assertNotIn('actions/checkout@v6', text)
