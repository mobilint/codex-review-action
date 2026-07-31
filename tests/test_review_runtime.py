from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "scripts" / "review-runtime.sh"


class ReviewRuntimeTests(unittest.TestCase):
    def normalize(
        self,
        *,
        max_files: str = "500",
        max_diff_chars: str = "1000000",
        sandbox_mode: str = "read-only",
        unsafe_fallback: str = "false",
    ) -> subprocess.CompletedProcess[str]:
        script = """
source "$1"
MAX_FILES="$2"
MAX_DIFF_CHARS="$3"
SANDBOX_MODE="$4"
ALLOW_UNSAFE_NO_SANDBOX_FALLBACK="$5"
normalize_review_runtime_inputs
printf '%s|%s|%s|%s\n' \
  "$MAX_FILES" \
  "$MAX_DIFF_CHARS" \
  "$SANDBOX_MODE" \
  "$ALLOW_UNSAFE_NO_SANDBOX_FALLBACK"
"""
        return subprocess.run(
            (
                "bash",
                "-c",
                script,
                "runtime-test",
                str(RUNTIME),
                max_files,
                max_diff_chars,
                sandbox_mode,
                unsafe_fallback,
            ),
            check=False,
            capture_output=True,
            text=True,
        )

    def test_valid_values_are_preserved(self) -> None:
        result = self.normalize(
            max_files="750",
            max_diff_chars="2000000",
            sandbox_mode="workspace-write",
            unsafe_fallback="true",
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "750|2000000|workspace-write|true")

    def test_invalid_and_unbounded_values_fail_safe(self) -> None:
        cases = (
            ("0", "0", "invalid", "yes"),
            ("-1", "-1", "invalid", "1"),
            ("5001", "5000001", "invalid", "TRUE"),
            ("999999999999999999999999", "999999999999999999999999", "invalid", "yes"),
            ("1;echo injected", "nan", "invalid", "$(id)"),
        )
        for max_files, max_diff, sandbox, fallback in cases:
            with self.subTest(max_files=max_files, max_diff=max_diff):
                result = self.normalize(
                    max_files=max_files,
                    max_diff_chars=max_diff,
                    sandbox_mode=sandbox,
                    unsafe_fallback=fallback,
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(
                    result.stdout.strip(),
                    "500|1000000|read-only|false",
                )
                self.assertNotIn("injected", result.stdout)

    def test_sandbox_fallback_matcher_is_narrow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "probe.log"
            log.write_text("could not find bubblewrap\n", encoding="utf-8")
            accepted = subprocess.run(
                (
                    "bash",
                    "-c",
                    'source "$1"; is_codex_sandbox_startup_error "$2"',
                    "runtime-test",
                    str(RUNTIME),
                    str(log),
                ),
                check=False,
            )
            log.write_text("arbitrary Codex failure\n", encoding="utf-8")
            rejected = subprocess.run(
                (
                    "bash",
                    "-c",
                    'source "$1"; is_codex_sandbox_startup_error "$2"',
                    "runtime-test",
                    str(RUNTIME),
                    str(log),
                ),
                check=False,
            )
        self.assertEqual(accepted.returncode, 0)
        self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main()
