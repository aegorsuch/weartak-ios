"""Windows-compatible source/resource preflight; does not compile or execute Swift."""
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
WATCH = ROOT / "WearTAK Watch App"
LANGUAGES = ("en", "fr", "es", "de", "ar", "ja", "zh-Hans")
KEYS = (
    "Start nearest", "Start from beginning", "Stop route", "Point %lld of %lld",
    "Remaining: %lld m", "Remaining distance unavailable", "Nearest point: %lld m",
    "Route complete: %@", "Start nearest requires a current location. Enable location and try again.",
    "Show details", "Show %@ on map", "Bloodhound to %@", "Start Bloodhound",
    "Open navigation", "No active Bloodhound target", "Bloodhound", "Navigation",
    "Distance unavailable", "Selected target", "Marker", "%lld m", "%@ km",
    "Route \u00b7 %lld pts", "Pt %lld of %lld", "%@ left",
)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f"Duplicate JSON key: {key}"
        result[key] = value
    return result


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def main():
    catalogs = list(ROOT.rglob("*.xcstrings"))
    for catalog in catalogs:
        json.loads(catalog.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    strings = json.loads((WATCH / "Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
    for key in KEYS:
        for language in LANGUAGES:
            unit = strings[key]["localizations"][language]["stringUnit"]
            value = unit["value"]
            assert value and "?" not in value and "\ufffd" not in value, (key, language, "Encoding damage")
            assert sorted(re.findall(r"%(?:lld|@)", key)) == sorted(re.findall(r"%(?:lld|@)", value)), (key, language)
            assert unit["state"] == ("translated" if language == "en" else "needs_review"), (key, language)
    print(f"PASS: {len(catalogs)} catalogs; {len(KEYS)} route/picker strings in seven locales, unique keys and placeholders")

    for name in ("ATAKBloodhound", "ATAKCrosshair"):
        folder = WATCH / "Assets.xcassets" / f"{name}.imageset"
        manifest = json.loads((folder / "Contents.json").read_text(encoding="utf-8"), object_pairs_hook=unique_object)
        assert manifest["properties"]["template-rendering-intent"] == "template"
        filename = manifest["images"][0]["filename"]
        png = (folder / filename).read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", png[16:29])
        assert (width, height, depth, color) == (68, 68, 8, 6), (name, "Expected small RGBA artwork")
        offset = 8
        compressed = b""
        while offset < len(png):
            length = struct.unpack(">I", png[offset:offset + 4])[0]
            kind = png[offset + 4:offset + 8]
            data = png[offset + 8:offset + 8 + length]
            crc = struct.unpack(">I", png[offset + 8 + length:offset + 12 + length])[0]
            assert zlib.crc32(kind + data) & 0xffffffff == crc, (name, "PNG CRC")
            if kind == b"IDAT":
                compressed += data
            offset += 12 + length
        assert len(zlib.decompress(compressed)) == height * (1 + width * 4)
    print("PASS: both ATAK imagesets reference valid 68x68 RGBA template PNGs with intact CRCs")

    picker = read("WearTAK Watch App/ContentView.swift")
    model = read("WearTAK Watch App/WatchSessionModel.swift")
    rows = read("WearTAK Watch App/WatchBloodhoundPickerViews.swift")
    shared = read("Shared/BloodhoundPicker.swift")
    runner = read("scripts/run-portable-garmin-checks.sh")
    assert "case .showOnMap: return .showOnMap(target)" in shared
    assert "if target == active { return .stop }" in shared
    assert "case .showOnMap(let target): mapTarget = target" in picker
    assert "case .stop: model.stopBloodhoundLocally()" in picker
    assert "case .start(let target): model.startPickerBloodhound(target)" in picker
    assert "TacticalMapView(model: model, settings: settings, initialFocus: points)" in picker
    assert "BloodhoundMapBounds(points: initialFocus.map" in picker
    assert "BloodhoundNavigationView(model: model)" in picker
    for case in ("route(route.id)", "marker(marker.id)", "contact(contact.id)", "point(item.id)"):
        assert case in picker, case
    start = model.index("    func startPickerBloodhound(")
    end = model.index("    func stopRouteFollowing()", start)
    local_methods = model[start:end]
    assert "stopBloodhoundLocally()" in local_methods
    assert not re.search(r"\b(?:send\w*|publish\w*|markInPosition)\s*\(", local_methods)
    assert '.disabled(model.routeLocation == nil)' in rows
    assert 'Button("Cancel"' not in rows  # Reuses WatchMain's established localization.
    assert 'Image("ATAKBloodhound")' in rows and 'Image("ATAKCrosshair")' in rows
    assert 'Image(systemName: "stop.fill")' in rows
    assert '.frame(width: 44, height: 44)' in rows
    assert 'Tests/BloodhoundPickerChecks.swift' in runner
    assert 'Tests/RouteFollowerChecks.swift' in runner
    for filename in ("Shared/BloodhoundPicker.swift", "Shared/RouteFollower.swift",
                     "Tests/BloodhoundPickerChecks.swift", "Tests/RouteFollowerChecks.swift",
                     "WearTAK Watch App/WatchBloodhoundPickerViews.swift"):
        text = read(filename)
        assert "\ufffd" not in text and all(line == line.rstrip() for line in text.splitlines()), filename
        code = re.sub(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"', "", text, flags=re.S)
        stack = []
        for char in code:
            if char in "([{":
                stack.append(char)
            elif char in ")]}":
                assert stack and stack.pop() == {")": "(", "]": "[", "}": "{"}[char], filename
        assert not stack, filename
    print("PASS: picker action/map/stop/start wiring, local-only methods, touch targets and portable runner source checks")
    print("UNVERIFIED: native Swift compilation/tests, Xcode asset linking, UI layout, VoiceOver and physical GPS/actions")


if __name__ == "__main__":
    main()
