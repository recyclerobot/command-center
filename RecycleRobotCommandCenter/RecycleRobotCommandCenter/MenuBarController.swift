import Cocoa
import ServiceManagement

class MenuBarController {
    private struct NewProfileDetails {
        let name: String
        let sidecarTargetDisplay: DisplaySnapshot?
        let sidecarTargetDeviceName: String?
    }

    private struct ProfileUpdateDetails {
        let sidecarTargetDisplay: DisplaySnapshot?
        let sidecarTargetDeviceName: String?
    }

    private enum RestorePresentation {
        case none
        case badge(String)
        case alert(title: String, message: String)
    }

    private let statusItem: NSStatusItem
    private let profileStore = ProfileStore.shared
    private let windowManager = WindowManager.shared
    private let screenshotMonitor = ScreenshotClipboardMonitor.shared
    private var transientBadgeWindow: NSPanel?
    private var transientBadgeDismissWorkItem: DispatchWorkItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🤖"
            button.toolTip = "recyclerobot command center"
        }

        rebuildMenu()
    }

    // MARK: - Menu Construction

    func rebuildMenu() {
        let menu = NSMenu()
        menu.title = "recyclerobot command center"

        // Title
        let titleItem = NSMenuItem(title: "🤖 recyclerobot command center", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // Save current layout
        let saveItem = NSMenuItem(title: "Save Current Window Layout…", action: #selector(saveProfile), keyEquivalent: "s")
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())

        // Profiles submenu
        let profiles = profileStore.profiles
        if profiles.isEmpty {
            let emptyItem = NSMenuItem(title: "No saved profiles", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let headerItem = NSMenuItem(title: "Restore Profile:", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            for profile in profiles {
                let profileItem = NSMenuItem(title: profile.name, action: #selector(restoreProfile(_:)), keyEquivalent: "")
                profileItem.target = self
                profileItem.representedObject = profile.id
                profileItem.indentationLevel = 1

                // Submenu for profile actions
                let subMenu = NSMenu()

                let restoreAction = NSMenuItem(title: "Restore", action: #selector(restoreProfile(_:)), keyEquivalent: "")
                restoreAction.target = self
                restoreAction.representedObject = profile.id
                subMenu.addItem(restoreAction)

                let overwriteAction = NSMenuItem(title: "Update with Current Layout", action: #selector(overwriteProfile(_:)), keyEquivalent: "")
                overwriteAction.target = self
                overwriteAction.representedObject = profile.id
                subMenu.addItem(overwriteAction)

                let renameAction = NSMenuItem(title: "Rename…", action: #selector(renameProfile(_:)), keyEquivalent: "")
                renameAction.target = self
                renameAction.representedObject = profile.id
                subMenu.addItem(renameAction)

                subMenu.addItem(NSMenuItem.separator())

                let deleteAction = NSMenuItem(title: "Delete", action: #selector(deleteProfile(_:)), keyEquivalent: "")
                deleteAction.target = self
                deleteAction.representedObject = profile.id
                subMenu.addItem(deleteAction)

                profileItem.submenu = subMenu
                menu.addItem(profileItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(launchAtLoginItem)

        settingsMenu.addItem(NSMenuItem.separator())

        let screenshotToggle = NSMenuItem(title: "Save Screenshots to Folder", action: #selector(toggleScreenshotSave(_:)), keyEquivalent: "")
        screenshotToggle.target = self
        screenshotToggle.state = screenshotMonitor.isEnabled ? .on : .off
        settingsMenu.addItem(screenshotToggle)

        let folderLabel: String
        if let folder = screenshotMonitor.saveFolder {
            let folderName = (folder as NSString).lastPathComponent
            folderLabel = "Save Folder: \(folderName)"
        } else {
            folderLabel = "Choose Save Folder…"
        }
        let chooseFolderItem = NSMenuItem(title: folderLabel, action: #selector(chooseScreenshotFolder), keyEquivalent: "")
        chooseFolderItem.target = self
        chooseFolderItem.indentationLevel = 1
        settingsMenu.addItem(chooseFolderItem)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func saveProfile() {
        // Check accessibility first
        if !checkAccessibility() { return }

        let windows = windowManager.captureWindows()
        let displays = windowManager.currentDisplays()

        if windows.isEmpty {
            showAlert(title: "No Windows Found", message: "No application windows were detected. Make sure Accessibility permissions are granted in System Settings > Privacy & Security > Accessibility.")
            return
        }

        guard let details = promptForNewProfile(windows: windows, displays: displays) else { return }

        let profile = WindowProfile(
            name: details.name,
            windows: windows,
            displays: displays,
            sidecarTargetDisplay: details.sidecarTargetDisplay,
            sidecarTargetDeviceName: details.sidecarTargetDeviceName
        )
        profileStore.save(profile: profile)
        rebuildMenu()
    }

    @objc private func restoreProfile(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String,
              let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        if !checkAccessibility() { return }

        let result = windowManager.restoreWindows(from: profile)

        switch restoreFeedback(for: profile, result: result) {
        case .none:
            break
        case .badge(let message):
            showTransientBadge(message: message)
        case .alert(let title, let message):
            showAlert(title: title, message: message)
        }
    }

    @objc private func overwriteProfile(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String,
              let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        if !checkAccessibility() { return }

        let windows = windowManager.captureWindows()
        let displays = windowManager.currentDisplays()

        if windows.isEmpty {
            showAlert(title: "No Windows Found", message: "No application windows were detected.")
            return
        }

        guard let updateDetails = promptForProfileUpdate(profile: profile, windows: windows, displays: displays) else {
            return
        }

        profileStore.update(
            profileId: profileId,
            windows: windows,
            displays: displays,
            sidecarTargetDisplay: updateDetails.sidecarTargetDisplay,
            sidecarTargetDeviceName: updateDetails.sidecarTargetDeviceName
        )
        rebuildMenu()
    }

    @objc private func renameProfile(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String,
              let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Profile"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = profile.name
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            profileStore.rename(profileId: profileId, newName: newName)
            rebuildMenu()
        }
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String,
              let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Profile"
        alert.informativeText = "Are you sure you want to delete \"\(profile.name)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            profileStore.delete(profileId: profileId)
            rebuildMenu()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Launch at Login", message: "Failed to update login item: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func toggleScreenshotSave(_ sender: NSMenuItem) {
        if !screenshotMonitor.isEnabled {
            // Turning on — ensure a folder is selected first
            if screenshotMonitor.saveFolder == nil {
                if !pickScreenshotFolder() {
                    return // user cancelled
                }
            }
            screenshotMonitor.isEnabled = true
        } else {
            screenshotMonitor.isEnabled = false
        }
        rebuildMenu()
    }

    @objc private func chooseScreenshotFolder() {
        _ = pickScreenshotFolder()
        rebuildMenu()
    }

    private func pickScreenshotFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a folder to save screenshots to:"

        if let current = screenshotMonitor.saveFolder {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()

        if response == .OK, let url = panel.url {
            screenshotMonitor.saveFolder = url.path
            return true
        }
        return false
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            showAlert(
                title: "Accessibility Permission Required",
                message: "Please grant Accessibility access in System Settings > Privacy & Security > Accessibility, then relaunch the app."
            )
        }
        return trusted
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showTransientBadge(message: String) {
        transientBadgeDismissWorkItem?.cancel()
        dismissTransientBadge(animated: false)

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 8
        let minimumWidth: CGFloat = 150
        let maximumWidth: CGFloat = 320
        let labelSize = label.intrinsicContentSize
        let badgeWidth = min(max(labelSize.width + (horizontalPadding * 2), minimumWidth), maximumWidth)
        let badgeHeight = labelSize.height + (verticalPadding * 2)
        let badgeSize = NSSize(width: badgeWidth, height: badgeHeight)

        let contentView = NSVisualEffectView(frame: NSRect(origin: .zero, size: badgeSize))
        contentView.material = .hudWindow
        contentView.blendingMode = .withinWindow
        contentView.state = .active
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = badgeHeight / 2
        contentView.layer?.masksToBounds = true

        label.frame = NSRect(
            x: horizontalPadding,
            y: (badgeHeight - labelSize.height) / 2,
            width: badgeWidth - (horizontalPadding * 2),
            height: labelSize.height
        )
        contentView.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: badgeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
        panel.contentView = contentView
        panel.setFrameOrigin(transientBadgeOrigin(for: badgeSize))
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        transientBadgeWindow = panel

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismissTransientBadge(animated: true)
        }
        transientBadgeDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismissWorkItem)
    }

    private func dismissTransientBadge(animated: Bool) {
        transientBadgeDismissWorkItem?.cancel()
        transientBadgeDismissWorkItem = nil

        guard let badgeWindow = transientBadgeWindow else { return }
        transientBadgeWindow = nil

        let closeWindow = {
            badgeWindow.orderOut(nil)
        }

        guard animated else {
            closeWindow()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            badgeWindow.animator().alphaValue = 0
        }, completionHandler: closeWindow)
    }

    private func transientBadgeOrigin(for badgeSize: NSSize) -> NSPoint {
        if let button = statusItem.button,
           let buttonWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

            let unclampedX = buttonFrameOnScreen.midX - (badgeSize.width / 2)
            let x = min(max(unclampedX, visibleFrame.minX + 12), visibleFrame.maxX - badgeSize.width - 12)
            let y = max(visibleFrame.minY + 12, buttonFrameOnScreen.minY - badgeSize.height - 8)
            return NSPoint(x: x, y: y)
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: visibleFrame.maxX - badgeSize.width - 24,
            y: visibleFrame.maxY - badgeSize.height - 24
        )
    }

    private func promptForNewProfile(
        windows: [WindowSnapshot],
        displays: [DisplaySnapshot]
    ) -> NewProfileDetails? {
        let alert = NSAlert()
        alert.messageText = "Save Window Layout"
        alert.informativeText = "Enter a name for this profile (\(windows.count) windows captured):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = "e.g., Development, Writing, Design"

        let (accessoryView, popupButton, deviceNameField, options) = makeProfileAccessoryView(
            displays: displays,
            windows: windows,
            existingTargetName: nil,
            existingTargetIdentifier: nil,
            existingTargetDisplayID: nil,
            existingTargetDeviceName: nil,
            includeNameField: textField
        )

        alert.accessoryView = accessoryView
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else { return nil }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showAlert(title: "Invalid Name", message: "Please enter a profile name.")
            return nil
        }

        let selectedDisplay = selectedDisplay(from: popupButton, options: options)
        return NewProfileDetails(
            name: name,
            sidecarTargetDisplay: selectedDisplay,
            sidecarTargetDeviceName: normalizedSidecarDeviceName(
                rawValue: deviceNameField.stringValue,
                selectedDisplay: selectedDisplay
            )
        )
    }

    private func promptForProfileUpdate(
        profile: WindowProfile,
        windows: [WindowSnapshot],
        displays: [DisplaySnapshot]
    ) -> ProfileUpdateDetails? {
        let alert = NSAlert()
        alert.messageText = "Update Profile"
        alert.informativeText = "Replace \"\(profile.name)\" with the current window layout (\(windows.count) windows)?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")

        let (accessoryView, popupButton, deviceNameField, options) = makeProfileAccessoryView(
            displays: displays,
            windows: windows,
            existingTargetName: profile.sidecarTargetDisplayName,
            existingTargetIdentifier: profile.sidecarTargetDisplayIdentifier,
            existingTargetDisplayID: profile.sidecarTargetDisplayID,
            existingTargetDeviceName: profile.sidecarTargetDeviceName,
            includeNameField: nil
        )

        alert.accessoryView = accessoryView

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else { return nil }
        let selectedDisplay = selectedDisplay(from: popupButton, options: options)
        return ProfileUpdateDetails(
            sidecarTargetDisplay: selectedDisplay,
            sidecarTargetDeviceName: normalizedSidecarDeviceName(
                rawValue: deviceNameField.stringValue,
                selectedDisplay: selectedDisplay
            )
        )
    }

    private func makeProfileAccessoryView(
        displays: [DisplaySnapshot],
        windows: [WindowSnapshot],
        existingTargetName: String?,
        existingTargetIdentifier: String?,
        existingTargetDisplayID: Int?,
        existingTargetDeviceName: String?,
        includeNameField: NSTextField?
    ) -> (NSView, NSPopUpButton, NSTextField, [DisplaySnapshot]) {
        let accessoryWidth: CGFloat = 340
        let fieldWidth: CGFloat = 320
        let secondaryDisplays = displays.filter { !$0.isPrimary }
        let popupButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popupButton.translatesAutoresizingMaskIntoConstraints = false
        popupButton.addItem(withTitle: "None")

        for display in secondaryDisplays {
            popupButton.addItem(withTitle: display.name)
        }

        let sidecarLabel = NSTextField(labelWithString: "Auto-start this display when the layout needs it:")
        sidecarLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sidecarLabel.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: secondaryDisplays.isEmpty
            ? "No secondary displays are connected right now."
            : "Choose the iPad display this profile should reconnect during restore.")
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let deviceNameLabel = NSTextField(labelWithString: "Sidecar device name in Screen Mirroring (optional):")
        deviceNameLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false

        let deviceNameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        deviceNameField.placeholderString = "e.g., Jarne's iPad"
        deviceNameField.stringValue = existingTargetDeviceName ?? fallbackDeviceName(
            from: existingTargetName,
            selectedDisplays: secondaryDisplays
        )
        deviceNameField.translatesAutoresizingMaskIntoConstraints = false

        let deviceHintLabel = NSTextField(labelWithString:
            "Use the exact iPad name shown in Screen Mirroring. Leave blank to use best-effort matching."
        )
        deviceHintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        deviceHintLabel.textColor = .secondaryLabelColor
        deviceHintLabel.lineBreakMode = .byWordWrapping
        deviceHintLabel.maximumNumberOfLines = 0
        deviceHintLabel.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        if let nameField = includeNameField {
            let nameLabel = NSTextField(labelWithString: "Profile name:")
            nameLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameField.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(nameLabel)
            stackView.addArrangedSubview(nameField)
        }

        stackView.addArrangedSubview(sidecarLabel)
        stackView.addArrangedSubview(popupButton)
        stackView.addArrangedSubview(hintLabel)
        stackView.addArrangedSubview(deviceNameLabel)
        stackView.addArrangedSubview(deviceNameField)
        stackView.addArrangedSubview(deviceHintLabel)

        if let selectionIndex = preferredSidecarSelectionIndex(
            displays: secondaryDisplays,
            windows: windows,
            existingTargetName: existingTargetName,
            existingTargetIdentifier: existingTargetIdentifier,
            existingTargetDisplayID: existingTargetDisplayID
        ) {
            popupButton.selectItem(at: selectionIndex)
        } else {
            popupButton.selectItem(at: 0)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 10))
        container.addSubview(stackView)

        var constraints: [NSLayoutConstraint] = [
            container.widthAnchor.constraint(equalToConstant: accessoryWidth),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            popupButton.widthAnchor.constraint(equalToConstant: fieldWidth),
            deviceNameField.widthAnchor.constraint(equalToConstant: fieldWidth),
            sidecarLabel.widthAnchor.constraint(equalToConstant: accessoryWidth),
            hintLabel.widthAnchor.constraint(equalToConstant: accessoryWidth),
            deviceNameLabel.widthAnchor.constraint(equalToConstant: accessoryWidth),
            deviceHintLabel.widthAnchor.constraint(equalToConstant: accessoryWidth),
        ]

        if let nameField = includeNameField {
            constraints.append(nameField.widthAnchor.constraint(equalToConstant: fieldWidth))
        }

        NSLayoutConstraint.activate(constraints)
        container.layoutSubtreeIfNeeded()
        let fittingSize = container.fittingSize
        container.frame = NSRect(origin: .zero, size: fittingSize)

        return (container, popupButton, deviceNameField, secondaryDisplays)
    }

    private func preferredSidecarSelectionIndex(
        displays: [DisplaySnapshot],
        windows: [WindowSnapshot],
        existingTargetName: String?,
        existingTargetIdentifier: String?,
        existingTargetDisplayID: Int?
    ) -> Int? {
        if let existingMatchIndex = displays.firstIndex(where: {
            displayMatches(
                $0,
                name: existingTargetName,
                identifier: existingTargetIdentifier,
                displayID: existingTargetDisplayID
            )
        }) {
            return existingMatchIndex + 1
        }

        if let inferredSidecarIndex = displays.firstIndex(where: { display in
            DisplayLayoutSupport.isLikelySidecarDisplayName(display.name) &&
            windows.contains {
                displayMatches(
                    display,
                    name: $0.displayName,
                    identifier: $0.displayIdentifier,
                    displayID: $0.displayID
                )
            }
        }) {
            return inferredSidecarIndex + 1
        }

        let displaysWithWindows = displays.filter { display in
            windows.contains {
                displayMatches(
                    display,
                    name: $0.displayName,
                    identifier: $0.displayIdentifier,
                    displayID: $0.displayID
                )
            }
        }

        if displaysWithWindows.count == 1,
           let smartDefaultIndex = displays.firstIndex(of: displaysWithWindows[0]) {
            return smartDefaultIndex + 1
        }

        return 0
    }

    private func selectedDisplay(from popupButton: NSPopUpButton, options: [DisplaySnapshot]) -> DisplaySnapshot? {
        let index = popupButton.indexOfSelectedItem
        guard index > 0, index - 1 < options.count else { return nil }
        return options[index - 1]
    }

    private func fallbackDeviceName(from existingTargetName: String?, selectedDisplays: [DisplaySnapshot]) -> String {
        if let existingTargetName,
           !DisplayLayoutSupport.isGenericSidecarDisplayName(existingTargetName) {
            return existingTargetName
        }

        if let singleSidecarDisplay = selectedDisplays.first(where: { DisplayLayoutSupport.isLikelySidecarDisplayName($0.name) }),
           !DisplayLayoutSupport.isGenericSidecarDisplayName(singleSidecarDisplay.name) {
            return singleSidecarDisplay.name
        }

        return ""
    }

    private func normalizedSidecarDeviceName(rawValue: String, selectedDisplay: DisplaySnapshot?) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let selectedDisplay,
           !DisplayLayoutSupport.isLikelySidecarDisplayName(selectedDisplay.name),
           DisplayLayoutSupport.isLikelySidecarDisplayName(trimmed) {
            return nil
        }

        return trimmed
    }

    private func displayMatches(
        _ display: DisplaySnapshot,
        name: String?,
        identifier: String?,
        displayID: Int?
    ) -> Bool {
        if let identifier, display.identifier == identifier {
            return true
        }

        if let displayID, display.displayID == displayID {
            return true
        }

        if let name, display.name == name {
            return true
        }

        return false
    }

    private func restoreFeedback(
        for profile: WindowProfile,
        result: WindowRestoreResult
    ) -> RestorePresentation {
        let sidecarNeedsAlert: Bool
        if let sidecarConnection = result.sidecarConnection {
            switch sidecarConnection.status {
            case .alreadyAvailable, .connected:
                sidecarNeedsAlert = false
            default:
                sidecarNeedsAlert = true
            }
        } else {
            sidecarNeedsAlert = false
        }

        guard sidecarNeedsAlert || result.skippedTotal > 0 else {
            guard result.restored > 0 else { return .none }

            var badgeParts = ["Restored \(result.restored) window(s)"]
            if let sidecarConnection = result.sidecarConnection,
               sidecarConnection.didConnect,
               sidecarConnection.attempted {
                badgeParts.append("Sidecar connected")
            }
            return .badge(badgeParts.joined(separator: " • "))
        }

        var parts: [String] = []

        if let sidecarConnection = result.sidecarConnection {
            parts.append(sidecarConnection.message)
        }

        parts.append("Restored \(result.restored) window(s).")

        if result.skippedAppNotRunning > 0 {
            parts.append("Skipped \(result.skippedAppNotRunning) window(s) because their apps were not running.")
        }

        if result.skippedDisplayUnavailable > 0 {
            parts.append("Skipped \(result.skippedDisplayUnavailable) window(s) because their saved display was unavailable.")
        }

        if let legacyMessage = profile.legacyRestoreMessage {
            parts.append(legacyMessage)
        }

        let title = result.skippedTotal > 0 ? "Layout Partially Restored" : "Layout Restored"
        return .alert(title: title, message: parts.joined(separator: " "))
    }
}
