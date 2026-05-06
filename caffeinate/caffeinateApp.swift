import SwiftUI
import Security
import ServiceManagement
import IOKit.pwr_mgt
import IOKit.ps

@Observable
final class SleepManager {
    // MARK: User intent (UI-bound)

    var preventIdleSleep: Bool = false {
        didSet {
            guard !suppressDidSet, oldValue != preventIdleSleep else { return }
            applyIdleSleep()
        }
    }

    var disableSystemSleep: Bool = false {
        didSet {
            guard !suppressDidSet, oldValue != disableSystemSleep else { return }
            applySystemSleep(userInitiated: true, previousIntent: oldValue)
        }
    }

    // MARK: Low-battery protection (persisted)

    var batteryProtectionEnabled: Bool = UserDefaults.standard.object(forKey: "batteryProtectionEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(batteryProtectionEnabled, forKey: "batteryProtectionEnabled")
            evaluateBattery()
        }
    }

    var batteryThreshold: Int = UserDefaults.standard.object(forKey: "batteryThreshold") as? Int ?? 20 {
        didSet {
            UserDefaults.standard.set(batteryThreshold, forKey: "batteryThreshold")
            evaluateBattery()
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool = false {
        didSet {
            guard !suppressDidSet, oldValue != launchAtLogin else { return }
            applyLaunchAtLogin(previous: oldValue)
        }
    }

    // MARK: Observable status

    private(set) var batteryLevel: Int = 100
    private(set) var isOnBattery: Bool = false
    private(set) var hasBattery: Bool = false
    private(set) var batterySuppressing: Bool = false
    private(set) var pmsetDisabled: Bool = false

    var anyActive: Bool { assertionID != 0 || pmsetDisabled }

    // MARK: Internals

    private var assertionID: IOPMAssertionID = 0
    private var sharedAuth: AuthorizationRef?
    private var batterySource: CFRunLoopSource?
    private var suppressDidSet = false

    init() {
        refreshPmsetState()
        // Sync intent to actual pmset state (e.g., previously toggled on and persisted across reboots).
        if pmsetDisabled {
            suppressDidSet = true
            disableSystemSleep = true
            suppressDidSet = false
        }
        refreshBattery()
        evaluateBattery()
        startBatteryMonitor()
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled {
            suppressDidSet = true
            launchAtLogin = enabled
            suppressDidSet = false
        }
    }

    private func applyLaunchAtLogin(previous: Bool) {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    showError("Caffeinate needs approval in System Settings → General → Login Items to launch at login.")
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            suppressDidSet = true
            launchAtLogin = previous
            suppressDidSet = false
            showError("Couldn't update login item: \(error.localizedDescription)")
        }
    }

    deinit {
        if let auth = sharedAuth { AuthorizationFree(auth, [.destroyRights]) }
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        if let src = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    // MARK: Idle sleep (IOPMAssertion)

    private func applyIdleSleep() {
        let want = preventIdleSleep && !batterySuppressing
        let have = assertionID != 0
        guard want != have else { return }
        if want {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Caffeinate is preventing sleep" as CFString,
                &id
            )
            if r == kIOReturnSuccess { assertionID = id }
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    // MARK: System sleep (pmset)

    private func applySystemSleep(userInitiated: Bool, previousIntent: Bool) {
        let want = disableSystemSleep && !batterySuppressing
        guard want != pmsetDisabled else { return }
        do {
            try setDisableSleep(want)
            pmsetDisabled = want
        } catch {
            refreshPmsetState()
            if userInitiated {
                // Revert toggle so UI matches reality.
                suppressDidSet = true
                disableSystemSleep = previousIntent
                suppressDidSet = false
                showError(error.localizedDescription)
            } else {
                // Battery-driven; surface a notification but keep intent.
                showError("Battery is low but Caffeinate couldn't update pmset: \(error.localizedDescription)")
            }
        }
    }

    func refreshPmsetState() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        pmsetDisabled = output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Caffeinate"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Battery monitoring

    private static let batteryCallback: IOPowerSourceCallbackType = { ctx in
        guard let ctx else { return }
        let manager = Unmanaged<SleepManager>.fromOpaque(ctx).takeUnretainedValue()
        manager.refreshBattery()
        manager.evaluateBattery()
    }

    private func startBatteryMonitor() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource(Self.batteryCallback, ctx)?.takeRetainedValue() {
            batterySource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private func refreshBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        var level: Int?
        var onBattery = false
        var found = false

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            found = true
            if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int, maxCap > 0 {
                level = Int((Double(current) / Double(maxCap)) * 100)
            }
            if let state = desc[kIOPSPowerSourceStateKey as String] as? String,
               state == (kIOPSBatteryPowerValue as String) {
                onBattery = true
            }
        }

        hasBattery = found
        if let level { batteryLevel = level }
        isOnBattery = onBattery
    }

    private func evaluateBattery() {
        let suppressing = batteryProtectionEnabled && hasBattery && isOnBattery && batteryLevel < batteryThreshold
        guard suppressing != batterySuppressing else { return }
        batterySuppressing = suppressing
        applyIdleSleep()
        applySystemSleep(userInitiated: false, previousIntent: disableSystemSleep)
    }

    // MARK: Authorization

    struct PmsetError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { self.errorDescription = message }
    }

    private func acquireAuth() throws -> AuthorizationRef {
        var item = AuthorizationItem(
            name: kAuthorizationRightExecute, valueLength: 0, value: nil, flags: 0
        )

        if let existing = sharedAuth {
            let status = withUnsafeMutablePointer(to: &item) { ptr -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: ptr)
                return AuthorizationCopyRights(existing, &rights, nil, [.extendRights], nil)
            }
            if status == errAuthorizationSuccess { return existing }
            AuthorizationFree(existing, [.destroyRights])
            sharedAuth = nil
        }

        var newAuth: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &newAuth)
        guard createStatus == errAuthorizationSuccess, let auth = newAuth else {
            throw PmsetError("AuthorizationCreate failed (\(createStatus))")
        }

        let copyStatus = withUnsafeMutablePointer(to: &item) { ptr -> OSStatus in
            var rights = AuthorizationRights(count: 1, items: ptr)
            return AuthorizationCopyRights(
                auth, &rights, nil,
                [.interactionAllowed, .extendRights, .preAuthorize], nil
            )
        }
        guard copyStatus == errAuthorizationSuccess else {
            AuthorizationFree(auth, [])
            if copyStatus == errAuthorizationCanceled {
                throw PmsetError("Authorization canceled.")
            }
            throw PmsetError("AuthorizationCopyRights failed (\(copyStatus)). If this persists, make sure App Sandbox is disabled in Signing & Capabilities.")
        }

        sharedAuth = auth
        return auth
    }

    private func setDisableSleep(_ disable: Bool) throws {
        let auth = try acquireAuth()

        typealias AEWP = @convention(c) (
            AuthorizationRef, UnsafePointer<CChar>, UInt32,
            UnsafePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutableRawPointer?
        ) -> OSStatus

        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
            ?? dlopen(nil, RTLD_NOW)
        guard let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
            throw PmsetError("AuthorizationExecuteWithPrivileges symbol not found.")
        }
        let execute = unsafeBitCast(sym, to: AEWP.self)

        let args: [UnsafeMutablePointer<CChar>?] = [
            strdup("-a"), strdup("disablesleep"), strdup(disable ? "1" : "0"), nil
        ]
        defer { args.compactMap { $0 }.forEach { free($0) } }

        let execStatus = args.withUnsafeBufferPointer { buf in
            execute(auth, "/usr/bin/pmset", 0, buf.baseAddress!, nil)
        }
        guard execStatus == errAuthorizationSuccess else {
            throw PmsetError("pmset execution failed (\(execStatus)).")
        }
    }
}

