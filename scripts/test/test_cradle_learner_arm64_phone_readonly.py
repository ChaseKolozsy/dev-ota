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
OBSERVED = {"model": "REVVL V+ 5G", "android_sdk": 31,
            "short_side_px": 720, "long_side_px": 1600, "density_dpi": 320}
VISIBLE = {"sync_block_text": "Full sync is blocked for this library.",
           "sync_now_text": "Sync now", "choose_languages_text": "Choose languages",
           }


class Arm64PhoneMacroTest(unittest.TestCase):
    def test_normalized_macro_contains_only_read_only_actions(self):
        rendered = macro.render("https://peer.example", "owned-book", "Owned title",
                                "occ:1", "bank", "JEV first choice",
                                **OBSERVED, **VISIBLE)
        normalized = devota_server.normalize_macro(rendered)
        actions = [json.loads(step["value"]) for step in normalized["steps"]]
        self.assertEqual(actions[0]["args"], {
            "profile": actions[0]["args"]["profile"],
            "models": ["REVVL V+ 5G"], "androidSdk": 31,
            "shortSidePx": 720, "longSidePx": 1600, "densityDpi": 320,
        })
        self.assertEqual([step["action"] for step in actions], [
            "assertDeviceProfile", "launchApp", "launchIntent", "assertUi",
            "launchIntent", "assertUi", "tapUi", "assertUi",
        ])
        self.assertFalse(any(step["action"] == "humanCheckpoint" for step in actions))
        self.assertEqual(actions[3]["expect"]["textIncludes"], [
            "https://peer.example", "Full sync is blocked for this library.",
            "Sync now", "Choose languages",
        ])
        self.assertEqual(actions[6]["args"]["selector"],
                         {"contentDescriptionExact": "bank"})

    def test_bad_fixture_arguments_fail_closed(self):
        for peer, book in [("http://127.0.0.1:18003/path", "owned-book"),
                           ("https://peer.example", "../wrong-book")]:
            with self.assertRaises(ValueError):
                macro.render(peer, book, "Title", "occ:1", "bank", "Ready",
                             **OBSERVED, **VISIBLE)

    def test_profile_is_required_exact_and_part_of_macro_identity(self):
        args = ("https://peer.example", "owned-book", "Owned title",
                "occ:1", "bank", "Ready")
        first = macro.render(*args, **OBSERVED, **VISIBLE)
        second = macro.render(*args, **{**OBSERVED, "density_dpi": 321}, **VISIBLE)
        self.assertNotEqual(first["id"], second["id"])
        for invalid in (
            {"model": "*"}, {"model": " REVVL V+ 5G"},
            {"android_sdk": True}, {"android_sdk": 0},
            {"short_side_px": 1601}, {"long_side_px": 0},
            {"density_dpi": 0},
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                macro.render(*args, **{**OBSERVED, **invalid}, **VISIBLE)
        with self.assertRaises(ValueError):
            macro.render(*args, **OBSERVED,
                         **{**VISIBLE, "sync_block_text": "wrong\nmessage"})
        translated = macro.render(*args, **OBSERVED,
                                  **{**VISIBLE, "sync_block_text": "A teljes szinkron nem érhető el."})
        self.assertNotEqual(first["id"], translated["id"])

    def test_meminfo_parser_returns_only_observed_pss(self):
        self.assertEqual(memory.pss_kib("TOTAL PSS: 138,153\nTOTAL RSS: 229968\n"), 138153)
        self.assertEqual(memory.pss_kib("  TOTAL  42  1  0\n"), 42)
        self.assertIsNone(memory.pss_kib("No process found"))


if __name__ == "__main__":
    unittest.main()
