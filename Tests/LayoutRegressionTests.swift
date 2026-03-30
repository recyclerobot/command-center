import AppKit
import Foundation

@main
struct LayoutRegressionTests {
    static func main() throws {
        try testLegacyProfileDecoding()
        try testSidecarTargetInferenceFromSavedDisplay()
        testRelativeFrameRoundTrip()
        testLargestIntersectionWins()
        testDisplayMatchingPrefersIdentifier()
        print("Layout regression tests passed.")
    }

    private static func testLegacyProfileDecoding() throws {
        let json = """
        [
          {
            "id": "legacy-profile",
            "name": "Legacy",
            "createdAt": 764294400,
            "windows": [
              {
                "appName": "Xcode",
                "bundleIdentifier": "com.apple.dt.Xcode",
                "windowTitle": "Project",
                "windowIndex": 0,
                "x": 120,
                "y": 80,
                "width": 1200,
                "height": 900
              }
            ]
          }
        ]
        """

        let data = Data(json.utf8)
        let profiles = try JSONDecoder().decode([WindowProfile].self, from: data)

        expect(profiles.count == 1, "Expected one decoded legacy profile.")
        expect(profiles[0].supportsDisplayAwareRestore == false, "Legacy profile should not require display-aware metadata.")
        expect(profiles[0].legacyRestoreMessage != nil, "Legacy profile should surface the re-save hint.")
        expect(profiles[0].windows[0].displayName == nil, "Legacy window should decode without display metadata.")
    }

    private static func testRelativeFrameRoundTrip() {
        let displayFrame = CGRect(x: 1440, y: 0, width: 1024, height: 768)
        let windowFrame = CGRect(x: 1600, y: 120, width: 640, height: 400)

        guard let normalized = DisplayLayoutSupport.normalizedFrame(for: windowFrame, in: displayFrame) else {
            fail("Expected normalized frame.")
        }

        let denormalized = DisplayLayoutSupport.denormalizedFrame(from: normalized, in: displayFrame)
        expect(abs(denormalized.origin.x - windowFrame.origin.x) < 0.001, "Round-trip x should match.")
        expect(abs(denormalized.origin.y - windowFrame.origin.y) < 0.001, "Round-trip y should match.")
        expect(abs(denormalized.size.width - windowFrame.size.width) < 0.001, "Round-trip width should match.")
        expect(abs(denormalized.size.height - windowFrame.size.height) < 0.001, "Round-trip height should match.")
    }

    private static func testLargestIntersectionWins() {
        let primary = ActiveDisplay(
            snapshot: DisplaySnapshot(name: "Built-in", x: 0, y: 0, width: 1440, height: 900, isPrimary: true),
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let sidecar = ActiveDisplay(
            snapshot: DisplaySnapshot(name: "Jarne's iPad", x: 1440, y: 0, width: 1024, height: 768, isPrimary: false),
            frame: CGRect(x: 1440, y: 0, width: 1024, height: 768)
        )

        let spanningWindow = CGRect(x: 1300, y: 40, width: 600, height: 600)
        let best = DisplayLayoutSupport.bestDisplay(for: spanningWindow, among: [primary, sidecar])

        expect(best?.snapshot.name == "Jarne's iPad", "Window should be assigned to the display with the largest overlap.")
    }

    private static func testDisplayMatchingPrefersIdentifier() {
        let displays = [
            ActiveDisplay(
                snapshot: DisplaySnapshot(
                    name: "Built-in",
                    identifier: "PRIMARY",
                    displayID: 1,
                    x: 0,
                    y: 0,
                    width: 1440,
                    height: 900,
                    isPrimary: true
                ),
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            ActiveDisplay(
                snapshot: DisplaySnapshot(
                    name: "Jarne's iPad",
                    identifier: "SIDECAR-UUID",
                    displayID: 2,
                    x: 1440,
                    y: 0,
                    width: 1024,
                    height: 768,
                    isPrimary: false
                ),
                frame: CGRect(x: 1440, y: 0, width: 1024, height: 768)
            )
        ]

        let match = DisplayLayoutSupport.matchingDisplay(
            identifier: "SIDECAR-UUID",
            displayID: nil,
            name: "Different Name",
            among: displays
        )

        expect(match?.snapshot.name == "Jarne's iPad", "Display matching should prefer identifier over name.")
    }

    private static func testSidecarTargetInferenceFromSavedDisplay() throws {
        let json = """
        [
          {
            "id": "sidecar-profile",
            "name": "Sidecar",
            "createdAt": 764294400,
            "displays": [
              {
                "name": "Built-in Retina Display",
                "identifier": "PRIMARY",
                "displayID": 1,
                "x": 0,
                "y": 0,
                "width": 1440,
                "height": 900,
                "isPrimary": true
              },
              {
                "name": "Sidecar Display (AirPlay)",
                "identifier": "SIDECAR",
                "displayID": 5,
                "x": 1440,
                "y": 0,
                "width": 1024,
                "height": 768,
                "isPrimary": false
              }
            ],
            "windows": [
              {
                "appName": "Obsidian",
                "bundleIdentifier": "md.obsidian",
                "windowTitle": "Daily Note",
                "windowIndex": 0,
                "x": 1440,
                "y": 0,
                "width": 1024,
                "height": 768,
                "displayName": "Sidecar Display (AirPlay)",
                "displayIdentifier": "SIDECAR",
                "displayID": 5,
                "relativeX": 0,
                "relativeY": 0,
                "relativeWidth": 1,
                "relativeHeight": 1
              }
            ]
          }
        ]
        """

        let data = Data(json.utf8)
        let profiles = try JSONDecoder().decode([WindowProfile].self, from: data)
        let resolvedTarget = profiles[0].resolvedSidecarTarget

        expect(resolvedTarget?.displayName == "Sidecar Display (AirPlay)", "Profile should infer Sidecar target from saved display metadata.")
        expect(resolvedTarget?.displayIdentifier == "SIDECAR", "Inferred target should preserve display identity.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("Test failed: \(message)\n", stderr)
        exit(1)
    }
}
