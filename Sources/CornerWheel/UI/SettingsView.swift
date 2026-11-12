import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var updates: AppUpdateController
    @Environment(\.colorScheme) private var colorScheme

    private let brandBlue = Color(red: 0.46, green: 0.65, blue: 0.91)
    private let sliderWidth: CGFloat = 165
    private let sliderValueWidth: CGFloat = 55
    private var isDark: Bool { colorScheme == .dark }
    private var canvas: Color {
        isDark ? Color(red: 0.07, green: 0.08, blue: 0.10)
               : Color(red: 0.96, green: 0.97, blue: 0.98)
    }

    private var preferences: Binding<CornerWheelPreferences> {
        Binding(get: { settings.preferences }, set: { settings.preferences = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandHeader

                updatesSection

                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accessibility lets CornerWheel find windows and, when you choose an action, bring a window forward, minimize, restore or close it. The window’s app handles any save confirmation. Each window uses a static app icon. CornerWheel does not capture or record your screen.")
                            .font(.callout)
                        permissionRow("Accessibility", granted: permissions.accessibilityGranted,
                                      request: permissions.requestAccessibility,
                                      open: permissions.openAccessibilitySettings)
                        Button("Recheck permission") { permissions.recheck() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 11) {
                        toggleRow("Enable CornerWheel", isOn: preferences.enabled)
                        Divider()
                        HStack {
                            Text("Your corner")
                            Spacer()
                            CornerSelector(selection: preferences.corner)
                        }
                        Divider()
                        HStack {
                            Text("Activation displays")
                            Spacer()
                            Picker("Activation displays", selection: preferences.activationDisplays) {
                                ForEach(ActivationDisplays.allCases) { value in Text(value.label).tag(value) }
                            }
                            .labelsHidden()
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Detection area")
                                Spacer(minLength: 8)
                                DefaultSlider(value: preferences.detectionAreaSize,
                                              range: CornerWheelPreferences.detectionAreaSizeRange,
                                              defaultValue: CornerWheelPreferences.defaults.detectionAreaSize,
                                              label: "Detection area",
                                              formatValue: { String(format: "%.0f points from each edge", $0) },
                                              roundingIncrement: 1)
                                    .frame(width: sliderWidth, height: 26)
                                Text("\(Int(settings.preferences.detectionAreaSize)) pt")
                                    .monospacedDigit().frame(width: sliderValueWidth, alignment: .trailing)
                            }
                            Text("Increase to show the wheel farther from the corner. The area extends inward from both screen edges.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        HStack {
                            Text("Preview size")
                            Spacer(minLength: 8)
                            DefaultSlider(value: preferences.previewScale, range: 0.85...1.5,
                                          defaultValue: CornerWheelPreferences.defaults.previewScale,
                                          label: "Preview size",
                                          formatValue: { String(format: "%.0f%%", $0 * 100) })
                                .frame(width: sliderWidth, height: 26)
                            Text(String(format: "%.0f%%", settings.preferences.previewScale * 100))
                                .monospacedDigit().frame(width: sliderValueWidth, alignment: .trailing)
                        }
                        Divider()
                        HStack {
                            Text("Hover delay")
                            Spacer(minLength: 8)
                            DefaultSlider(value: preferences.hoverDelay, range: 0.1...0.5,
                                          defaultValue: CornerWheelPreferences.defaults.hoverDelay,
                                          label: "Hover delay",
                                          formatValue: { String(format: "%.0f ms", $0 * 1000) },
                                          step: 0.05)
                                .frame(width: sliderWidth, height: 26)
                            Text(String(format: "%.0f ms", settings.preferences.hoverDelay * 1000))
                                .monospacedDigit().frame(width: sliderValueWidth, alignment: .trailing)
                        }
                        Divider()
                        HStack {
                            Text("Scroll sensitivity")
                            Spacer(minLength: 8)
                            DefaultSlider(value: preferences.scrollSensitivity, range: 0.5...2,
                                          defaultValue: CornerWheelPreferences.defaults.scrollSensitivity,
                                          label: "Scroll sensitivity",
                                          formatValue: { String(format: "%.1f×", $0) })
                                .frame(width: sliderWidth, height: 26)
                            Text(String(format: "%.1f×", settings.preferences.scrollSensitivity))
                                .monospacedDigit().frame(width: sliderValueWidth, alignment: .trailing)
                        }
                        Divider()
                        toggleRow("Reverse scroll direction", isOn: preferences.reverseScroll)
                        Divider()
                        toggleRow("Include minimized windows", isOn: preferences.includeMinimized)
                        Divider()
                        HStack {
                            Text("Appearance")
                            Spacer()
                            Picker("Appearance", selection: preferences.appearance) {
                                ForEach(AppearanceChoice.allCases) { value in Text(value.label).tag(value) }
                            }
                            .labelsHidden()
                            .fixedSize(horizontal: true, vertical: false)
                            .onChange(of: settings.preferences.appearance) { _, appearance in
                                NSApp.keyWindow?.appearance = appearance.appearance
                            }
                        }
                        Divider()
                        toggleRow("Launch at login", isOn: preferences.launchAtLogin)
                            .onChange(of: settings.preferences.launchAtLogin) { _, _ in settings.syncLaunchAtLogin() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .toggleStyle(.switch)
                    .font(.callout)
                }

                if let error = settings.launchAtLoginError {
                    Text("Launch at login: \(error)").foregroundStyle(.red).font(.caption)
                }

                GroupBox("Excluded applications") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Excluded apps do not appear in the switcher.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(settings.runningApplications) { app in
                            toggleRow(app.name, isOn: exclusionBinding(for: app.bundleID))
                        }
                        ForEach(settings.preferences.excludedBundleIdentifiers.sorted(), id: \.self) { bundleID in
                            if !settings.runningApplications.contains(where: { $0.bundleID == bundleID }) {
                                HStack {
                                    Text(bundleID)
                                    Spacer()
                                    Button("Remove") { settings.preferences.excludedBundleIdentifiers.remove(bundleID) }
                                }
                            }
                        }
                        Button("Choose an application…") { chooseApplication() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                AboutCornerWheelView()

                HStack {
                    Button("Reset to defaults") { settings.reset() }
                    Spacer()
                    Link("Get Help", destination: CornerWheelHelp.url)
                        .help("Open the CornerWheel setup and troubleshooting guide in your browser.")
                    Button("Done") { NSApp.keyWindow?.close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(canvas)
        .tint(brandBlue)
        .groupBoxStyle(BrandGroupBoxStyle(isDark: isDark))
        .frame(width: 570, height: 690)
        .onAppear {
            permissions.recheck()
            settings.refreshRunningApplications()
        }
    }

    private var updatesSection: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    Spacer()
                    Button(updates.pendingUpdateVersion == nil ? "Check for Updates…" : "View Update…") {
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheckForUpdates)
                }

                Divider()

                toggleRow("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticallyChecksForUpdates($0) }))
                    .disabled(!updates.isAvailable)
                toggleRow("Automatically download and install updates", isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.setAutomaticallyDownloadsUpdates($0) }))
                    .disabled(!updates.isAvailable || !updates.automaticallyChecksForUpdates)

                if updates.isAvailable {
                    Text("Automatic updates download in the background and install when CornerWheel quits. You can also choose to install and restart sooner.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let version = updates.pendingUpdateVersion {
                        Label("Version \(version) is available.", systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let date = updates.lastUpdateCheckDate {
                        Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(updates.unavailableMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 15) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 62, height: 62)
                    .accessibilityHidden(true)
                Text("CornerWheel")
                    .font(.system(size: 31, weight: .regular))
                    .tracking(-1.3)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            Text("Move the pointer near a bottom corner and pause to show one window preview, with its neighbors peeking from the screen edges. Scroll to cycle continuously; click a preview to switch. Right-click a preview to show, minimize, restore, or close its window.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Text("If a macOS Hot Corner uses the same corner, choose the other one below. CornerWheel does not change your Hot Corner settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.20, blue: 0.25),
                                              Color(red: 0.08, green: 0.09, blue: 0.11)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(isDark ? 0.20 : 0.12), radius: 15, y: 7)
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? brandBlue : .orange)
            Text(title)
            Text(granted ? "Granted" : "Needed")
                .foregroundStyle(.secondary)
            Spacer()
            if !granted { Button("Request") { request() } }
            Button("System Settings") { open() }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { settings.preferences.excludedBundleIdentifiers.contains(bundleID) },
            set: { excluded in
                if excluded { settings.preferences.excludedBundleIdentifiers.insert(bundleID) }
                else { settings.preferences.excludedBundleIdentifiers.remove(bundleID) }
            }
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundleID = Bundle(url: url)?.bundleIdentifier {
            settings.preferences.excludedBundleIdentifiers.insert(bundleID)
        }
    }

}

private struct CornerSelector: View {
    @Binding var selection: CornerChoice
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            cornerButton(.bottomLeft, title: "↙ Left")
            cornerButton(.bottomRight, title: "Right ↘")
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.08)
                             : Color(red: 0.88, green: 0.89, blue: 0.91))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.08)
                                     : Color.black.opacity(0.04))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your corner")
    }

    private func cornerButton(_ corner: CornerChoice, title: String) -> some View {
        Button {
            selection = corner
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selection == corner ? Color.primary.opacity(0.8) : Color.secondary)
                .frame(width: 56, height: 28)
                .background {
                    if selection == corner {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.14)
                                         : Color(red: 0.96, green: 0.96, blue: 0.97))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(corner.label)
        .accessibilityAddTraits(selection == corner ? .isSelected : [])
    }
}

