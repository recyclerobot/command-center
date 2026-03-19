import Cocoa
import ServiceManagement

class MenuBarController {
    private let statusItem: NSStatusItem
    private let profileStore = ProfileStore.shared
    private let windowManager = WindowManager.shared
    private let screenshotMonitor = ScreenshotClipboardMonitor.shared

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

        if windows.isEmpty {
            showAlert(title: "No Windows Found", message: "No application windows were detected. Make sure Accessibility permissions are granted in System Settings > Privacy & Security > Accessibility.")
            return
        }

        // Ask for profile name
        let alert = NSAlert()
        alert.messageText = "Save Window Layout"
        alert.informativeText = "Enter a name for this profile (\(windows.count) windows captured):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "e.g., Development, Writing, Design"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                showAlert(title: "Invalid Name", message: "Please enter a profile name.")
                return
            }

            let profile = WindowProfile(name: name, windows: windows)
            profileStore.save(profile: profile)
            rebuildMenu()
        }
    }

    @objc private func restoreProfile(_ sender: NSMenuItem) {
        guard let profileId = sender.representedObject as? String,
              let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        if !checkAccessibility() { return }

        let result = windowManager.restoreWindows(from: profile)

        if result.skipped > 0 {
            showAlert(
                title: "Layout Restored",
                message: "Restored \(result.restored) window(s). Skipped \(result.skipped) window(s) — their apps may not be running."
            )
        }
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
}
