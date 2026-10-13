"""Host-only command contract tests; not simulator execution evidence."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("native", Path(__file__).with_name("test_ios_package.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
phone = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
ipad = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"

with tempfile.TemporaryDirectory() as directory:
    m.ARTIFACTS = Path(directory)
    assert m.run("output", [sys.executable, "-c", "print('retained')"]).strip() == "retained"
    try:
        m.run("timeout", [sys.executable, "-c", "import time; print('partial', flush=True); time.sleep(20)"], timeout=0.1)
        raise AssertionError("deadline ignored")
    except RuntimeError:
        assert "partial" in (m.ARTIFACTS / "timeout.log").read_text()
    try:
        m.run("nonzero", [sys.executable, "-c", "raise SystemExit(7)"])
        raise AssertionError("failure ignored")
    except RuntimeError as error:
        assert "(7)" in str(error)

    def scenario(devices, fail_boot=False, fail_shutdown=False,
                 stall_bootstatus=0, stall_shutdown=False):
        calls = []
        stalls = {"remaining": stall_bootstatus}
        def fake(name, command, timeout=60, cwd=m.ROOT):
            calls.append((name, command, timeout))
            if name == "runtimes":
                return json.dumps({"runtimes": [{"identifier": m.RUNTIME, "isAvailable": True}]})
            if name == "device-types":
                return json.dumps({"devicetypes": [{"name": "iPhone 17", "identifier": phone}, {"name": "iPad", "identifier": ipad}]})
            if name == "devices":
                return json.dumps({"devices": {m.RUNTIME: devices}})
            if name == "create":
                return "created"
            if name.startswith("boot") and fail_boot:
                raise RuntimeError("boot failed")
            if name.startswith("bootstatus") and stalls["remaining"] > 0:
                stalls["remaining"] -= 1
                raise m.Deadline(f"{name} exceeded {timeout}s")
            if name == "recovery-shutdown" and stall_shutdown:
                raise m.Deadline(f"{name} exceeded {timeout}s")
            if name == "shutdown-created" and fail_shutdown:
                raise RuntimeError("shutdown failed")
            if name == "schemes":
                return json.dumps({"workspace": {"schemes": ["PaydayBridgeKit"]}})
            if name == "destinations":
                return "created existing"
            return ""
        m.run = fake
        try:
            m.main()
        except RuntimeError:
            assert fail_boot or stall_bootstatus >= 2
        else:
            assert not fail_boot and stall_bootstatus < 2
        return calls

    disguised = {"isAvailable": True, "name": "iPhone fake", "deviceTypeIdentifier": ipad, "udid": "wrong", "state": "Booted"}
    existing = {"isAvailable": True, "name": "PaydayBridge CI iPhone", "deviceTypeIdentifier": phone, "udid": "existing", "state": "Booted"}
    calls = scenario([disguised, existing])
    assert not any(c[0] == "create" for c in calls)
    command = next(c[1] for c in calls if c[0] == "tests")
    assert "platform=iOS Simulator,id=existing" in command and "-only-testing" not in command

    # One bootstatus stall recovers via shutdown + retry:
    retry_calls = scenario([existing], stall_bootstatus=1)
    phase_names = [c[0] for c in retry_calls]
    assert "bootstatus" in phase_names
    assert "recovery-shutdown" in phase_names
    assert "bootstatus-retry" in phase_names
    assert "tests" in phase_names
    budgets = {c[0]: c[2] for c in retry_calls}
    assert budgets["bootstatus"] == 300 and budgets["bootstatus-retry"] == 180

    # Hung recovery shutdown is tolerated and the retry still happens:
    hung = scenario([existing], stall_bootstatus=1, stall_shutdown=True)
    assert "bootstatus-retry" in [c[0] for c in hung] and "tests" in [c[0] for c in hung]

    # Two bootstatus stalls fail closed without running tests:
    double_stall_calls = scenario([existing], stall_bootstatus=2)
    phase_names = [c[0] for c in double_stall_calls]
    assert "bootstatus" in phase_names
    assert "recovery-shutdown" in phase_names
    assert "bootstatus-retry" in phase_names
    assert "tests" not in phase_names

    for fail in [False, True]:
        for failed_shutdown in [False, True]:
            calls = scenario([disguised], fail_boot=fail, fail_shutdown=failed_shutdown)
            assert any(c[0] == "create" for c in calls)
            assert [c[0] for c in calls][-2:] == ["shutdown-created", "delete-created"]
        # Ignore mutually exclusive command paths; worst-case configured bounds
        # fit the 30-minute outer step timeout with diagnostic collection.
        assert 8 * 60 + 720 + 60 + 60 < 30 * 60
print("Host native-test command contracts: PASS; no Apple execution performed")
