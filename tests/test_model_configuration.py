from pathlib import Path
import json
import os
import subprocess
import tempfile
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
