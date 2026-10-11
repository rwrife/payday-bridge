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
            raise RuntimeError(f"{name} exceeded {timeout}s; see {log}")
    if code:
        raise RuntimeError(f"{name} failed ({code}); see {log}")
    return log.read_text()


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
    if phones:
        selected = sorted(phones, key=lambda d: d["name"])[0]
        udid = selected["udid"]
        if selected["state"] != "Booted":
            run("boot", ["xcrun", "simctl", "boot", udid])
    else:
        phone_type = next(t for t in types["devicetypes"] if t["name"] == "iPhone 17")
        udid = run("create", ["xcrun", "simctl", "create", "iPhone 17 CI",
                              phone_type["identifier"], RUNTIME]).strip()
        created_udid = udid
    (ARTIFACTS / "destination.txt").write_text(f"platform=iOS Simulator,id={udid}\n")
    try:
        if created_udid:
            run("boot", ["xcrun", "simctl", "boot", udid])
        run("bootstatus", ["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=180)
        listing = json.loads(run("schemes", ["xcodebuild", "-list", "-json"], cwd=PACKAGE))
        assert "PaydayBridgeKit" in listing.get("workspace", listing.get("project", {})).get("schemes", []), listing
        destination = f"platform=iOS Simulator,id={udid}"
        destinations = run("destinations", ["xcodebuild", "-scheme", "PaydayBridgeKit", "-showdestinations"],
            timeout=120, cwd=PACKAGE)
        if udid not in destinations:
            raise RuntimeError("Selected iPhone is not a supported PaydayBridgeKit test destination")
        run("tests", ["xcodebuild", "-scheme", "PaydayBridgeKit", "-sdk", "iphonesimulator26.0",
                      "-destination", destination, "-destination-timeout", "60",
                      "-parallel-testing-enabled", "NO", "-configuration", "Debug",
                      "-derivedDataPath", str(ROOT / "NativeTestDerivedData"),
                      "-resultBundlePath", str(ARTIFACTS / "PaydayBridgeKit.xcresult"),
                      "CODE_SIGNING_ALLOWED=NO", "test"], timeout=720, cwd=PACKAGE)
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
