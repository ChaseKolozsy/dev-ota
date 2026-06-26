import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SERVER_PATH = Path(__file__).with_name("devota_server.py")
SPEC = importlib.util.spec_from_file_location("devota_server", SERVER_PATH)
devota_server = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(devota_server)


class MacroStoreTests(unittest.TestCase):
    def test_bootstraps_macros_from_profile_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            backup = {
                "format": "devota-backup",
                "version": 1,
                "sharedPreferences": {
                    "macros_json": json.dumps(
                        [
                            {
                                "id": "macro-1",
                                "name": "hello",
                                "steps": [
                                    {
                                        "id": "step-1",
                                        "type": "shell",
                                        "value": "say hello",
                                        "delaySeconds": 0.5,
                                    }
                                ],
                            }
                        ]
                    ),
                    "macro_usage_counts_json": json.dumps({"macro-1": 2}),
                },
            }
            devota_server.write_profile_backup(repo, backup)

            result = devota_server.list_macros(repo)

            self.assertEqual(result["status"], "ok")
            self.assertEqual(result["macros"][0]["name"], "hello")
            self.assertEqual(result["usageCounts"], {"macro-1": 2})
            self.assertTrue(devota_server.macros_path(repo).is_file())

    def test_creates_updates_and_deletes_macro(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)

            created = devota_server.create_macro(
                repo,
                {
                    "name": "Build check",
                    "steps": [
                        {
                            "type": "shell",
                            "value": "flutter test",
                            "delaySeconds": 0.25,
                        }
                    ],
                },
            )
            macro_id = created["item"]["id"]
            self.assertEqual(created["item"]["name"], "Build check")

            updated = devota_server.update_macro(
                repo,
                macro_id,
                {
                    "name": "Build and check",
                    "steps": [
                        {"type": "tmux", "value": "n", "delaySeconds": 0},
                    ],
                },
            )
            self.assertEqual(updated["item"]["name"], "Build and check")
            self.assertEqual(updated["item"]["steps"][0]["type"], "tmux")

            deleted = devota_server.delete_macro(repo, macro_id)
            self.assertEqual(deleted["deletedId"], macro_id)
            self.assertEqual(deleted["macros"], [])

    def test_rejects_unknown_macro_step_type(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            with self.assertRaises(ValueError):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Bad macro",
                        "steps": [{"type": "not-real", "value": ""}],
                    },
                )


if __name__ == "__main__":
    unittest.main()
