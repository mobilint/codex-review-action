from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RenderPromptTests(unittest.TestCase):
    def test_auto_and_mention_templates_render_without_placeholders(self) -> None:
        for template_name in (
            "auto-review.md.tmpl",
            "mention-review.md.tmpl",
        ):
            with self.subTest(template=template_name):
                template = ROOT / "prompts" / template_name
                text = template.read_text(encoding="utf-8")
                keys = sorted(set(re.findall(r"\{\{([A-Z0-9_]+)\}\}", text)))
                with tempfile.TemporaryDirectory() as directory:
                    output = Path(directory) / "prompt.md"
                    command = [
                        "python3",
                        str(ROOT / "scripts" / "render-prompt.py"),
                        "--template",
                        str(template),
                        "--output",
                        str(output),
                    ]
                    for key in keys:
                        command.extend(("--var", f"{key}=fixture-{key.lower()}"))
                    result = subprocess.run(
                        command,
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    rendered = output.read_text(encoding="utf-8")
                self.assertNotRegex(rendered, r"\{\{[A-Z0-9_]+\}\}")
                self.assertIn("valid JSON only", rendered)


if __name__ == "__main__":
    unittest.main()
