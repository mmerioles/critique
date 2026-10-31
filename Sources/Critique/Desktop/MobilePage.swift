import CoreImage
import SwiftUI

/// Critiques from your Android phone: connect it over Wireless debugging, add the
/// Critique tile, and tap it to start and send while you test your app.
struct MobilePage: View {
    @ObservedObject private var mobile = Mobile.shared
    @ObservedObject private var projects = Projects.shared
    @State private var now = Date()
    @State private var pairing = false
    @State private var busy: String?
    @State private var problem: String?
    @State private var hasScrcpy = ADB.scrcpyPath != nil

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PageScaffold(title: "Mobile", subtitle: "Critique an Android app from your phone, and get the fix back on it.") {
            card { phoneSection }
            if mobile.device != nil {
                card { setupSection }
                sessionStatus
                card { installSection }
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
            }
            howItWorks
        }
        .onReceive(tick) { now = $0 }
        .task { await mobile.refresh() }
        .sheet(isPresented: $pairing) { PairSheet() }
    }

    // MARK: Phone

    @ViewBuilder private var phoneSection: some View {
        if ADB.adbPath == nil {
            row("iphone.gen3", "No adb found", "Install Android Studio or `brew install android-platform-tools`, then reopen Critique.") { EmptyView() }
        } else if mobile.devices.isEmpty {
            row("iphone.gen3", "No phone connected",
                "On your phone: Settings → Developer options → Wireless debugging. Same Wi‑Fi as this Mac.") {
                Button("Pair phone…") { pairing = true }.buttonStyle(.borderedProminent).tint(Theme.red)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(mobile.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3").foregroundStyle(Theme.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.model).font(.system(size: 13, weight: .medium))
                            Text(device.isReady ? device.connection : stateHelp(device.state))
                                .font(.system(size: 12)).foregroundStyle(device.isReady ? Theme.secondary : Color.orange)
                        }
                        Spacer()
                        if mobile.devices.count > 1, device.isReady {
                            if mobile.device?.serial == device.serial {
                                Text("Critiques from this phone").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            } else {
                                Button("Use this phone") { mobile.selected = device.serial }
                            }
                        }
                    }
                }
                Divider().overlay(Theme.border)
                HStack {
                    Spacer()
                    Button("Pair another phone…") { pairing = true }
                }
            }
        }
    }

    private func stateHelp(_ state: String) -> String {
        switch state {
        case "unauthorized": "Allow debugging on the phone's screen"
        case "offline": "Offline: turn Wireless debugging off and on again"
        default: state
        }
    }

    // MARK: Setup

    @ViewBuilder private var setupSection: some View {
        let serial = mobile.device?.serial ?? ""
        VStack(spacing: 14) {
            row("square.grid.2x2", "Critique tile",
                mobile.helperInstalled[serial] == true
                    ? "In Quick Settings (swipe down twice). Not there? Tap the pencil and drag Critique in."
                    : "A Quick Settings tile that starts and sends a critique. It only tells this Mac when you tap it.") {
                if mobile.helperInstalled[serial] == true {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.35))
                } else {
                    Button(busy == "helper" ? "Installing…" : "Install tile") {
                        run("helper") {
                            if let result = await mobile.installHelper(), !result.ok { return "Couldn't install the tile: \(result.message)" }
                            return nil
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.red).disabled(busy != nil)
                }
            }
            Divider().overlay(Theme.border)
            row("record.circle", "Screen and mic recording",
                hasScrcpy ? "scrcpy records your phone's screen and mic (Android 11+ for the mic)."
                    : "Critique uses scrcpy to record your phone's screen and mic.") {
                if hasScrcpy {
                    Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.35))
                } else {
                    Button(busy == "scrcpy" ? "Installing…" : "Install scrcpy") {
                        run("scrcpy") {
                            let result = await ADB.run("/bin/sh", ["-c", "brew install scrcpy"], timeout: 600)
                            ADB.forgetScrcpy()
                            hasScrcpy = ADB.scrcpyPath != nil
                            return result.ok ? nil : "Couldn't install scrcpy: \(result.message)"
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.red).disabled(busy != nil)
                }
            }
        }
    }

    // MARK: Now

    @ViewBuilder private var sessionStatus: some View {
        RowList {
            HStack(spacing: 14) {
                Circle().fill(statusColor).frame(width: 8, height: 8).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 14, weight: .medium))
                    Text(statusDetail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                switch mobile.phase {
                case .idle:
                    Button("Start from Mac") { mobile.start() }
                        .help("Same as tapping the Critique tile on your phone")
                case .recording(let since):
                    Text(clock(since)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tertiary)
                    Button("Cancel") { mobile.cancel() }
                    Button("Send") { mobile.send() }.buttonStyle(.borderedProminent).tint(Theme.red)
                case .sending:
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private var statusTitle: String {
        switch mobile.phase {
        case .idle: "Ready"
        case .recording: "Recording your phone"
        case .sending: "Sending"
        }
    }

    private var statusDetail: String {
        switch mobile.phase {
        case .idle: "Tap the Critique tile on your phone to start."
        case .recording: "Talk and tap around the app. Tap the tile again to send."
        case .sending: "Transcribing and handing it to the agent…"
        }
    }

    private var statusColor: Color {
        switch mobile.phase {
        case .idle: Color(red: 0.2, green: 0.6, blue: 0.35)
        case .recording: Theme.red
        case .sending: Color.orange
        }
    }

    private func clock(_ since: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Reinstall

    @ViewBuilder private var installSection: some View {
        let project = projects.active
        let gradle = project.flatMap { Installer.gradleProject(in: URL(fileURLWithPath: $0.path)) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app").foregroundStyle(Theme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install the fix on your phone").font(.system(size: 13, weight: .medium))
                    Text(installHelp(project: project, gradle: gradle))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Install the fix on your phone", isOn: $mobile.autoInstall)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.red)
            }
            if let text = mobile.installer.text {
                HStack(spacing: 8) {
                    if case .building = mobile.installer { ProgressView().controlSize(.small) }
                    Text(text).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                        .foregroundStyle(installColor)
                }
                .padding(.leading, 32)
            }
            if gradle != nil {
                HStack {
                    Spacer()
                    Button("Build and install now") { mobile.installNow() }
                        .disabled({ if case .building = mobile.installer { return true }; return false }())
                }
            }
        }
    }

    private func installHelp(project: FeedbackRecord.ProjectRecord?, gradle: URL?) -> String {
        guard let project else { return "Pick the repo your critiques are for on the Agent page." }
        guard let gradle else { return "\(project.name) has no Gradle wrapper (gradlew), so there's nothing to install." }
        let place = gradle.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return "When the agent finishes a phone critique, runs ./gradlew installDebug in \(place) and reopens the app."
    }

    private var installColor: Color {
        switch mobile.installer {
        case .failed: Theme.red
        case .done: Color(red: 0.2, green: 0.6, blue: 0.35)
        default: Theme.secondary
        }
    }

    // MARK: Help

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.system(size: 13, weight: .semibold))
            ForEach(Array([
                "Tap the Critique tile in Quick Settings. Critique records your phone's screen and mic from this Mac.",
                "Use the app and talk. Each tap gets a screenshot with a ring where your finger was; swipes go in the timeline.",
                "Tap the tile again. The critique goes to the agent, like one from your Mac.",
                "When the agent is done, Critique builds the app and installs it on your phone, so you can check the fix.",
            ].enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(Theme.ink))
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func row<Trailing: View>(_ icon: String, _ title: String, _ detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(.init(detail)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }

    private func run(_ what: String, _ work: @escaping () async -> String?) {
        busy = what
        problem = nil
        Task {
            problem = await work()
            busy = nil
        }
    }
}

/// Pair a phone by scanning a QR code with its Wireless debugging screen
/// ("Pair device with QR code"), or by typing its pairing code.
private struct PairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var useCode = false
    @State private var qr = QRPairing()
    @State private var message: String?
    @State private var failed = false
    @State private var pairAddress = ""
    @State private var code = ""
    @State private var connectAddress = ""
    @State private var working = false
    /// The adb server is ours and macOS lets Critique on the local network; until then, nothing to watch.
    @State private var ready = false
    @State private var networkDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair your phone").font(.system(size: 18, weight: .semibold))
            if useCode { codeForm } else { qrForm }
            if networkDenied {
                HStack(alignment: .top, spacing: 10) {
                    Text("macOS is keeping Critique off your local network, so it can't find your phone. Turn on Critique in Privacy & Security → Local Network.")
                        .font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { LocalNetwork.openSettings() }
                }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(failed ? Theme.red : Theme.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button(useCode ? "Scan a QR code instead" : "Use a pairing code instead") {
                    useCode.toggle(); message = nil; failed = false
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }
                if useCode {
                    Button(working ? "Connecting…" : "Pair and connect") { pairWithCode() }
                        .buttonStyle(.borderedProminent).tint(Theme.red)
                        .disabled(working || (pairAddress.isEmpty && connectAddress.isEmpty))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            async let allowed = LocalNetwork.isAllowed()
            await ADB.takeOverServer()
            networkDenied = !(await allowed)
            ready = true
        }
        // Watch for the phone while the QR code is up (a new one after a failed try).
        .task(id: "\(useCode) \(qr.name) \(ready)") {
            guard !useCode, ready else { return }
            await waitForScan()
        }
    }

    // MARK: QR code

    private var qrForm: some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let image = qr.image {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "On your phone, open Settings → Developer options → **Wireless debugging**.")
                step(2, "Tap **Pair device with QR code** and scan this.")
                step(3, "Keep the phone on the same Wi‑Fi as this Mac.")
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(ready ? "Waiting for your phone…" : "Getting ready…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.ink))
            Text(.init(text)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The phone announces itself on the network under the QR code's name once
    /// it has scanned it; then adb pairs with the QR code's password.
    private func waitForScan() async {
        let qr = qr
        while !Task.isCancelled {
            if let address = await ADB.mdnsServices().first(where: { $0.name == qr.name && $0.type == "_adb-tls-pairing._tcp" })?.address {
                failed = false
                message = "Pairing…"
                let result = await ADB.pair(address, code: qr.password)
                guard result.ok else {
                    failed = true
                    message = "Couldn't pair: \(result.message) Then scan the new code."
                    // A new code, which restarts this watch.
                    self.qr = QRPairing()
                    return
                }
                message = "Paired. Connecting…"
                let connected = await ADB.connectAfterPairing(host: address.split(separator: ":").first.map(String.init) ?? "")
                await Mobile.shared.refresh()
                guard connected else {
                    failed = true
                    message = "Paired, but your phone didn't connect. Turn Wireless debugging off and on again on your phone, or use a pairing code and enter its IP address & port."
                    return
                }
                dismiss()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Pairing code

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On your phone: Settings → Developer options → Wireless debugging → **Pair device with pairing code**. Enter what it shows.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("IP address & port, e.g. 192.168.1.20:37099", text: $pairAddress)
                TextField("Pairing code", text: $code).frame(width: 110)
            }
            .textFieldStyle(.roundedBorder)
            Text("Then enter the **IP address & port** from the main Wireless debugging screen (a different port).")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("IP address & port, e.g. 192.168.1.20:41235", text: $connectAddress)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func pairWithCode() {
        working = true
        failed = false
        message = nil
        Task {
            defer { working = false }
            await ADB.takeOverServer()
            let pairAt = pairAddress.filter { !$0.isWhitespace }
            if !pairAt.isEmpty {
                guard !code.filter({ !$0.isWhitespace }).isEmpty else {
                    failed = true
                    message = "Enter the 6-digit pairing code from your phone."
                    return
                }
                message = "Pairing…"
                let result = await ADB.pair(pairAt, code: code.filter { !$0.isWhitespace })
                guard result.ok else {
                    failed = true
                    message = "Couldn't pair: \(result.message)"
                    return
                }
            }
            let connectAt = connectAddress.filter { !$0.isWhitespace }
            if !connectAt.isEmpty {
                message = "Connecting…"
                let result = await ADB.connect(connectAt)
                guard result.ok else {
                    failed = true
                    message = "Paired, but couldn't connect: \(result.message)"
                    return
                }
            } else if let host = pairAt.split(separator: ":").first {
                message = "Paired. Connecting…"
                guard await ADB.connectAfterPairing(host: String(host)) else {
                    await Mobile.shared.refresh()
                    failed = true
                    message = "Paired, but your phone didn't connect. Enter the IP address & port from the main Wireless debugging screen and try again."
                    return
                }
            }
            await Mobile.shared.refresh()
            dismiss()
        }
    }
}

/// What Android's "Pair device with QR code" scans: a made-up service name the
/// phone will announce, and a password for `adb pair`.
struct QRPairing {
    let name = "critique-" + String(UUID().uuidString.prefix(6)).lowercased()
    let password = String((0..<10).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
    var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

    var image: NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
