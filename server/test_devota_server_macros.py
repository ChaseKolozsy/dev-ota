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
            self.assertEqual(result["macros"][0]["priority"], 0)
            self.assertEqual(result["usageCounts"], {"macro-1": 2})
            self.assertTrue(devota_server.macros_path(repo).is_file())

    def test_creates_updates_and_deletes_macro(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)

            created = devota_server.create_macro(
                repo,
                {
                    "name": "Build check",
                    "priority": 4,
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
            self.assertEqual(created["item"]["priority"], 4)

            updated = devota_server.update_macro(
                repo,
                macro_id,
                {
                    "name": "Build and check",
                    "priority": 9,
                    "steps": [
                        {"type": "tmux", "value": "n", "delaySeconds": 0},
                    ],
                },
            )
            self.assertEqual(updated["item"]["name"], "Build and check")
            self.assertEqual(updated["item"]["priority"], 9)
            self.assertEqual(updated["item"]["steps"][0]["type"], "tmux")

            deleted = devota_server.delete_macro(repo, macro_id)
            self.assertEqual(deleted["deletedId"], macro_id)
            self.assertEqual(deleted["macros"], [])

    def test_stale_phone_sync_cannot_overwrite_server_macro(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            created = devota_server.create_macro(
                repo,
                {
                    "id": "macro-managed",
                    "name": "Canonical prompt",
                    "steps": [{"type": "shell", "value": "new prompt"}],
                },
            )
            original_updated_at = devota_server.list_macros(repo)["updatedAt"]

            synced = devota_server.sync_macros(
                repo,
                {
                    "macros": [
                        {
                            "id": "macro-managed",
                            "name": "Stale prompt",
                            "steps": [{"type": "shell", "value": "old 50-50 split"}],
                        }
                    ],
                    "usageCounts": {"macro-managed": 7},
                },
            )

            self.assertEqual(synced["syncMode"], "server_authoritative")
            self.assertEqual(synced["macros"], created["macros"])
            self.assertEqual(synced["macros"][0]["name"], "Canonical prompt")
            self.assertEqual(synced["macros"][0]["steps"][0]["value"], "new prompt")
            self.assertEqual(synced["usageCounts"], {"macro-managed": 7})
            self.assertEqual(synced["updatedAt"], original_updated_at)

    def test_phone_sync_can_add_new_macro_without_replacing_existing_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            devota_server.create_macro(
                repo,
                {
                    "id": "macro-managed",
                    "name": "Canonical",
                    "steps": [{"type": "shell", "value": "canonical"}],
                },
            )

            synced = devota_server.sync_macros(
                repo,
                {
                    "macros": [
                        {
                            "id": "macro-managed",
                            "name": "Stale",
                            "steps": [{"type": "shell", "value": "stale"}],
                        },
                        {
                            "id": "macro-from-phone",
                            "name": "New phone macro",
                            "steps": [{"type": "shell", "value": "new"}],
                        },
                    ],
                    "usageCounts": {"macro-from-phone": 2},
                },
            )

            self.assertEqual(
                [(item["id"], item["name"]) for item in synced["macros"]],
                [
                    ("macro-managed", "Canonical"),
                    ("macro-from-phone", "New phone macro"),
                ],
            )
            self.assertEqual(synced["usageCounts"], {"macro-from-phone": 2})

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
