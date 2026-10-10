"""Run with python3 scripts/test_policy_gates.py; isolated policy canaries."""
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="payday-policy-") as directory:
    root = Path(directory)
    shutil.copytree(source, root / "scripts")
    (root / "PaydayBridge").mkdir()
    (root / "Packages").mkdir()

    def check(script, expected):
        result = subprocess.run(["bash", str(root / "scripts" / script)],
                                capture_output=True, text=True)
        assert result.returncode == expected, result.stdout + result.stderr

    check("check_native_only.sh", 0)
    check("check_zero_network.sh", 0)
    for name, content in [
        ("pubspec.yaml", "name: forbidden"),
        ("ProjectVersion.txt", "m_EditorVersion: 6000"),
        ("package.json", '{"dependencies":{"react-native":"1"}}'),
        ("package.json", '{"dependencies":{"expo":"1"}}'),
        ("build.gradle", 'plugins { id "org.jetbrains.kotlin.multiplatform" }'),
        ("build.gradle.kts", 'plugins { id("org.jetbrains.kotlin.multiplatform") }'),
        ("app.csproj", "<Project><UseMaui>true</UseMaui></Project>"),
        ("app.csproj", '<PackageReference Include="Microsoft.Maui.Controls" />'),
    ]:
        fixture = root / name
        fixture.write_text(content)
        check("check_native_only.sh", 1)
        fixture.unlink()
    fixture = root / "PaydayBridge" / "NetworkCanary.swift"
    fixture.write_text("let session = URLSession.shared\n")
    check("check_zero_network.sh", 1)
    fixture.unlink()
    check("check_native_only.sh", 0)
    check("check_zero_network.sh", 0)
print("Policy gates: clean baseline and 9 forbidden fixtures PASS")
