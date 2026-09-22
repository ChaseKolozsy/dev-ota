"""Exercise the actual staging scripts with tiny fake Flutter/Android tools.

The fake compiler models Flutter's +2000 ARM64 split offset and zero universal
offset. Real APK compilation/signing is still checked by the Android CI job.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FLOOR = 2099000000  # Deliberately ahead of today's date-derived build number.


class BuildVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devota-build-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts/build"
        scripts.mkdir(parents=True)
        for name in ("debug", "release"):
            shutil.copy2(ROOT / f"scripts/build/devota-public-{name}.sh", scripts)
        self.dist = self.root / "app/dist/public"
        self.dist.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tool(self.bin / "flutter", """#!/usr/bin/env bash
set -eu
number=0
offset=0
name=app-release.apk
for arg in "$@"; do
  case "$arg" in
    --build-number=*) number="${arg#*=}" ;;
    --split-per-abi) offset=2000; name=app-arm64-v8a-debug.apk ;;
  esac
done
mkdir -p build/app/outputs/flutter-apk
printf "package: name='io.github.chasekolozsy.devota' versionCode='%s'\\n" "$((number + offset))" > "build/app/outputs/flutter-apk/$name"
""")
        sdk = self.root / "sdk"
        build_tools = sdk / "build-tools/1"
        build_tools.mkdir(parents=True)
        self.tool(build_tools / "aapt", '#!/usr/bin/env bash\ncat "$3"\n')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("DEVOTA_")}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", ANDROID_HOME=str(sdk))

    def tool(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def prefix(self, kind):
        return "devota-arm64-debug" if kind == "debug" else "devota-universal-release"

    def seed(self, kind, version):
        prefix = self.prefix(kind)
        (self.dist / f"{prefix}.badging.txt").write_text(f"versionCode='{version}'\n")
        (self.dist / f"{prefix}.apk").write_text("previous APK")

    def version(self, kind):
        return int((self.dist / f"{self.prefix(kind)}.badging.txt").read_text().split("versionCode='")[1].split("'")[0])

    def build(self, kind, **env):
        return subprocess.run(
            ["bash", str(self.root / f"scripts/build/devota-public-{kind}.sh")],
            env={**self.env, **env}, text=True, capture_output=True, timeout=10)

    def assert_build(self, kind, expected):
        result = self.build(kind)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.version(kind), expected)

    def test_debug_then_universal_release(self):
        self.seed("debug", FLOOR)
        self.assert_build("debug", FLOOR + 1)
        self.assert_build("release", FLOOR + 2)
        self.assertTrue((self.dist / "devota-arm64-debug.apk").exists())

    def test_release_then_debug_preserves_release(self):
        self.seed("release", FLOOR)
        self.assert_build("debug", FLOOR + 1)
        self.assertEqual(self.version("release"), FLOOR)
        self.assertTrue((self.dist / "devota-universal-release.apk").exists())
        self.assert_build("release", FLOOR + 2)

    def test_release_uses_highest_of_both_artifacts(self):
        self.seed("release", FLOOR)
        self.seed("debug", FLOOR + 50)
        self.assert_build("release", FLOOR + 51)

    def test_explicit_downgrades_rejected_before_replacing_artifact(self):
        for kind, offset in (("debug", 2000), ("release", 0)):
            with self.subTest(kind=kind):
                self.seed(kind, FLOOR)
                result = self.build(kind, DEVOTA_BUILD_NUMBER=str(FLOOR - offset))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing to stage", result.stderr)
                self.assertEqual((self.dist / f"{self.prefix(kind)}.apk").read_text(), "previous APK")

    def test_invalid_build_number_rejected(self):
        for kind in ("debug", "release"):
            with self.subTest(kind=kind):
                result = self.build(kind, DEVOTA_BUILD_NUMBER="not-a-number")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be numeric", result.stderr)


if __name__ == "__main__":
    unittest.main()