struct CaffeinateView: View {
    @Bindable var manager: SleepManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $manager.preventIdleSleep) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prevent idle sleep")
                        Text("Uses IOPMAssertion — no password required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $manager.disableSystemSleep) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disable all sleep")
                        Text("Runs pmset -a disablesleep · requires admin password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Sleep prevention", systemImage: "moon.zzz.fill")
            }

            Section {
                Toggle(isOn: $manager.batteryProtectionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable")
                        Text("Pauses sleep prevention so the Mac can sleep when battery is low.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!manager.hasBattery)

                LabeledContent("Allow sleep below") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(manager.batteryThreshold) },
                                set: { manager.batteryThreshold = Self.clamp(Int($0.rounded())) }
                            ),
                            in: 5...95
                        )
                        .frame(minWidth: 120)

                        TextField("", value: Binding(
                            get: { manager.batteryThreshold },
                            set: { manager.batteryThreshold = Self.clamp($0) }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)

                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!manager.batteryProtectionEnabled || !manager.hasBattery)

                if manager.batterySuppressing {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Sleep prevention paused — battery below \(manager.batteryThreshold)%.")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            } header: {
                Label("Low-battery protection", systemImage: "battery.75")
            } footer: {
                HStack(spacing: 6) {
                    Image(systemName: batteryIcon)
                        .foregroundStyle(batteryColor)
                    Text("\(manager.batteryLevel)%")
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(manager.hasBattery
                         ? (manager.isOnBattery ? "on battery" : "on AC")
                         : "no battery")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Section {
                Toggle(isOn: $manager.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Open Caffeinate automatically when you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("General", systemImage: "gearshape.fill")
            }

            Section {
                Button {
                    manager.refreshPmsetState()
                } label: {
                    Label("Refresh from pmset", systemImage: "arrow.clockwise")
                }
            }

            Section {
                LabeledContent("Version", value: Self.versionString)
                LabeledContent("Commit", value: Self.commitString)
                    .textSelection(.enabled)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 460)
    }

    private static func clamp(_ v: Int) -> Int { max(5, min(95, v)) }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return short == build ? short : "\(short) (\(build))"
    }

    private static var commitString: String {
        Bundle.main.infoDictionary?["GitCommit"] as? String ?? "unknown"
    }

    private var batteryIcon: String {
        guard manager.hasBattery else { return "bolt.horizontal" }
        switch manager.batteryLevel {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var batteryColor: Color {
        guard manager.hasBattery else { return .secondary }
        if manager.isOnBattery, manager.batteryLevel < manager.batteryThreshold { return .orange }
        return .secondary
    }
}

struct MenuContent: View {
    @Bindable var manager: SleepManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(isOn: $manager.preventIdleSleep) {
            Text("Prevent idle sleep")
        }

        Toggle(isOn: $manager.disableSystemSleep) {
            Text("Disable all sleep (pmset)")
        }

        if manager.batterySuppressing {
            Divider()
            Text("Paused — battery at \(manager.batteryLevel)%")
        }

        Divider()

        Button("Open Caffeinate…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            manager.preventIdleSleep = false
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@main
struct caffeinateApp: App {
    @State private var manager = SleepManager()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: manager)
        } label: {
            Image(systemName: manager.anyActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        }

        Window("Caffeinate", id: "main") {
            CaffeinateView(manager: manager)
        }
        .windowResizability(.contentSize)
    }
}
