import Cocoa
import ApplicationServices

enum SidecarConnectionStatus: Equatable {
    case alreadyAvailable
    case connected(strategyName: String)
    case accessibilityPermissionRequired
    case automationPermissionDenied
    case deviceUnavailable
    case timedOut
    case failed(message: String)
}

struct SidecarConnectionResult: Equatable {
    let attempted: Bool
    let targetDisplayName: String
    let status: SidecarConnectionStatus

    var didConnect: Bool {
        switch status {
        case .alreadyAvailable, .connected:
            return true
        default:
            return false
        }
    }

    var message: String {
        switch status {
        case .alreadyAvailable:
            return "\(targetDisplayName) is already available."
        case .connected(let strategyName):
            return "Connected \(targetDisplayName) using \(strategyName)."
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to automate Sidecar."
        case .automationPermissionDenied:
            return "Automation permission was denied, so Command Center could not connect \(targetDisplayName)."
        case .deviceUnavailable:
            return "\(targetDisplayName) was not available in Screen Mirroring or Displays."
        case .timedOut:
            return "Command Center tried to connect \(targetDisplayName), but the display did not appear in time."
        case .failed(let message):
            return message
        }
    }
}

protocol AppleScriptRunning {
    func run(_ source: String) -> Result<Void, AppleScriptExecutionError>
}

struct AppleScriptExecutionError: Error, Equatable {
    let code: Int
    let message: String
}

private struct SidecarAutomationStrategy {
    let name: String
    let attempt: () -> Result<Void, AppleScriptExecutionError>
}

final class AppleScriptRunner: AppleScriptRunning {
    func run(_ source: String) -> Result<Void, AppleScriptExecutionError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(AppleScriptExecutionError(code: -1, message: "Failed to compile AppleScript source."))
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? -1
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
            return .failure(AppleScriptExecutionError(code: code, message: message))
        }

        return .success(())
    }
}

final class SidecarAutomationService {
    static let shared = SidecarAutomationService()

    private let scriptRunner: AppleScriptRunning
    private let displayProvider: () -> [DisplaySnapshot]

    init(
        scriptRunner: AppleScriptRunning = AppleScriptRunner(),
        displayProvider: @escaping () -> [DisplaySnapshot] = { DisplayLayoutSupport.currentDisplays() }
    ) {
        self.scriptRunner = scriptRunner
        self.displayProvider = displayProvider
    }

    func ensureDisplayAvailable(
        targetDisplayName: String,
        targetDeviceName: String?,
        targetDisplayIdentifier: String?,
        targetDisplayID: Int?
    ) -> SidecarConnectionResult {
        let targetName = targetDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredDeviceName = targetDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if isDisplayAvailable(name: targetName, identifier: targetDisplayIdentifier, displayID: targetDisplayID) {
            return SidecarConnectionResult(attempted: false, targetDisplayName: targetName, status: .alreadyAvailable)
        }

        guard AXIsProcessTrusted() else {
            return SidecarConnectionResult(
                attempted: false,
                targetDisplayName: targetName,
                status: .accessibilityPermissionRequired
            )
        }

        var lastError: AppleScriptExecutionError?

        let strategies =
            makeNativeStrategies(for: targetName, targetDeviceName: preferredDeviceName) +
            makeAppleScriptStrategies(for: targetName, targetDeviceName: preferredDeviceName)

        for strategy in strategies {
            switch strategy.attempt() {
            case .success:
                NSLog("Sidecar strategy succeeded: %@", strategy.name)
                if waitForDisplay(name: targetName, identifier: targetDisplayIdentifier, displayID: targetDisplayID) {
                    return SidecarConnectionResult(
                        attempted: true,
                        targetDisplayName: targetName,
                        status: .connected(strategyName: strategy.name)
                    )
                }
                NSLog("Sidecar strategy did not surface %@ before timeout window: %@", targetName, strategy.name)
                lastError = nil
            case .failure(let error):
                NSLog(
                    "Sidecar strategy failed: %@ (%d) %@",
                    strategy.name,
                    error.code,
                    error.message
                )
                lastError = error

                if error.code == -1743 {
                    return SidecarConnectionResult(
                        attempted: true,
                        targetDisplayName: targetName,
                        status: .automationPermissionDenied
                    )
                }

                if error.code == 1001 {
                    return SidecarConnectionResult(
                        attempted: true,
                        targetDisplayName: targetName,
                        status: .accessibilityPermissionRequired
                    )
                }
            }
        }

        if let lastError, isDeviceUnavailableError(lastError) {
            return SidecarConnectionResult(
                attempted: true,
                targetDisplayName: targetName,
                status: .deviceUnavailable
            )
        }

        if lastError == nil {
            return SidecarConnectionResult(
                attempted: true,
                targetDisplayName: targetName,
                status: .timedOut
            )
        }

        return SidecarConnectionResult(
            attempted: true,
            targetDisplayName: targetName,
            status: .failed(message: "Command Center could not connect \(targetName): \(lastError!.message)")
        )
    }

