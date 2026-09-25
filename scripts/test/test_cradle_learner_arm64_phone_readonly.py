import importlib.util
import json
import sys
import unittest
from pathlib import Path


HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent.parent / "server"))
import devota_server  # noqa: E402


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


macro = load_script("cradle-learner-arm64-phone-readonly.py")
memory = load_script("cradle-learner-arm64-memory-observer.py")


class Arm64PhoneMacroTest(unittest.TestCase):
    def test_normalized_macro_contains_only_read_only_actions(self):
        rendered = macro.render("https://peer.example", "owned-book", "Owned title",
                                "occ:1", "bank", "JEV first choice")
        normalized = devota_server.normalize_macro(rendered)
        actions = [json.loads(step["value"]) for step in normalized["steps"]]
        self.assertEqual(actions[0]["args"]["models"], ["TMRV07P5G"])
        self.assertEqual([step["action"] for step in actions], [
            "assertDeviceProfile", "launchApp", "launchIntent", "assertUi",
            "launchIntent", "assertUi", "tapUi", "assertUi",
        ])
        self.assertFalse(any(step["action"] == "humanCheckpoint" for step in actions))
        self.assertEqual(actions[3]["expect"]["textIncludes"][0], "https://peer.example")
        self.assertEqual(actions[6]["args"]["selector"],
                         {"contentDescriptionExact": "bank"})

    def test_bad_fixture_arguments_fail_closed(self):
        for peer, book in [("http://127.0.0.1:18003/path", "owned-book"),
                           ("https://peer.example", "../wrong-book")]:
            with self.assertRaises(ValueError):
                macro.render(peer, book, "Title", "occ:1", "bank", "Ready")

    def test_meminfo_parser_returns_only_observed_pss(self):
        self.assertEqual(memory.pss_kib("TOTAL PSS: 138,153\nTOTAL RSS: 229968\n"), 138153)
        self.assertEqual(memory.pss_kib("  TOTAL  42  1  0\n"), 42)
        self.assertIsNone(memory.pss_kib("No process found"))


if __name__ == "__main__":
    unittest.main()
