import importlib.util
import base64
import json
import tempfile
import unittest
from unittest.mock import patch
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
    def queue_macro(order):
        return {"id": "ceb", "name": "CEB", "steps": [
            {"type": "shell", "value": "Roster: {{devota:ceb-primer:" + order + "}}"}]}

    @patch.object(devota_server, "prepare_ceb_primer_kits", side_effect=lambda roster: roster)
    def test_queue_selection_is_fresh_and_directional_without_mutations(self, prepare):
        for order, expected in (("forward", range(1, 21)),
                                ("middle", range(16, 36)),
                                ("reverse", range(50, 30, -1))):
            words = [{"topic": f"word{i}", "rank": i} for i in range(1, 51)]
            queue = {"lang": "ceb", "source": "primer_first_1000",
                     "filtered_total": 50, "words": words[:20] if order == "forward" else words}
            macro = self.queue_macro(order)
            with patch.object(devota_server.urllib.request, "urlopen") as fetch:
                fetch.return_value.__enter__.side_effect = lambda: BytesIO(json.dumps(queue).encode())
                for _ in range(2):
                    result = devota_server.resolve_macro({"macro": macro})
                    roster = json.loads(result["item"]["steps"][0]["value"].removeprefix("Roster: "))
                    self.assertEqual([w["rank"] for w in roster], list(expected))
                self.assertEqual(fetch.call_count, 2)
                url = fetch.call_args.args[0]
                self.assertEqual("limit=20" in url, order == "forward")
            self.assertIn("{{devota:", macro["steps"][0]["value"])
        self.assertEqual(prepare.call_count, 6)

    @patch.object(devota_server, "prepare_ceb_primer_kits", side_effect=lambda roster: roster)
    def test_queue_empty_short_and_bad_response(self, prepare):
        for order in ("forward", "middle", "reverse"):
            for length in (0, 3):
                queue = {"lang": "ceb", "source": "primer_first_1000", "filtered_total": length,
                         "words": [{"topic": f"word{i}", "rank": i} for i in range(length)]}
                with patch.object(devota_server.urllib.request, "urlopen") as fetch:
                    fetch.return_value.__enter__.return_value = BytesIO(json.dumps(queue).encode())
                    result = devota_server.resolve_macro(self.queue_macro(order))
                    roster = json.loads(result["item"]["steps"][0]["value"].removeprefix("Roster: "))
                    self.assertEqual(len(roster), length)
        with patch.object(devota_server.urllib.request, "urlopen") as fetch:
            fetch.return_value.__enter__.return_value = BytesIO(b'{"words": []}')
            with self.assertRaisesRegex(ValueError, "invalid"):
                devota_server.resolve_macro(self.queue_macro("middle"))
        with patch.object(devota_server.urllib.request, "urlopen") as fetch:
            fetch.return_value.__enter__.return_value = BytesIO(json.dumps({
                "lang": "ceb", "source": "primer_first_1000", "filtered_total": 100, "words": []}).encode())
            with self.assertRaisesRegex(ValueError, "whole queue"):
                devota_server.resolve_macro(self.queue_macro("reverse"))

    def test_runtime_generates_current_isolated_kits_and_supplies_paths(self):
        calls = []
        def generate(request, timeout):
            body = json.loads(request.data)
            calls.append(body)
            root = Path(body["path"])
            skill = root / "skills" / "ceb-blended-definition" / "SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text("kit")
            (root / "compile_blended.py").write_text("helper")
            (root / "definition_policy.json").write_text(json.dumps({
                "content_profile": "mnemonic_v4", "symbolic_policy": "selected_register",
                "commentary_sources": ["primer"]}))
            return BytesIO(json.dumps({"path": str(root), "agent": body["agent"], "lang": "ceb"}).encode())
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(devota_server, "CEB_PRIMER_KITS_DIR", Path(tmp)), \
                patch.object(devota_server.urllib.request, "urlopen", side_effect=generate):
            roster = [{"topic": "semana", "rank": 172}, {"topic": "bulan", "rank": 173}]
            first = devota_server.prepare_ceb_primer_kits(roster)
            second = devota_server.prepare_ceb_primer_kits(roster)
            self.assertNotEqual(first[0]["kit_path"], second[0]["kit_path"])
            self.assertEqual([x["topic"] for x in first], ["semana", "bulan"])
            self.assertEqual(len(calls), 4)
            for assignment, call in zip(first, calls):
                self.assertTrue(Path(assignment["kit_path"]).is_file())
                self.assertEqual(assignment["draft_path"], str(Path(call["path"]) / "draft.json"))
                self.assertEqual(call["symbolic_policy"], "selected_register")
                self.assertEqual(call["commentary_sources"], ["primer"])

    def test_runtime_generation_failure_removes_partial_kits_and_never_returns_prompt(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(devota_server, "CEB_PRIMER_KITS_DIR", Path(tmp)), \
                patch.object(devota_server.urllib.request, "urlopen", side_effect=OSError("generation failed")):
            with self.assertRaisesRegex(OSError, "generation failed"):
                devota_server.prepare_ceb_primer_kits([{"topic": "semana", "rank": 172}])
            self.assertEqual(list(Path(tmp).iterdir()), [])
        with patch.object(devota_server.urllib.request, "urlopen") as fetch:
            self.assertEqual(devota_server.prepare_ceb_primer_kits([]), [])
            fetch.assert_not_called()

    def test_generic_queue_directions_and_rank_source_precedence(self):
        words = [{"lemma": f"word{i}", "rank": i, "sources": ["primer", "ux"]} for i in range(50, 0, -1)]
        words.append({"lemma": "uxonly", "sources": ["ux"]})
        with patch.object(devota_server, "cradle_get", return_value={"lang": "hu", "words": words}):
            for order, expected in (("forward", range(1, 21)), ("middle", range(16, 36)), ("reverse", range(50, 30, -1))):
                self.assertEqual([r["rank"] for r in devota_server.select_cradle_authoring("hu", "creative-rank", order)], list(expected))
            self.assertEqual([r["topic"] for r in devota_server.select_cradle_authoring("hu", "creative-full", "forward")], ["uxonly"])

    def test_generic_full_pool_mix_and_commentary_filter(self):
        words = [{"lemma": f"back{i}", "sources": ["backstage"]} for i in range(30)] + [{"lemma": f"ux{i}", "sources": ["ux"]} for i in range(30)]
        with patch.object(devota_server, "cradle_get", return_value={"lang": "en", "words": words}):
            rows = devota_server.select_cradle_authoring("en", "creative-full", "forward")
            self.assertEqual([r["topic"] for r in rows], [f"back{i}" for i in range(10)] + [f"ux{i}" for i in range(10)])
        rows = [{"topic": "word", "id": "source", "approved": True, "has_ogden_commentary": False}]
        with patch.object(devota_server, "cradle_get", return_value={"lang": "en", "filtered_total": 1, "lessons": rows}) as fetch:
            self.assertEqual(devota_server.select_cradle_authoring("en", "ogden-commentary", "forward")[0]["source_id"], "source")
            self.assertIn("missing=ogden_commentary", fetch.call_args.args[0])

    def test_generic_preparation_caches_rank_pool_and_commentary_source(self):
        def generate(request, timeout):
            body = json.loads(request.data)
            root = Path(body["path"])
            token = body["agent"].replace("draft-arachnomind-", "").replace("generate-arachnomind-", "")
            skill = root / "skills" / ("en-" + token) / "SKILL.md"
            skill.parent.mkdir(parents=True, exist_ok=True)
            skill.write_text("kit")
            for helper in ("compile_one.py", "submit_one.py"):
                (root / helper).write_text("helper")
            return BytesIO(json.dumps({"path": str(root), "agent": body["agent"]}).encode())
        def fetch(path):
            if "/conventions/" in path:
                return {"mode": "rank_strict", "topic_rank": 12, "lemmas": ["known"]}
            if "/blocks?" in path:
                return {"shorthand": "p example"}
            return {"lesson_style": "creative", "anchor_words": ["anchor"]}
        with tempfile.TemporaryDirectory() as tmp, patch.object(devota_server, "CRADLE_AUTHORING_KITS_DIR", Path(tmp)), patch.object(devota_server.urllib.request, "urlopen", side_effect=generate), patch.object(devota_server, "cradle_get", side_effect=fetch):
            rank = devota_server.prepare_cradle_authoring("en", "creative-rank", [{"topic": "word", "rank": 12}])[0]
            root = Path(rank["draft_path"]).parent
            self.assertEqual(json.loads((root / "topic_pool.json").read_text())["lemmas"], ["known"])
            commentary = devota_server.prepare_cradle_authoring("en", "primer-commentary", [{"topic": "word", "source_id": "source"}])[0]
            self.assertTrue(Path(commentary["semantic_kit_path"]).is_file())
            packet = json.loads((Path(commentary["draft_path"]).parent / "source_packet.json").read_text())
            self.assertEqual(packet["id"], "source")
            self.assertEqual(commentary["anchor_words"], ["anchor"])

    def test_static_macro_needs_no_queue_request(self):
        with patch.object(devota_server.urllib.request, "urlopen") as fetch:
            result = devota_server.resolve_macro({"id": "static", "steps": [{"type": "shell", "value": "hello"}]})
            self.assertEqual(result["item"]["steps"][0]["value"], "hello")
            fetch.assert_not_called()

    def test_accepts_native_double_tap_and_path_device_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = devota_server.create_macro(
                Path(tmp),
                {
                    "name": "Native gestures",
                    "steps": [
                        {"type": "device", "value": json.dumps({
                            "action": "doubleTap", "args": {"xNormalized": 0.5, "yNormalized": 0.5}
                        })},
                        {"type": "device", "value": json.dumps({
                            "action": "gesturePath", "args": {"durationMs": 300, "points": [
                                {"xNormalized": 0.2, "yNormalized": 0.2},
                                {"xNormalized": 0.8, "yNormalized": 0.8},
                            ]}
                        })},
                        {"type": "device", "value": json.dumps({
                            "action": "waitUi",
                            "args": {"packageName": "example.app", "timeoutSeconds": 5,
                                     "intervalMs": 200},
                            "expect": {"textIncludes": ["Ready"]},
                        })},
                    ],
                },
            )
            self.assertEqual(len(result["item"]["steps"]), 3)

    def test_gesture_ui_requires_semantic_selector_and_bounded_relative_path(self):
        good = {"action": "gestureUi", "args": {
            "packageName": "io.github.chasekolozsy.cradlespeak",
            "selector": {"contentDescriptionExact": "Demo choice 📁"},
            "gesture": {"kind": "path", "durationMs": 400, "points": [
                {"dx": 40, "dy": 0}, {"dx": 100, "dy": -100},
            ]},
        }}
        normalized = devota_server.normalize_macro_step(
            {"type": "device", "value": json.dumps(good)})
        self.assertEqual(json.loads(normalized["value"])["action"], "gestureUi")
        for bad in (
            {**good, "args": {**good["args"], "selector": {"centerRegion": {"left": 0}}}},
            {**good, "args": {**good["args"], "gesture": {
                "kind": "path", "durationMs": 400,
                "points": [{"dx": 1, "dy": 0, "tMs": 0}, {"dx": 100, "dy": -100}]}}},
            {**good, "args": {**good["args"], "gesture": {
                "kind": "swipe", "dx": 0, "dy": -300, "durationMs": 5001}}},
        ):
            with self.assertRaisesRegex(ValueError, "gestureUi"):
                devota_server.normalize_macro_step(
                    {"type": "device", "value": json.dumps(bad)})

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

            self.assertEqual(synced["syncMode"], "server_authoritative_run")
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
                            "name": "Canonical",
                            "steps": [{"type": "shell", "value": "canonical"}],
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

    def test_phone_edit_can_rename_existing_macro_when_usage_did_not_advance(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            devota_server.create_macro(
                repo,
                {
                    "id": "macro-copy",
                    "name": "Hungarian Creative full pool copy",
                    "steps": [{"type": "shell", "value": "original prompt"}],
                },
            )

            synced = devota_server.sync_macros(
                repo,
                {
                    "macros": [
                        {
                            "id": "macro-copy",
                            "name": "My renamed macro",
                            "steps": [{"type": "shell", "value": "edited prompt"}],
                        }
                    ],
                    "usageCounts": {},
                },
            )

            self.assertEqual(synced["syncMode"], "client_edit")
            self.assertEqual(synced["macros"][0]["name"], "My renamed macro")
            self.assertEqual(synced["macros"][0]["steps"][0]["value"], "edited prompt")

    def test_phone_edit_can_delete_macro_when_usage_did_not_advance(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            devota_server.create_macro(
                repo,
                {
                    "id": "macro-delete-me",
                    "name": "Delete me",
                    "steps": [{"type": "shell", "value": "unused"}],
                },
            )

            synced = devota_server.sync_macros(
                repo,
                {"macros": [], "usageCounts": {}},
            )

            self.assertEqual(synced["syncMode"], "client_edit")
            self.assertEqual(synced["macros"], [])

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