    private func isDisplayAvailable(name: String, identifier: String?, displayID: Int?) -> Bool {
        let activeDisplays = displayProvider().map { ActiveDisplay(snapshot: $0, frame: $0.frame) }
        return DisplayLayoutSupport.matchingDisplay(
            identifier: identifier,
            displayID: displayID,
            name: name,
            among: activeDisplays
        ) != nil
    }

    private func waitForDisplay(name: String, identifier: String?, displayID: Int?) -> Bool {
        let timeout = Date().addingTimeInterval(20)

        while Date() < timeout {
            if isDisplayAvailable(name: name, identifier: identifier, displayID: displayID) {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        return false
    }

    private func isDeviceUnavailableError(_ error: AppleScriptExecutionError) -> Bool {
        switch error.code {
        case 1004, 1007:
            return true
        default:
            return false
        }
    }

    private func makeNativeStrategies(
        for targetDisplayName: String,
        targetDeviceName: String?
    ) -> [SidecarAutomationStrategy] {
        let looseMatchAllowed =
            recentSidecarDeviceCount() == 1 &&
            (targetDeviceName == nil || DisplayLayoutSupport.isGenericSidecarDisplayName(targetDisplayName))
        let targetDeviceLabel = targetDeviceName ?? targetDisplayName

        return [
            SidecarAutomationStrategy(
                name: "Native Screen Mirroring Menu Bar",
                attempt: {
                    self.connectUsingAccessibilityScreenMirroringMenuBar(
                        targetDeviceLabel: targetDeviceLabel,
                        allowLooseMatch: looseMatchAllowed
                    )
                }
            ),
            SidecarAutomationStrategy(
                name: "Native Control Center",
                attempt: {
                    self.connectUsingAccessibilityControlCenter(
                        targetDeviceLabel: targetDeviceLabel,
                        allowLooseMatch: looseMatchAllowed
                    )
                }
            ),
            SidecarAutomationStrategy(
                name: "Native Displays Settings",
                attempt: {
                    self.connectUsingAccessibilityDisplaysSettings(
                        targetDeviceLabel: targetDeviceLabel,
                        allowLooseMatch: looseMatchAllowed
                    )
                }
            )
        ]
    }

    private func makeAppleScriptStrategies(
        for targetDisplayName: String,
        targetDeviceName: String?
    ) -> [SidecarAutomationStrategy] {
        let looseMatchAllowed =
            recentSidecarDeviceCount() == 1 &&
            (targetDeviceName == nil || DisplayLayoutSupport.isGenericSidecarDisplayName(targetDisplayName))

        return [
            SidecarAutomationStrategy(
                name: "AppleScript Screen Mirroring Menu Bar",
                attempt: {
                    self.scriptRunner.run(
                        self.directScreenMirroringMenuBarScript(
                            targetDisplayName: targetDisplayName,
                            targetDeviceName: targetDeviceName,
                            allowLooseMatch: looseMatchAllowed
                        )
                    )
                }
            ),
            SidecarAutomationStrategy(
                name: "AppleScript Control Center",
                attempt: {
                    self.scriptRunner.run(
                        self.controlCenterScreenMirroringScript(
                            targetDisplayName: targetDisplayName,
                            targetDeviceName: targetDeviceName,
                            allowLooseMatch: looseMatchAllowed
                        )
                    )
                }
            ),
            SidecarAutomationStrategy(
                name: "AppleScript Displays Settings",
                attempt: {
                    self.scriptRunner.run(
                        self.displaysSettingsScript(
                            targetDisplayName: targetDisplayName,
                            targetDeviceName: targetDeviceName,
                            allowLooseMatch: looseMatchAllowed
                        )
                    )
                }
            )
        ]
    }

    private func recentSidecarDeviceCount() -> Int {
        let defaults = UserDefaults(suiteName: "com.apple.sidecar.display")
        let recents = defaults?.array(forKey: "recents") as? [String]
        return recents?.count ?? 0
    }

    private func connectUsingAccessibilityScreenMirroringMenuBar(
        targetDeviceLabel: String,
        allowLooseMatch: Bool
    ) -> Result<Void, AppleScriptExecutionError> {
        guard let controlCenterApp = runningApplication(
            bundleIdentifiers: ["com.apple.controlcenter", "com.apple.ControlCenter"],
            localizedNames: ["ControlCenter", "Control Center", "Control Centre"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "Control Center is not running."))
        }

        let appElement = AXUIElementCreateApplication(controlCenterApp.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 1.5)

        guard let menuBarItem = waitForPressableElement(
            in: appElement,
            timeout: 2,
            matchingAnyOf: ["Screen Mirroring"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "The Screen Mirroring menu bar item is not available."))
        }

        guard performAction(on: menuBarItem.element) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "The Screen Mirroring menu bar item could not be opened."))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return chooseDeviceUsingAccessibility(
            in: appElement,
            targetDeviceLabel: targetDeviceLabel,
            allowLooseMatch: allowLooseMatch,
            notFoundCode: 1004,
            selectionFailedCode: 1005
        )
    }

    private func connectUsingAccessibilityControlCenter(
        targetDeviceLabel: String,
        allowLooseMatch: Bool
    ) -> Result<Void, AppleScriptExecutionError> {
        guard let controlCenterApp = runningApplication(
            bundleIdentifiers: ["com.apple.controlcenter", "com.apple.ControlCenter"],
            localizedNames: ["ControlCenter", "Control Center", "Control Centre"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "Control Center is not running."))
        }

        let appElement = AXUIElementCreateApplication(controlCenterApp.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 1.5)

        guard let controlCenterItem = waitForPressableElement(
            in: appElement,
            timeout: 2,
            matchingAnyOf: ["Control Center", "Control Centre"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "Control Center is not available."))
        }

        guard performAction(on: controlCenterItem.element) else {
            return .failure(AppleScriptExecutionError(code: 1002, message: "Control Center could not be opened."))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        guard let screenMirroringTile = waitForPressableElement(
            in: appElement,
            timeout: 2,
            matchingAnyOf: ["Screen Mirroring"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1003, message: "The Screen Mirroring tile could not be found in Control Center."))
        }

        guard performAction(on: screenMirroringTile.element) else {
            return .failure(AppleScriptExecutionError(code: 1003, message: "The Screen Mirroring tile could not be activated."))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return chooseDeviceUsingAccessibility(
            in: appElement,
            targetDeviceLabel: targetDeviceLabel,
            allowLooseMatch: allowLooseMatch,
            notFoundCode: 1004,
            selectionFailedCode: 1005
        )
    }

    private func connectUsingAccessibilityDisplaysSettings(
        targetDeviceLabel: String,
        allowLooseMatch: Bool
    ) -> Result<Void, AppleScriptExecutionError> {
        guard let displaysURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays") else {
            return .failure(AppleScriptExecutionError(code: 1006, message: "Displays settings URL is invalid."))
        }

        NSWorkspace.shared.open(displaysURL)

        guard let systemSettingsApp = waitForRunningApplication(
            bundleIdentifiers: ["com.apple.systemsettings", "com.apple.systempreferences"],
            localizedNames: ["System Settings", "System Preferences"],
            timeout: 4
        ) else {
            return .failure(AppleScriptExecutionError(code: 1006, message: "Displays settings did not open."))
        }

        systemSettingsApp.activate(options: [.activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(systemSettingsApp.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 1.5)

        guard let addDisplayControl = waitForPressableElement(
            in: appElement,
            timeout: 5,
            matchingAnyOf: ["Add Display", "Add display"]
        ) else {
            return .failure(AppleScriptExecutionError(code: 1006, message: "The Add Display control could not be found in Displays settings."))
        }

        guard performAction(on: addDisplayControl.element) else {
            return .failure(AppleScriptExecutionError(code: 1006, message: "The Add Display control could not be opened."))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return chooseDeviceUsingAccessibility(
            in: appElement,
            targetDeviceLabel: targetDeviceLabel,
            allowLooseMatch: allowLooseMatch,
            notFoundCode: 1007,
            selectionFailedCode: 1008
        )
    }

    private func directScreenMirroringMenuBarScript(
        targetDisplayName: String,
        targetDeviceName: String?,
        allowLooseMatch: Bool
    ) -> String {
        let escapedTarget = appleScriptEscaped(targetDeviceName ?? targetDisplayName)
        let allowLooseMatchFlag = allowLooseMatch ? "true" : "false"

        return """
        set targetDeviceName to "\(escapedTarget)"
        set allowLooseMatch to \(allowLooseMatchFlag)
        \(deviceSelectionHelpers(
            notFoundErrorCode: 1004,
            selectionFailedErrorCode: 1005
        ))
        tell application "System Events"
            if UI elements enabled is false then error "Accessibility permission is required." number 1001
        end tell

        tell application "System Events"
            tell application process "ControlCenter"
                set screenMirroringItem to missing value

                try
                    set screenMirroringItem to first menu bar item of menu bar 1 whose description contains "Screen Mirroring"
                end try

                if screenMirroringItem is missing value then
                    try
                        set screenMirroringItem to first menu bar item of menu bar 1 whose title contains "Screen Mirroring"
                    end try
                end if

                if screenMirroringItem is missing value then
                    try
                        set screenMirroringItem to first menu bar item of menu bar 1 whose value contains "Screen Mirroring"
                    end try
                end if

                if screenMirroringItem is missing value then error "The Screen Mirroring menu bar item is not available." number 1002

                if my activateElement(screenMirroringItem) is false then
                    error "The Screen Mirroring menu bar item could not be opened." number 1002
                end if

                repeat 20 times
                    if exists window 1 then exit repeat
                    delay 0.1
                end repeat

                if not (exists window 1) then error "The Screen Mirroring popover did not open." number 1003

                my chooseDeviceFromWindow(window 1, targetDeviceName, allowLooseMatch)
            end tell
        end tell
        """
    }

    private func controlCenterScreenMirroringScript(
        targetDisplayName: String,
        targetDeviceName: String?,
        allowLooseMatch: Bool
    ) -> String {
        let escapedTarget = appleScriptEscaped(targetDeviceName ?? targetDisplayName)
        let allowLooseMatchFlag = allowLooseMatch ? "true" : "false"

        return """
        set targetDeviceName to "\(escapedTarget)"
        set allowLooseMatch to \(allowLooseMatchFlag)
        \(deviceSelectionHelpers(
            notFoundErrorCode: 1004,
            selectionFailedErrorCode: 1005
        ))
        tell application "System Events"
            if UI elements enabled is false then error "Accessibility permission is required." number 1001
        end tell

        tell application "System Events"
            tell application process "ControlCenter"
                set controlCenterItem to missing value

                try
                    set controlCenterItem to first menu bar item of menu bar 1 whose description is "Control Center"
                end try

                if controlCenterItem is missing value then
                    try
                        set controlCenterItem to first menu bar item of menu bar 1 whose description is "Control Centre"
                    end try
                end if

                if controlCenterItem is missing value then
                    try
                        set controlCenterItem to first menu bar item of menu bar 1 whose description contains "Control"
                    end try
                end if

                if controlCenterItem is missing value then error "Control Center is not available." number 1002

                if my activateElement(controlCenterItem) is false then error "Control Center could not be opened." number 1002

                repeat 20 times
                    if exists window 1 then exit repeat
                    delay 0.1
                end repeat

                if not (exists window 1) then error "Control Center did not open." number 1003

                set screenMirroringControl to missing value

                try
                    set screenMirroringControl to first button of (entire contents of window 1) whose ((name is "Screen Mirroring") or (description is "Screen Mirroring") or (title is "Screen Mirroring"))
                end try

                if screenMirroringControl is missing value then
                    try
                        set screenMirroringControl to first checkbox of (entire contents of window 1) whose ((name is "Screen Mirroring") or (description is "Screen Mirroring") or (title is "Screen Mirroring"))
                    end try
                end if

                if screenMirroringControl is missing value then
                    try
                        set screenMirroringControl to button 2 of group 1 of window 1
                    end try
                end if

                if screenMirroringControl is missing value then
                    try
                        set screenMirroringControl to UI element 6 of group 1 of window 1
                    end try
                end if

                if screenMirroringControl is missing value then error "The Screen Mirroring tile could not be found in Control Center." number 1003

                if my activateElement(screenMirroringControl) is false then
                    error "The Screen Mirroring tile could not be activated." number 1003
                end if

                delay 0.8
                my chooseDeviceFromWindow(window 1, targetDeviceName, allowLooseMatch)
            end tell
        end tell
        """
    }

    private func displaysSettingsScript(
        targetDisplayName: String,
        targetDeviceName: String?,
        allowLooseMatch: Bool
    ) -> String {
        let escapedTarget = appleScriptEscaped(targetDeviceName ?? targetDisplayName)
        let allowLooseMatchFlag = allowLooseMatch ? "true" : "false"

        return """
        set targetDeviceName to "\(escapedTarget)"
        set allowLooseMatch to \(allowLooseMatchFlag)
        \(deviceSelectionHelpers(
            notFoundErrorCode: 1007,
            selectionFailedErrorCode: 1008
        ))
        tell application "System Events"
            if UI elements enabled is false then error "Accessibility permission is required." number 1001
        end tell

        do shell script "open x-apple.systempreferences:com.apple.preference.displays"

        delay 1.2

        tell application "System Events"
            tell application process "System Settings"
                repeat 25 times
                    if exists window 1 then exit repeat
                    delay 0.2
                end repeat

                if not (exists window 1) then error "Displays settings did not open." number 1006

                set settingsWindow to window 1
                set addDisplayControl to missing value

                repeat 20 times
                    try
                        set addDisplayControl to first button of (entire contents of settingsWindow) whose ((name is "Add Display") or (name is "Add display") or (description is "Add Display") or (description is "Add display") or (title is "Add Display") or (title is "Add display"))
                    end try

                    if addDisplayControl is missing value then
                        try
                            set addDisplayControl to first pop up button of (entire contents of settingsWindow) whose ((name is "Add Display") or (name is "Add display") or (description is "Add Display") or (description is "Add display") or (title is "Add Display") or (title is "Add display"))
                        end try
                    end if

                    if addDisplayControl is missing value then
                        try
                            set addDisplayControl to pop up button 1 of group 1 of group 2 of splitter group 1 of group 1 of settingsWindow
                        end try
                    end if

                    if addDisplayControl is not missing value then exit repeat
                    delay 0.2
                end repeat

                if addDisplayControl is missing value then error "The Add Display control could not be found in Displays settings." number 1006

                if my activateElement(addDisplayControl) is false then
                    error "The Add Display control could not be opened." number 1006
                end if

                delay 0.5
                my chooseMenuItemFromActivator(addDisplayControl, targetDeviceName, allowLooseMatch)
            end tell
        end tell
        """
    }

    private func deviceSelectionHelpers(
        notFoundErrorCode: Int,
        selectionFailedErrorCode: Int
    ) -> String {
        """
        on normalizedText(rawValue)
            if rawValue is missing value then return ""
            try
                set textValue to rawValue as text
            on error
                return ""
            end try

            if textValue is "missing value" then return ""
            return textValue
        end normalizedText

        on candidateTexts(elementRef)
            set textCandidates to {}

            try
                set end of textCandidates to my normalizedText(name of elementRef)
            end try

            try
                set end of textCandidates to my normalizedText(title of elementRef)
            end try

            try
                set end of textCandidates to my normalizedText(description of elementRef)
            end try

            try
                set end of textCandidates to my normalizedText(value of elementRef)
            end try

            return textCandidates
        end candidateTexts

        on isIgnoredLabel(labelText)
            set normalizedLabel to my normalizedText(labelText)
            if normalizedLabel is "" then return true

            set ignoredLabels to {"Screen Mirroring", "Link keyboard and mouse", "AirPlay Audio", "Airplay Audio", "Display Settings...", "Display Settings…", "Displays", "Add Display", "Add display", "Control Center", "Control Centre", "Wi-Fi", "Focus", "Bluetooth", "AirDrop"}

            repeat with ignoredLabel in ignoredLabels
                ignoring case
                    if normalizedLabel is (contents of ignoredLabel) then return true
                end ignoring
            end repeat

            return false
        end isIgnoredLabel

        on textMatches(candidateText, targetText)
            set normalizedCandidate to my normalizedText(candidateText)
            set normalizedTarget to my normalizedText(targetText)
            if normalizedCandidate is "" or normalizedTarget is "" then return false

            ignoring case
                if normalizedCandidate is normalizedTarget then return true
                if normalizedCandidate contains normalizedTarget then return true
                if normalizedTarget contains normalizedCandidate then return true
            end ignoring

            return false
        end textMatches

        on activateElement(elementRef)
            try
                click elementRef
                return true
            end try

            try
                perform action 1 of elementRef
                return true
            end try

            try
                perform action 2 of elementRef
                return true
            end try

            return false
        end activateElement

        on firstExactMatchInCollection(elementCollection, targetText)
            repeat with currentElement in elementCollection
                try
                    set elementRef to contents of currentElement
                    repeat with candidateText in my candidateTexts(elementRef)
                        if my textMatches(contents of candidateText, targetText) then return elementRef
                    end repeat
                end try
            end repeat

            return missing value
        end firstExactMatchInCollection

        on firstLooseMatchInCollection(elementCollection)
            repeat with currentElement in elementCollection
                try
                    set elementRef to contents of currentElement
                    repeat with candidateText in my candidateTexts(elementRef)
                        set normalizedCandidate to my normalizedText(contents of candidateText)
                        if normalizedCandidate is not "" and (my isIgnoredLabel(normalizedCandidate) is false) then
                            ignoring case
                                if normalizedCandidate contains "ipad" or normalizedCandidate contains "sidecar" then return elementRef
                            end ignoring
                        end if
                    end repeat
                end try
            end repeat

            repeat with currentElement in elementCollection
                try
                    set elementRef to contents of currentElement
                    repeat with candidateText in my candidateTexts(elementRef)
                        set normalizedCandidate to my normalizedText(contents of candidateText)
                        if normalizedCandidate is not "" and (my isIgnoredLabel(normalizedCandidate) is false) then return elementRef
                    end repeat
                end try
            end repeat

            return missing value
        end firstLooseMatchInCollection

        on firstElementInCollection(elementCollection)
            try
                if (count of elementCollection) > 0 then return item 1 of elementCollection
            end try

            return missing value
        end firstElementInCollection

        on firstDeviceElementInContainer(containerRef, targetText, allowLooseMatch)
            set candidateRef to missing value

            try
                set candidateRef to my firstExactMatchInCollection(every menu item of containerRef, targetText)
            end try

            if candidateRef is missing value then
                try
                    set candidateRef to my firstExactMatchInCollection(every button of containerRef, targetText)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstExactMatchInCollection(every checkbox of containerRef, targetText)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstExactMatchInCollection(every UI element of containerRef, targetText)
                end try
            end if

            if candidateRef is not missing value or allowLooseMatch is false then return candidateRef

            try
                set candidateRef to my firstLooseMatchInCollection(every menu item of containerRef)
            end try

            if candidateRef is missing value then
                try
                    set candidateRef to my firstLooseMatchInCollection(every button of containerRef)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstLooseMatchInCollection(every checkbox of containerRef)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstLooseMatchInCollection(every UI element of containerRef)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstElementInCollection(every checkbox of containerRef)
                end try
            end if

            if candidateRef is missing value then
                try
                    set candidateRef to my firstElementInCollection(every button of containerRef)
                end try
            end if

            return candidateRef
        end firstDeviceElementInContainer

        on chooseDeviceFromWindow(windowRef, targetText, allowLooseMatch)
            set targetControl to missing value

            repeat 20 times
                try
                    repeat with currentScrollArea in (every scroll area of windowRef)
                        set targetControl to my firstDeviceElementInContainer(contents of currentScrollArea, targetText, false)
                        if targetControl is not missing value then exit repeat
                    end repeat
                end try

                if targetControl is missing value then
                    set targetControl to my firstDeviceElementInContainer(windowRef, targetText, false)
                end if

                if targetControl is missing value and allowLooseMatch then
                    try
                        repeat with currentScrollArea in (every scroll area of windowRef)
                            set targetControl to my firstDeviceElementInContainer(contents of currentScrollArea, targetText, true)
                            if targetControl is not missing value then exit repeat
                        end repeat
                    end try
                end if

                if targetControl is missing value and allowLooseMatch then
                    set targetControl to my firstDeviceElementInContainer(windowRef, targetText, true)
                end if

                if targetControl is not missing value then exit repeat
                delay 0.2
            end repeat

            if targetControl is missing value then error "The requested iPad was not found." number \(notFoundErrorCode)

            if my activateElement(targetControl) is false then
                error "The requested iPad could not be selected." number \(selectionFailedErrorCode)
            end if
        end chooseDeviceFromWindow

        on chooseMenuItemFromActivator(activatorRef, targetText, allowLooseMatch)
            repeat 15 times
                try
                    if exists menu 1 of activatorRef then exit repeat
                end try
                delay 0.1
            end repeat

            set targetMenuItem to missing value

            try
                set targetMenuItem to my firstDeviceElementInContainer(menu 1 of activatorRef, targetText, allowLooseMatch)
            end try

            if targetMenuItem is missing value and (my normalizedText(targetText)) is not "" then
                tell application "System Events"
                    keystroke targetText
                    delay 0.2
                    key code 36
                end tell
                return
            end if

            if targetMenuItem is missing value then error "The requested iPad was not found." number \(notFoundErrorCode)

            if my activateElement(targetMenuItem) is false then
                error "The requested iPad could not be selected." number \(selectionFailedErrorCode)
            end if
        end chooseMenuItemFromActivator
        """
    }

    private func chooseDeviceUsingAccessibility(
        in appElement: AXUIElement,
        targetDeviceLabel: String,
        allowLooseMatch: Bool,
        notFoundCode: Int,
        selectionFailedCode: Int
    ) -> Result<Void, AppleScriptExecutionError> {
        let deadline = Date().addingTimeInterval(4)
        let normalizedTarget = normalizeAccessibilityText(targetDeviceLabel)

        while Date() < deadline {
            let tree = snapshotAccessibilityTree(from: [appElement])

            if let exactMatch = pressableCandidate(
                in: tree,
                matching: normalizedTarget,
                allowLooseMatch: false
            ) {
                if performAction(on: exactMatch.element) {
                    return .success(())
                }

                return .failure(AppleScriptExecutionError(code: selectionFailedCode, message: "The requested iPad could not be selected."))
            }

            if allowLooseMatch,
               let looseMatch = pressableCandidate(
                in: tree,
                matching: normalizedTarget,
                allowLooseMatch: true
               ) {
                if performAction(on: looseMatch.element) {
                    return .success(())
                }

                return .failure(AppleScriptExecutionError(code: selectionFailedCode, message: "The requested iPad could not be selected."))
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return .failure(AppleScriptExecutionError(code: notFoundCode, message: "The requested iPad was not found."))
    }

    private func waitForPressableElement(
        in appElement: AXUIElement,
        timeout: TimeInterval,
        matchingAnyOf targetTexts: [String]
    ) -> AXElementSnapshot? {
        let normalizedTargets = targetTexts.map(normalizeAccessibilityText)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let tree = snapshotAccessibilityTree(from: [appElement])
            if let candidate = pressableElement(in: tree, matchingAnyOf: normalizedTargets) {
                return candidate
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        return nil
    }

    private func pressableElement(
        in tree: [AXElementSnapshot],
        matchingAnyOf targetTexts: [String]
    ) -> AXElementSnapshot? {
        for node in tree {
            if node.isPressable && targetTexts.contains(where: { node.contains(text: $0) }) {
                return node
            }
        }

        for index in tree.indices {
            guard targetTexts.contains(where: { tree[index].contains(text: $0) }) else {
                continue
            }

            if let resolvedIndex = resolvedPressableIndex(from: index, tree: tree) {
                return tree[resolvedIndex]
            }
        }

        return nil
    }

    private func pressableCandidate(
        in tree: [AXElementSnapshot],
        matching targetText: String,
        allowLooseMatch: Bool
    ) -> AXElementSnapshot? {
        if !targetText.isEmpty {
            for index in tree.indices {
                guard tree[index].contains(text: targetText) else { continue }
                if let resolvedIndex = resolvedPressableIndex(from: index, tree: tree) {
                    return tree[resolvedIndex]
                }
            }
        }

        guard allowLooseMatch else { return nil }

        for index in tree.indices where tree[index].isDeviceLikeLooseCandidate {
            if let resolvedIndex = resolvedPressableIndex(from: index, tree: tree) {
                return tree[resolvedIndex]
            }
        }

        for index in tree.indices where tree[index].isListCandidate {
            if let resolvedIndex = resolvedPressableIndex(from: index, tree: tree) {
                return tree[resolvedIndex]
            }
        }

        return nil
    }

    private func resolvedPressableIndex(from index: Int, tree: [AXElementSnapshot]) -> Int? {
        if tree[index].isPressable {
            return index
        }

        var ancestorIndex = tree[index].parentIndex
        while let current = ancestorIndex {
            if tree[current].isPressable {
                return current
            }
            ancestorIndex = tree[current].parentIndex
        }

        if let descendantIndex = firstPressableDescendantIndex(from: index, tree: tree, maxDepth: 2) {
            return descendantIndex
        }

        if let parentIndex = tree[index].parentIndex {
            for siblingIndex in tree[parentIndex].childIndices where siblingIndex != index {
                if tree[siblingIndex].isPressable {
                    return siblingIndex
                }

                if let descendantIndex = firstPressableDescendantIndex(from: siblingIndex, tree: tree, maxDepth: 1) {
                    return descendantIndex
                }
            }
        }

        return nil
    }

    private func firstPressableDescendantIndex(
        from index: Int,
        tree: [AXElementSnapshot],
        maxDepth: Int
    ) -> Int? {
        guard maxDepth >= 0 else { return nil }

        for childIndex in tree[index].childIndices {
            if tree[childIndex].isPressable {
                return childIndex
            }

            if let nestedMatch = firstPressableDescendantIndex(from: childIndex, tree: tree, maxDepth: maxDepth - 1) {
                return nestedMatch
            }
        }

        return nil
    }

    private func performAction(on element: AXUIElement) -> Bool {
        let prioritizedActions = ["AXPress", "AXShowMenu", "AXConfirm"]
        let availableActions = actionNames(for: element)

        for action in prioritizedActions where availableActions.contains(action) {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return true
            }
        }

        for action in availableActions {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return true
            }
        }

        return false
    }

    private func snapshotAccessibilityTree(from roots: [AXUIElement]) -> [AXElementSnapshot] {
        var snapshots: [AXElementSnapshot] = []
        var visited = Set<Int>()

        @discardableResult
        func appendSnapshot(for element: AXUIElement, parentIndex: Int?) -> Int? {
            let elementHash = Int(CFHash(element))
            guard !visited.contains(elementHash), snapshots.count < 2400 else {
                return nil
            }

            visited.insert(elementHash)

            let currentIndex = snapshots.count
            snapshots.append(
                AXElementSnapshot(
                    element: element,
                    parentIndex: parentIndex,
                    childIndices: [],
                    role: axStringAttribute("AXRole", on: element),
                    subrole: axStringAttribute("AXSubrole", on: element),
                    title: axStringAttribute("AXTitle", on: element),
                    elementDescription: axStringAttribute("AXDescription", on: element),
                    value: axStringAttribute("AXValue", on: element),
                    identifier: axStringAttribute("AXIdentifier", on: element),
                    help: axStringAttribute("AXHelp", on: element),
                    actions: actionNames(for: element)
                )
            )

            var childIndices: [Int] = []
            for child in childElements(of: element) {
                if let childIndex = appendSnapshot(for: child, parentIndex: currentIndex) {
                    childIndices.append(childIndex)
                }
            }

            snapshots[currentIndex].childIndices = childIndices
            return currentIndex
        }

        for root in roots {
            _ = appendSnapshot(for: root, parentIndex: nil)
        }

        return snapshots
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        let singleAttributes = [
            "AXMenuBar",
            "AXFocusedWindow",
            "AXMainWindow",
            "AXMenu"
        ]
        let arrayAttributes = [
            "AXChildren",
            "AXVisibleChildren",
            "AXWindows",
            "AXSheets",
            "AXRows",
            "AXTabs",
            "AXSelectedChildren",
            "AXContents"
        ]

        var children: [AXUIElement] = []
        var seen = Set<Int>()

        for attribute in singleAttributes {
            if let child = axElementAttribute(attribute, on: element) {
                let childHash = Int(CFHash(child))
                if !seen.contains(childHash) {
                    seen.insert(childHash)
                    children.append(child)
                }
            }
        }

        for attribute in arrayAttributes {
            for child in axElementArrayAttribute(attribute, on: element) {
                let childHash = Int(CFHash(child))
                if !seen.contains(childHash) {
                    seen.insert(childHash)
                    children.append(child)
                }
            }
        }

        return children
    }

    private func runningApplication(
        bundleIdentifiers: [String],
        localizedNames: [String]
    ) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if let bundleIdentifier = app.bundleIdentifier,
               bundleIdentifiers.contains(bundleIdentifier) {
                return true
            }

            if let localizedName = app.localizedName,
               localizedNames.contains(localizedName) {
                return true
            }

            return false
        }
    }

    private func waitForRunningApplication(
        bundleIdentifiers: [String],
        localizedNames: [String],
        timeout: TimeInterval
    ) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let app = runningApplication(bundleIdentifiers: bundleIdentifiers, localizedNames: localizedNames) {
                return app
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return nil
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var actionsValue: CFArray?
        let result = AXUIElementCopyActionNames(element, &actionsValue)
        guard result == .success,
              let actionsArray = actionsValue as? [String] else {
            return []
        }

        return actionsArray
    }

    private func axElementAttribute(_ attribute: String, on element: AXUIElement) -> AXUIElement? {
        guard let value = axAttributeValue(attribute, on: element) else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(cfValue, to: AXUIElement.self)
    }

    private func axElementArrayAttribute(_ attribute: String, on element: AXUIElement) -> [AXUIElement] {
        guard let value = axAttributeValue(attribute, on: element) else { return [] }

        if let elements = value as? [AXUIElement] {
            return elements
        }

        if let objects = value as? [Any] {
            return objects.compactMap { object in
                let cfValue = object as CFTypeRef
                guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
                return unsafeBitCast(cfValue, to: AXUIElement.self)
            }
        }

        return []
    }

    private func axStringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        guard let value = axAttributeValue(attribute, on: element) else { return nil }

        if let string = value as? String {
            return string.nilIfEmpty
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func axAttributeValue(_ attribute: String, on element: AXUIElement) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func normalizeAccessibilityText(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct AXElementSnapshot {
    let element: AXUIElement
    let parentIndex: Int?
    var childIndices: [Int]
    let role: String?
    let subrole: String?
    let title: String?
    let elementDescription: String?
    let value: String?
    let identifier: String?
    let help: String?
    let actions: [String]

    var searchableTexts: [String] {
        [title, elementDescription, value, identifier, help, role, subrole]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isPressable: Bool {
        if actions.contains("AXPress") || actions.contains("AXShowMenu") || actions.contains("AXConfirm") {
            return true
        }

        switch role {
        case "AXButton", "AXCheckBox", "AXMenuBarItem", "AXMenuItem", "AXPopUpButton", "AXRadioButton":
            return true
        default:
            return false
        }
    }

    var isDeviceLikeLooseCandidate: Bool {
        guard isPressable else { return false }

        for text in searchableTexts {
            let normalizedText = text.lowercased()
            if ignoredLooseMatchLabels.contains(normalizedText) {
                continue
            }

            if normalizedText.contains("ipad") || normalizedText.contains("sidecar") {
                return true
            }
        }

        return false
    }

    var isListCandidate: Bool {
        guard isPressable else { return false }

        return searchableTexts.contains { text in
            let normalizedText = text.lowercased()
            return !normalizedText.isEmpty && !ignoredLooseMatchLabels.contains(normalizedText)
        }
    }

    func contains(text normalizedTarget: String) -> Bool {
        guard !normalizedTarget.isEmpty else { return false }

        return searchableTexts.contains { text in
            let normalizedText = text.lowercased()
            return normalizedText == normalizedTarget ||
                normalizedText.contains(normalizedTarget) ||
                normalizedTarget.contains(normalizedText)
        }
    }

    private var ignoredLooseMatchLabels: Set<String> {
        [
            "screen mirroring",
            "control center",
            "control centre",
            "display settings...",
            "display settings…",
            "displays",
            "add display",
            "link keyboard and mouse",
            "airplay audio",
            "wi-fi",
            "focus",
            "bluetooth",
            "airdrop"
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
