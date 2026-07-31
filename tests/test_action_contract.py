from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def parse_action_inputs(text: str) -> dict[str, dict[str, object]]:
    """Parse the deliberately simple top-level action input mapping."""
    inputs_text = text[text.index("inputs:\n") : text.index("\nruns:\n")]
    matches = list(re.finditer(r"^  ([a-z0-9_]+):\n", inputs_text, re.M))
    inputs: dict[str, dict[str, object]] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(inputs_text)
        block = inputs_text[match.end() : end]
        required_match = re.search(r'^    required: (true|false)$', block, re.M)
        if required_match is None:
            raise AssertionError(f"{match.group(1)} is missing required")
        entry: dict[str, object] = {
            "required": required_match.group(1) == "true"
        }
        default_match = re.search(r'^    default: "(.*)"$', block, re.M)
        if default_match is not None:
            entry["default"] = default_match.group(1)
        inputs[match.group(1)] = entry
    return inputs


class ActionContractTests(unittest.TestCase):
    def test_action_manifest_matches_shared_contract(self) -> None:
        contract = json.loads(
            (ROOT / "config" / "codex-review-action-contract.json").read_text(
                encoding="utf-8"
            )
        )
        actual = parse_action_inputs(
            (ROOT / "action.yml").read_text(encoding="utf-8")
        )
        self.assertEqual(actual, contract["action_inputs"])

    def test_composite_step_forwards_every_public_input(self) -> None:
        text = (ROOT / "action.yml").read_text(encoding="utf-8")
        contract = json.loads(
            (ROOT / "config" / "codex-review-action-contract.json").read_text(
                encoding="utf-8"
            )
        )
        for name in contract["action_inputs"]:
            self.assertRegex(
                text,
                rf"INPUT_{name.upper()}: \$\{{\{{ inputs\.{re.escape(name)} \}}\}}",
            )


if __name__ == "__main__":
    unittest.main()
