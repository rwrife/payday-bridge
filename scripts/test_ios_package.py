"""Bounded native package XCTest gate; run after selecting pinned Xcode/runtime."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "NativeTestArtifacts"
ARTIFACTS.mkdir(exist_ok=True)
PACKAGE = ROOT / "Packages" / "PaydayBridgeKit"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"


class Deadline(RuntimeError):
    """Command exceeded its deadline; distinct from a nonzero exit."""


def run(name, command, timeout=60, cwd=ROOT):
    """Keep partial output and kill the command group when its deadline expires."""
    log = ARTIFACTS / f"{name}.log"
    with log.open("w") as output:
        print(f"{name}: {' '.join(command)}", flush=True)
        process = subprocess.Popen(command, cwd=cwd, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise Deadline(f"{name} exceeded {timeout}s; see {log}")
    if code:
        raise RuntimeError(f"{name} failed ({code}); see {log}")
    return log.read_text()


def boot_and_wait(udid, needs_boot):
    """Boot (if needed) and wait for readiness; recover ONE stalled boot.

    The FIRST boot after a fresh `xcodebuild -downloadPlatform iOS` prepares
    the device image lazily and routinely exceeds a 180s wait on hosted
    runners (observed on 3 consecutive fresh runners here, matching the
    fleet-wide pattern), so the first bootstatus gets a 300s bound. On a
    deadline (never a nonzero exit) run one best-effort shutdown — which can
    itself hang, tolerated — and retry boot+bootstatus once at the normal
    180s bound. The second deadline fails closed.
    """
    for attempt, budget in ((1, 300), (2, 180)):
        tag = "" if attempt == 1 else "-retry"
        try:
            if needs_boot:
                run(f"boot{tag}", ["xcrun", "simctl", "boot", udid])
            run(f"bootstatus{tag}", ["xcrun", "simctl", "bootstatus", udid, "-b"],
                timeout=budget)
            return
        except Deadline:
            if attempt == 2:
                raise
            try:
                run("recovery-shutdown", ["xcrun", "simctl", "shutdown", udid],
                    timeout=60)
            except Exception as shutdown_error:
                print(f"Recovery shutdown tolerated: {shutdown_error}",
                      file=sys.stderr)
            needs_boot = True


def main():
    runtimes = json.loads(run("runtimes", ["xcrun", "simctl", "list", "runtimes", "--json"]))
    assert any(r["identifier"] == RUNTIME and r["isAvailable"]
               for r in runtimes["runtimes"]), "Required iOS 26.0 runtime unavailable"
    types = json.loads(run("device-types", ["xcrun", "simctl", "list", "devicetypes", "--json"]))
    iphone_types = {t["identifier"] for t in types["devicetypes"] if "com.apple.CoreSimulator.SimDeviceType.iPhone" in t["identifier"]}
    devices = json.loads(run("devices", ["xcrun", "simctl", "list", "devices", "available", "--json"]))
    phones = [d for d in devices["devices"].get(RUNTIME, [])
              if d["isAvailable"] and d["deviceTypeIdentifier"] in iphone_types]
    created_udid = None
    needs_boot = True
    if phones:
        selected = sorted(phones, key=lambda d: d["name"])[0]
        udid = selected["udid"]
        needs_boot = selected["state"] != "Booted"
    else:
        phone_type = next(t for t in types["devicetypes"] if t["name"] == "iPhone 17")
        udid = run("create", ["xcrun", "simctl", "create", "iPhone 17 CI",
                              phone_type["identifier"], RUNTIME]).strip()
        created_udid = udid
    (ARTIFACTS / "destination.txt").write_text(f"platform=iOS Simulator,id={udid}\n")
    try:
        boot_and_wait(udid, needs_boot)
        schemes_output = run("schemes", ["xcodebuild", "-list", "-json"], timeout=180, cwd=PACKAGE)
        # xcodebuild can print IDERunDestination diagnostics before its JSON on stderr.
        json_start = schemes_output.find("{")
        if json_start < 0:
            raise RuntimeError("xcodebuild scheme listing has no JSON; see schemes.log")
        listing, _ = json.JSONDecoder().raw_decode(schemes_output[json_start:])
        assert "PaydayBridgeKit" in listing.get("workspace", listing.get("project", {})).get("schemes", []), listing
        destination = f"platform=iOS Simulator,id={udid}"
        destinations = run("destinations", ["xcodebuild", "-scheme", "PaydayBridgeKit", "-showdestinations"],
            timeout=120, cwd=PACKAGE)
        # SwiftPM scheme listing only enumerates "Any iOS Simulator Device"
        # placeholders, never concrete UDIDs (run 39417118833), so a UDID
        # membership check can never pass. Require the concrete simulator
        # platform to be an eligible destination; the test run below with the
        # explicit UDID is the real proof.
        if "platform:iOS Simulator" not in destinations:
            raise RuntimeError("PaydayBridgeKit scheme lists no iOS Simulator destination; see destinations.log")
        run("tests", ["xcodebuild", "-scheme", "PaydayBridgeKit", "-sdk", "iphonesimulator26.0",
                      "-destination", destination, "-destination-timeout", "60",
                      "-parallel-testing-enabled", "NO", "-configuration", "Debug",
                      "-derivedDataPath", str(ROOT / "NativeTestDerivedData"),
                      "-resultBundlePath", str(ARTIFACTS / "PaydayBridgeKit.xcresult"),
                      "CODE_SIGNING_ALLOWED=NO", "test"], timeout=720, cwd=PACKAGE)
        run("ui-tests", ["xcodebuild", "-project", str(ROOT / "PaydayBridge.xcodeproj"),
                         "-scheme", "PaydayBridge", "-sdk", "iphonesimulator26.0",
                         "-destination", destination, "-destination-timeout", "60",
                         "-parallel-testing-enabled", "NO", "-configuration", "Debug",
                         "-derivedDataPath", str(ROOT / "NativeTestDerivedData"),
                         "-resultBundlePath", str(ARTIFACTS / "PaydayBridgeUI.xcresult"),
                         "CODE_SIGNING_ALLOWED=NO", "test"], timeout=720, cwd=ROOT)
    finally:
        if created_udid:
            for name, command in [
                ("shutdown-created", ["xcrun", "simctl", "shutdown", created_udid]),
                ("delete-created", ["xcrun", "simctl", "delete", created_udid]),
            ]:
                try:
                    run(name, command, timeout=30)
                except Exception as cleanup_err:
                    print(f"Fallback simulator cleanup: {cleanup_err}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
    finally:
        for name, command in [
            ("xcode-version", ["xcodebuild", "-version"]),
            ("final-simulators", ["xcrun", "simctl", "list"]),
        ]:
            try:
                run(name, command, timeout=30)
            except Exception as error:
                print(f"Diagnostic collection: {error}", file=sys.stderr)