private struct BrandGroupBoxStyle: GroupBoxStyle {
    let isDark: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                CornerWheelMark()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                configuration.label
                    .font(.system(size: 16, weight: .semibold))
            }
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color(red: 0.12, green: 0.14, blue: 0.17) : .white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.12)
                                     : Color(red: 0.83, green: 0.86, blue: 0.90), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isDark ? 0.10 : 0.035), radius: 9, y: 3)
    }
}

private struct CornerWheelMark: View {
    var body: some View {
        ZStack {
            CornerWheelPanel(part: .left)
                .fill(LinearGradient(colors: [Color(red: 0.59, green: 0.76, blue: 0.96),
                                              Color(red: 0.15, green: 0.31, blue: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            CornerWheelPanel(part: .middle)
                .fill(LinearGradient(colors: [Color(red: 0.76, green: 0.71, blue: 0.90),
                                              Color(red: 0.36, green: 0.34, blue: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            CornerWheelPanel(part: .right)
                .fill(LinearGradient(colors: [Color(red: 0.73, green: 0.77, blue: 0.84),
                                              Color(red: 0.99, green: 0.89, blue: 0.82)],
                                     startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct CornerWheelPanel: Shape {
    enum Part { case left, middle, right }
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch part {
        case .left:
            path.move(to: CGPoint(x: 0.6, y: 4.7))
            path.addCurve(to: CGPoint(x: 1.0, y: 5.9), control1: CGPoint(x: 0.4, y: 5.1), control2: CGPoint(x: 0.5, y: 5.5))
            path.addLine(to: CGPoint(x: 3.6, y: 10.1))
            path.addCurve(to: CGPoint(x: 4.8, y: 10.4), control1: CGPoint(x: 3.9, y: 10.6), control2: CGPoint(x: 4.4, y: 10.7))
            path.addLine(to: CGPoint(x: 11.0, y: 5.0))
            path.addCurve(to: CGPoint(x: 11.2, y: 4.1), control1: CGPoint(x: 11.3, y: 4.7), control2: CGPoint(x: 11.4, y: 4.4))
            path.addLine(to: CGPoint(x: 10.3, y: 1.1))
            path.addCurve(to: CGPoint(x: 9.5, y: 0.6), control1: CGPoint(x: 10.1, y: 0.6), control2: CGPoint(x: 9.9, y: 0.5))
            path.addLine(to: CGPoint(x: 1.2, y: 3.7))
            path.addCurve(to: CGPoint(x: 0.6, y: 4.7), control1: CGPoint(x: 0.7, y: 3.9), control2: CGPoint(x: 0.5, y: 4.3))
        case .middle:
            path.move(to: CGPoint(x: 6.0, y: 11.5))
            path.addCurve(to: CGPoint(x: 6.4, y: 12.5), control1: CGPoint(x: 5.8, y: 11.9), control2: CGPoint(x: 5.9, y: 12.2))
            path.addLine(to: CGPoint(x: 10.2, y: 14.6))
            path.addCurve(to: CGPoint(x: 11.0, y: 14.1), control1: CGPoint(x: 10.6, y: 14.9), control2: CGPoint(x: 10.9, y: 14.7))
            path.addLine(to: CGPoint(x: 13.6, y: 5.6))
            path.addCurve(to: CGPoint(x: 13.2, y: 4.7), control1: CGPoint(x: 13.8, y: 5.2), control2: CGPoint(x: 13.6, y: 4.9))
            path.addLine(to: CGPoint(x: 12.7, y: 4.5))
            path.addCurve(to: CGPoint(x: 12.1, y: 4.8), control1: CGPoint(x: 12.4, y: 4.4), control2: CGPoint(x: 12.2, y: 4.5))
        case .right:
            path.move(to: CGPoint(x: 12.2, y: 16.9))
            path.addCurve(to: CGPoint(x: 13.1, y: 17.5), control1: CGPoint(x: 12.2, y: 17.3), control2: CGPoint(x: 12.5, y: 17.5))
            path.addLine(to: CGPoint(x: 16.4, y: 17.5))
            path.addCurve(to: CGPoint(x: 17.5, y: 16.4), control1: CGPoint(x: 17.1, y: 17.5), control2: CGPoint(x: 17.5, y: 17.1))
            path.addLine(to: CGPoint(x: 17.5, y: 5.2))
            path.addCurve(to: CGPoint(x: 16.8, y: 4.6), control1: CGPoint(x: 17.5, y: 4.7), control2: CGPoint(x: 17.3, y: 4.5))
            path.addLine(to: CGPoint(x: 14.1, y: 5.5))
            path.addCurve(to: CGPoint(x: 13.7, y: 6.0), control1: CGPoint(x: 13.9, y: 5.6), control2: CGPoint(x: 13.7, y: 5.8))
        }
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 18, b: 0, c: 0,
                                               d: -rect.height / 18, tx: rect.minX, ty: rect.maxY))
    }
}
