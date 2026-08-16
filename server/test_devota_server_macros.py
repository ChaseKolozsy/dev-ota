import importlib.util
import base64
import json
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

from PIL import Image


SERVER_PATH = Path(__file__).with_name("devota_server.py")
SPEC = importlib.util.spec_from_file_location("devota_server", SERVER_PATH)
devota_server = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(devota_server)


class MacroStoreTests(unittest.TestCase):
    @staticmethod
    def image_template():
        output = BytesIO()
        Image.new("RGB", (32, 24), "navy").save(output, format="PNG")
        return {
            "format": "devota-image-template",
            "version": 1,
            "pngBase64": base64.b64encode(output.getvalue()).decode("ascii"),
            "width": 32,
            "height": 24,
            "sourceWidth": 1080,
            "sourceHeight": 2400,
            "expectedCenterX": 0.5,
            "expectedCenterY": 0.5,
            "clickOffsetX": 0.5,
            "clickOffsetY": 0.5,
            "searchRadiusX": 0.42,
            "searchRadiusY": 0.42,
            "threshold": 0.84,
        }

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

            local_http = devota_server.create_macro(
                repo,
                {
                    "name": "Local lock assertion",
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps(
                                {
                                    "action": "localHttpAssert",
                                    "args": {
                                        "url": "http://127.0.0.1:8002/license?lang=en",
                                        "expectedStatus": 200,
                                        "jsonPathEquals": {"licensed": False},
                                        "jsonPaths": ["licensed"],
                                        "retryUntilSeconds": 1800,
                                        "retryIntervalSeconds": 2,
                                        "captureIntervalSeconds": 30,
                                    },
                                }
                            ),
                        }
                    ],
                },
            )
            self.assertEqual(
                json.loads(local_http["item"]["steps"][0]["value"])["action"],
                "localHttpAssert",
            )
            local_args = json.loads(local_http["item"]["steps"][0]["value"])["args"]
            self.assertEqual(local_args["retryUntilSeconds"], 1800)
            for unsafe_url in (
                "https://example.com/private",
                "http://10.0.2.2:8002/license",
            ):
                with self.assertRaises(ValueError):
                    devota_server.create_macro(
                        repo,
                        {
                            "name": "Unsafe local request",
                            "steps": [
                                {
                                    "type": "device",
                                    "value": json.dumps(
                                        {
                                            "action": "localHttpAssert",
                                            "args": {
                                                "url": unsafe_url,
                                                "expectedStatus": 200,
                                            },
                                        }
                                    ),
                                }
                            ],
                        },
                    )

    def test_device_macro_is_validated_and_canonicalized(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            created = devota_server.create_macro(
                repo,
                {
                    "name": "Visible settings proof",
                    "priority": 100,
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps(
                                {
                                    "action": "openSettings",
                                    "args": {},
                                    "expect": {"activePackage": "com.android.settings"},
                                }
                            ),
                        }
                    ],
                },
            )
            step = created["item"]["steps"][0]
            self.assertEqual(step["type"], "device")
            self.assertEqual(json.loads(step["value"])["action"], "openSettings")
            self.assertEqual(devota_server.list_macros(repo)["version"], 3)

            with self.assertRaises(ValueError):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Unsafe",
                        "steps": [
                            {
                                "type": "device",
                                "value": '{"action":"runArbitraryShell"}',
                            }
                        ],
                    },
                )

    def test_image_tap_templates_are_bounded_and_validated(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            template = self.image_template()
            created = devota_server.create_macro(
                repo,
                {
                    "name": "Portable visual tap",
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps(
                                {
                                    "action": "tapUi",
                                    "args": {
                                        "selector": {"text": "Install"},
                                        "imageFallback": template,
                                    },
                                }
                            ),
                        },
                        {
                            "type": "device",
                            "value": json.dumps(
                                {"action": "tapImage", "args": {"template": template}}
                            ),
                        },
                    ],
                },
            )
            self.assertEqual(len(created["item"]["steps"]), 2)

            invalid = dict(template)
            invalid["width"] = 31
            with self.assertRaisesRegex(ValueError, "dimensions do not match"):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Invalid template",
                        "steps": [
                            {
                                "type": "device",
                                "value": json.dumps(
                                    {"action": "tapImage", "args": {"template": invalid}}
                                ),
                            }
                        ],
                    },
                )

    def test_device_profile_requires_a_real_hardware_constraint(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            created = devota_server.create_macro(
                repo,
                {
                    "name": "REVVL 7 profile gate",
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps(
                                {
                                    "action": "assertDeviceProfile",
                                    "args": {
                                        "profile": "revvl7pro-android36-1080x2436",
                                        "models": ["TMRV07P5G", "sdk_gphone64_x86_64"],
                                        "androidSdk": 36,
                                        "shortSidePx": 1080,
                                        "longSidePx": 2436,
                                        "densityDpi": 480,
                                    },
                                }
                            ),
                        }
                    ],
                },
            )
            self.assertEqual(
                json.loads(created["item"]["steps"][0]["value"])["action"],
                "assertDeviceProfile",
            )
            with self.assertRaises(ValueError):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Label-only profile",
                        "steps": [
                            {
                                "type": "device",
                                "value": json.dumps(
                                    {
                                        "action": "assertDeviceProfile",
                                        "args": {"profile": "not-a-gate"},
                                    }
                                ),
                            }
                        ],
                    },
                )

    def test_failure_diagnostics_are_bounded_and_loopback_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            created = devota_server.create_macro(
                repo,
                {
                    "name": "Observe after failure",
                    "failureDiagnostics": {
                        "durationSeconds": 1800,
                        "intervalSeconds": 60,
                        "probes": [
                            {
                                "url": "http://127.0.0.1:8002/market-client/install-status?sku=hu-v2",
                                "expectedStatus": 200,
                                "timeoutSeconds": 10,
                                "jsonPaths": ["phase", "bytes_done", "bytes_total"],
                            }
                        ],
                    },
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps({"action": "openSettings"}),
                        }
                    ],
                },
            )
            diagnostics = created["item"]["failureDiagnostics"]
            self.assertEqual(diagnostics["durationSeconds"], 1800)
            self.assertEqual(diagnostics["intervalSeconds"], 60)
            self.assertTrue(diagnostics["captureScreenshot"])
            self.assertTrue(diagnostics["captureUi"])

            with self.assertRaisesRegex(ValueError, "loopback"):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Unsafe observer",
                        "failureDiagnostics": {
                            "durationSeconds": 60,
                            "intervalSeconds": 30,
                            "probes": [
                                {
                                    "url": "https://example.com/private",
                                    "expectedStatus": 200,
                                }
                            ],
                        },
                        "steps": [
                            {
                                "type": "device",
                                "value": json.dumps({"action": "openSettings"}),
                            }
                        ],
                    },
                )

            with self.assertRaisesRegex(ValueError, "at most 120"):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Unbounded observer",
                        "failureDiagnostics": {
                            "durationSeconds": 3600,
                            "intervalSeconds": 2,
                        },
                        "steps": [
                            {
                                "type": "device",
                                "value": json.dumps({"action": "openSettings"}),
                            }
                        ],
                    },
                )

    def test_human_checkpoint_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            human = devota_server.create_macro(
                repo,
                {
                    "name": "Timed human check",
                    "steps": [
                        {
                            "type": "device",
                            "value": json.dumps(
                                {
                                    "action": "humanCheckpoint",
                                    "args": {
                                        "countdownSeconds": 10,
                                        "durationSeconds": 12,
                                        "screenshotsPerSecond": 2,
                                    },
                                }
                            ),
                        }
                    ],
                },
            )
            self.assertEqual(
                json.loads(human["item"]["steps"][0]["value"])["action"],
                "humanCheckpoint",
            )
            with self.assertRaises(ValueError):
                devota_server.create_macro(
                    repo,
                    {
                        "name": "Too many frames",
                        "steps": [
                            {
                                "type": "device",
                                "value": json.dumps(
                                    {
                                        "action": "humanCheckpoint",
                                        "args": {
                                            "durationSeconds": 120,
                                            "screenshotsPerSecond": 5,
                                        },
                                    }
                                ),
                            }
                        ],
                    },
                )

    def test_macro_run_persists_private_step_evidence_and_gallery(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            png = b"\x89PNG\r\n\x1a\nminimal-test-payload"
            result = devota_server.record_macro_run_step(
                repo,
                "run-device-proof",
                {
                    "macroId": "macro-device-proof",
                    "macroName": "Device proof",
                    "stepIndex": 1,
                    "stepCount": 1,
                    "stepId": "step-1",
                    "name": "open settings",
                    "action": "openSettings",
                    "startedAt": "2026-08-15T00:00:00Z",
                    "completedAt": "2026-08-15T00:00:01Z",
                    "actionResult": {"ok": True},
                    "screenshot": {"pngBase64": base64.b64encode(png).decode()},
                    "ui": {"activePackage": "com.android.settings", "nodes": []},
                },
            )
            self.assertEqual(result["screenshot"], "step-0001.png")
            for frame_index in (1, 2):
                devota_server.record_macro_run_step(
                    repo,
                    "run-device-proof",
                    {
                        "macroId": "macro-device-proof",
                        "macroName": "Device proof",
                        "stepIndex": 2,
                        "stepCount": 2,
                        "stepId": "step-human",
                        "name": "human frame",
                        "action": "humanCheckpoint",
                        "frameIndex": frame_index,
                        "frameCount": 2,
                        "capturedAt": f"2026-08-15T00:00:0{frame_index}Z",
                        "startedAt": "2026-08-15T00:00:00Z",
                        "completedAt": f"2026-08-15T00:00:0{frame_index}Z",
                        "screenshot": {"pngBase64": base64.b64encode(png).decode()},
                    },
                )
            completed = devota_server.complete_macro_run(
                repo,
                "run-device-proof",
                {"status": "passed", "completedAt": "2026-08-15T00:00:02Z"},
            )
            self.assertEqual(completed["run"]["status"], "passed")
            directory = devota_server.macro_run_dir(repo, "run-device-proof")
            self.assertEqual((directory / "step-0001.png").read_bytes(), png)
            self.assertEqual((directory / "step-0002-frame-0002.png").read_bytes(), png)
            self.assertEqual(len(completed["run"]["steps"][1]["frames"]), 2)
            self.assertTrue((directory / "gallery.html").is_file())
            self.assertEqual((directory / "manifest.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            listed = devota_server.list_macro_runs(repo)["runs"]
            self.assertEqual(listed[0]["stepCount"], 2)
            self.assertEqual(listed[0]["status"], "passed")


if __name__ == "__main__":
    unittest.main()
