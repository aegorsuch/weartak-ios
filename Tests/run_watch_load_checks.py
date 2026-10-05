"""Run Debug watch receive-path stress checks in a disposable unpaired simulator."""
import argparse
import json
import subprocess
import shutil
import time
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="Built Debug watch app bundle")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.watchOS-26-2")
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error("Watch app bundle does not exist")
    args.artifacts.mkdir(parents=True, exist_ok=True)
    device = command("xcrun", "simctl", "create", "WearTAK isolated load checks",
                     "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-40mm", args.runtime)
    try:
        command("xcrun", "simctl", "boot", device)
        command("xcrun", "simctl", "bootstatus", device, "-b")
        command("xcrun", "simctl", "install", device, str(args.app.resolve()))
        container = Path(command("xcrun", "simctl", "get_app_container", device,
                                 "com.aegorsuch.weartak.watchkitapp", "data"))
        launch = command("xcrun", "simctl", "launch",
                         "--stdout=" + str((args.artifacts / "stdout.log").resolve()),
                         "--stderr=" + str((args.artifacts / "stderr.log").resolve()), device,
                         "com.aegorsuch.weartak.watchkitapp", "--simulator-load-test")
        pid = launch.rsplit(":", 1)[1].strip()
        report = container / "Documents" / "watch-load-report.json"
        samples = []
        deadline = time.monotonic() + 180
        while not report.exists():
            if time.monotonic() > deadline:
                raise RuntimeError("Load test timed out; inspect simulator logs for test failure")
            sample = subprocess.run(["ps", "-o", "rss=", "-p", pid],
                                    text=True, capture_output=True)
            rss = sample.stdout.strip()
            if not rss:
                raise RuntimeError("Watch app exited during load test")
            samples.append({"seconds": round(180 - (deadline - time.monotonic()), 2),
                            "rssMiB": round(int(rss) / 1024, 2)})
            time.sleep(0.25)
        stages = json.loads(report.read_text())
        if len(stages) != 7 or any(
                s["liveContacts"] > 50 or s["cachedContacts"] > 50 or s["cacheBytes"] >= 262_144
                for s in stages):
            raise RuntimeError("Incomplete report or contact bounds exceeded")
        output = {"stages": stages, "peakRssMiB": max(s["rssMiB"] for s in samples),
                  "memorySamples": samples,
                  "scope": "Simulator watch receive path and model lifecycle; no radio or physical-watch proof"}
        print(json.dumps(output, indent=2))
        (args.artifacts / "report.json").write_text(json.dumps(output, indent=2))
        if any(s["maxHeartbeatDelaySeconds"] > 1 for s in stages):
            raise RuntimeError("Main-actor heartbeat delay exceeded the one-second test threshold")
    except Exception:
        time.sleep(5)
        device_data = Path.home() / "Library/Developer/CoreSimulator/Devices" / device / "data"
        for crash in device_data.glob("Library/Logs/**/*.ips"):
            shutil.copy2(crash, args.artifacts / crash.name)
        diagnostics = subprocess.run(
            ["xcrun", "simctl", "spawn", device, "log", "show", "--last", "3m",
             "--style", "compact", "--predicate",
             'process == "WearTAK Watch App" OR process == "ReportCrash" OR eventMessage CONTAINS "weartak"'],
            text=True, capture_output=True)
        (args.artifacts / "failure.log").write_text(diagnostics.stdout + diagnostics.stderr)
        raise
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False, capture_output=True)
        command("xcrun", "simctl", "delete", device)


if __name__ == "__main__":
    main()
