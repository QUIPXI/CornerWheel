#!/usr/bin/env python3
"""Compare real CornerWheel component CPU paths, without opening a wheel.

Usage:
  python3 Scripts/benchmark_performance.py --baseline /path/to/source-snapshot \
      --output /private/tmp/CornerWheelPerformance

Both snapshots are compiled with -O by default. --include-debug also measures
baseline -Onone separately; do not confuse that compiler change with code gains.
A graphical macOS login session and Xcode are required. No Accessibility grant
is required, because AX scanning and real window activation are not benchmarked.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

SOURCES = [
    "App/SettingsStore.swift", "App/CornerTriggerController.swift",
    "App/CornerWheelCoordinator.swift", "Core/ArcLayoutEngine.swift",
    "Core/CarouselController.swift", "Core/DisplayGeometry.swift", "Core/MRUTracker.swift",
    "Services/PermissionManager.swift", "Services/WindowActivationService.swift",
    "Services/WindowCatalog.swift", "Services/AccessibilityWindowStore.swift",
    "Services/WindowModels.swift", "UI/OverlayPanelController.swift", "UI/OverlayView.swift",
]

COORDINATOR_INSTRUMENTATION = '''
// Benchmark-only entry points appended to the temporary source copy.
extension CornerWheelCoordinator {
    func benchmarkPrepare(records: [WindowRecord], screen: NSScreen) {
        catalog.benchmarkSetRecords(records)
        sessionScreen = screen
        carousel = CarouselController(orderedIDs: records.map(\\.id), visibleSlots: 3,
                                      currentID: records[1].id)
        catalogChanged(records)
    }
    func benchmarkNavigate() { navigate(by: 1) }
    func benchmarkFinish() { closeSession() }
}
'''


def capture(command):
    return subprocess.check_output(command, text=True).strip()


def compile_variant(root, output, name, optimization, harness):
    work = output / name
    work.mkdir(parents=True, exist_ok=True)
    copied = []
    for relative in SOURCES:
        source = root / "Sources/CornerWheel" / relative
        text = source.read_text()
        if relative == "App/CornerWheelCoordinator.swift":
            text += COORDINATOR_INSTRUMENTATION
        if relative == "Services/WindowCatalog.swift":
            assignment = "publishWindows(records)" if "func publishWindows(" in text else "windows = records"
            text += "\nextension WindowCatalog { func benchmarkSetRecords(_ records: [WindowRecord]) { " + assignment + " } }\n"
        if relative == "UI/OverlayView.swift":
            icon = "appIcon(for: item.record)" if "private func appIcon(" in text else "item.appIcon"
            text += '''
// Exercise the exact icon access used by card rendering, without counting
// unrelated offscreen snapshot/bitmap allocation in the CPU measurement.
extension OverlayView {
    @MainActor func benchmarkIconAccess() -> Int {
        var result = 0
        for item in model.items {
            if let icon = ''' + icon + ''' { result &+= Int(icon.size.width) }
        }
        return result
    }
}
'''
        target = work / Path(relative).name
        target.write_text(text)
        copied.append(str(target))
    executable = work / "CornerWheelBenchmark"
    command = ["xcrun", "swiftc", optimization, "-whole-module-optimization", "-swift-version", "5",
               "-module-name", "CornerWheelBenchmark", "-o", str(executable), *copied, str(harness)]
    if optimization == "-Onone":
        command.extend(["-D", "DEBUG"])
    started = time.time()
    result = subprocess.run(command, capture_output=True, text=True)
    (work / "compile.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Compilation failed for {name}: {result.stderr[-5000:]}")
    return executable, {"source_root": str(root), "optimization": optimization,
                        "compile_seconds": time.time() - started, "source_files": len(copied)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--current", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3, help="Alternating process runs per variant")
    parser.add_argument("--samples", type=int, default=3, help="Measured samples per process after warmup")
    parser.add_argument("--include-debug", action="store_true")
    parser.add_argument("--baseline-only", action="store_true")
    args = parser.parse_args()
    if args.runs < 1 or args.samples < 1:
        parser.error("runs and samples must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    harness = Path(__file__).resolve().parent.parent / "Tests/Performance/PerformanceHarness.swift"
    variants = [("baseline_optimized", args.baseline, "-O")]
    if not args.baseline_only:
        variants.append(("current_optimized", args.current, "-O"))
    if args.include_debug:
        variants.append(("baseline_debug", args.baseline, "-Onone"))
    compiled = {}
    results = {"method": "Offscreen component CPU microbenchmarks, not end-to-end speed or battery measurements",
               "environment": {"macos": platform.mac_ver()[0], "machine": platform.machine(),
                               "cpu": capture(["sysctl", "-n", "machdep.cpu.brand_string"]),
                               "xcode": capture(["xcodebuild", "-version"]),
                               "swift": capture(["xcrun", "swiftc", "--version"]),
                               "captured_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
               "variants": {}, "comparison": {}}
    for name, root, optimization in variants:
        print(f"Compiling {name}…", flush=True)
        compiled[name], metadata = compile_variant(root.resolve(), args.output.resolve(), name, optimization, harness)
        results["variants"][name] = {**metadata, "runs": []}
    environment = {**os.environ, "CORNERWHEEL_BENCHMARK_SAMPLES": str(args.samples)}
    for run in range(args.runs):
        # Reverse order on alternate passes to reduce consistent ordering bias.
        order = list(compiled.items())
        if run % 2:
            order.reverse()
        for name, executable in order:
            print(f"Measuring {name}, run {run + 1}/{args.runs}…", flush=True)
            run_environment = dict(environment)
            if run == 0:
                run_environment["CORNERWHEEL_BENCHMARK_PNG_DIRECTORY"] = str(args.output.resolve() / name / "visuals")
            process = subprocess.run([str(executable)], env=run_environment, capture_output=True, text=True, timeout=180)
            (args.output / f"{name}-{run + 1}.stderr.log").write_text(process.stderr)
            if process.returncode:
                raise RuntimeError(f"Benchmark failed ({name}): {process.stderr[-3000:]}")
            observed = json.loads(process.stdout)
            (args.output / f"{name}-{run + 1}.json").write_text(json.dumps(observed, indent=2) + "\n")
            results["variants"][name]["runs"].append(observed)
    for name, variant in results["variants"].items():
        variant["summary"] = {}
        for metric in variant["runs"][0]:
            if metric == "context":
                continue
            samples = [sample for run in variant["runs"] for sample in run[metric]["samples"]]
            variant["summary"][metric] = {"median_microseconds": statistics.median(samples),
                                         "min_microseconds": min(samples), "max_microseconds": max(samples),
                                         "sample_count": len(samples)}
    if "current_optimized" in results["variants"]:
        for metric, before in results["variants"]["baseline_optimized"]["summary"].items():
            old = before["median_microseconds"]
            new = results["variants"]["current_optimized"]["summary"][metric]["median_microseconds"]
            results["comparison"][metric] = {"before_microseconds": old, "after_microseconds": new,
                                             "reduction_percent": (old-new)/old*100,
                                             "speedup_factor": old/new if new else None}
        comparer = args.output.resolve() / "compare-images"
        subprocess.run(["xcrun", "swiftc", "-O", str(harness.parent / "CompareImages.swift"),
                        "-o", str(comparer)], check=True)
        results["visual_comparison"] = {}
        for appearance in ["light", "dark"]:
            baseline_png = args.output / "baseline_optimized/visuals" / f"overlay-{appearance}.png"
            current_png = args.output / "current_optimized/visuals" / f"overlay-{appearance}.png"
            results["visual_comparison"][appearance] = json.loads(
                capture([str(comparer), str(baseline_png), str(current_png)]))
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results["comparison"] or results["variants"]["baseline_optimized"]["summary"], indent=2))
    print(f"Raw measurements saved to {args.output / 'results.json'}")


if __name__ == "__main__":
    main()
