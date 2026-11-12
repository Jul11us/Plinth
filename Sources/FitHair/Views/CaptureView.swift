import SwiftUI
import AppKit

struct CaptureView: View {
    @Environment(AppState.self) private var state
    @State private var camera = CameraModel()
    @State private var countdownOn = true
    @State private var captureSession = CaptureSession()

    private var countdown: Int? { captureSession.countdown }
    private var shooting: Bool { captureSession.isShooting }

    var body: some View {
        VStack(spacing: 18) {
            preview
                .frame(maxWidth: 760, maxHeight: .infinity)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)

            status

            ZStack {
                shutter
                HStack {
                    Button("选一张照片…") { captureSession.cancel(); state.pickPhoto() }
                        .buttonStyle(.plain).font(.system(size: 13)).underline()
                    Spacer()
                    settings
                }
                .frame(maxWidth: 760)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .task { await camera.start() }
        .onDisappear { captureSession.cancel(); camera.stop() }
        // Don't wait for the fade: leaving must stop the countdown at once.
        .onChange(of: state.route) { _, route in if route != .capture { captureSession.cancel() } }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        ZStack {
            Color(hex: 0x1A1A1A)
            switch camera.access {
            case .granted:
                CameraPreview(session: camera.session)
                // The guide scales with the preview. Its width is ~36 % of the frame, the middle of the
                // 18–60 % face-width range `distanceOK` accepts, so a face filling the oval passes the check.
                GeometryReader { g in
                    Ellipse()
                        .stroke(.white.opacity(camera.ready ? 0.95 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: camera.ready ? [] : [6, 6]))
                        .frame(width: g.size.width * 0.36, height: g.size.width * 0.36 * 1.32)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                        .animation(.easeInOut(duration: 0.3), value: camera.ready)
                }
                if let n = countdown, n > 0 {
                    Text("\(n)")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 10)
                        .id(n)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if shooting && countdown == 0 {
                    Text("保持不动…").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            case .denied:
                message("Plinth 还没有摄像头权限",
                        "可以在「系统设置 › 隐私与安全性 › 摄像头」里打开，或者直接选一张照片。",
                        button: "打开系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            case .noCamera:
                message("没有找到摄像头", "可以连接 iPhone 当作摄像头，或者直接选一张照片。", button: "选择照片…") { state.pickPhoto() }
            case .unknown:
                // Dark appearance so the spinner is light on the dark preview; otherwise it is invisible.
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在打开摄像头…").font(.fhSmall).foregroundStyle(.white.opacity(0.7))
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }

    private func message(_ title: String, _ body: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.fhHeading).foregroundStyle(.white)
            Text(body).font(.fhBody).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 360)
            QuietButton(title: button, action: action).padding(.top, 4)
        }
    }

    // MARK: Status

    private var status: some View {
        VStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .animation(.easeInOut(duration: 0.2), value: statusText)
            HStack(spacing: 18) {
                check("正脸", camera.facingOK)
                check("距离", camera.distanceOK)
                check("光线", camera.lightOK)
            }
            .opacity(camera.access == .granted ? 1 : 0)
        }
    }

    private var statusText: String {
        guard camera.access == .granted else { return "也可以直接选一张正脸照片" }
        if shooting { return "正在拍，连拍 10 张取中间值" }
        if camera.faceCount == 0 { return "把脸放进椭圆里" }
        if camera.faceCount > 1 { return "画面里只留你一个人" }
        if !camera.facingOK { return "正对镜头，别转头、歪头或抬头" }
        if !camera.distanceOK { return camera.faceSize < 0.18 ? "再靠近一点" : "稍微离远一点" }
        if !camera.lightOK { return camera.brightness < 0.22 ? "有点暗，面向光源。也可以直接拍" : "太亮了，避开强光。也可以直接拍" }
        return "很好。头发撩到耳后，就可以拍了"
    }

    private func check(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Theme.ink : Color.fhTertiary)
            Text(title).foregroundStyle(ok ? Theme.ink : Color.fhSecondary)
        }
        .font(.system(size: 12))
        .animation(.easeInOut(duration: 0.2), value: ok)
    }

    // MARK: Controls

    /// The shutter works as soon as one face is in frame; the checks only colour the ring.
    /// A dim room or a slightly turned head shouldn't lock the user out — the result page says what was off.
    private var canShoot: Bool { camera.access == .granted && !shooting && camera.faceCount == 1 }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().fill(.white).frame(width: 58, height: 58)
                Circle().stroke(camera.ready ? Theme.ink : Color.fhTertiary, lineWidth: 3).frame(width: 66, height: 66)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!canShoot)
        .opacity(canShoot || shooting ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: canShoot)
        .accessibilityLabel("拍照")
        .help(camera.ready ? "空格键拍照" : (canShoot ? "条件还没全满足，也可以先拍，结果可能没那么准" : "画面里要有一张脸才能拍"))
    }

    private var settings: some View {
        Menu {
            if camera.devices.count > 1 {
                Picker("摄像头", selection: Binding(get: { camera.deviceID }, set: { camera.select($0) })) {
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Toggle("3 秒倒计时", isOn: $countdownOn)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("拍照设置")
    }

    private func shoot() {
        captureSession.start(countdownEnabled: countdownOn, capture: {
            try await camera.burst(count: 10)
        }) { frames in
            guard state.route == .capture else { return }
            NSSound(named: "Tink")?.play()
            camera.stop()
            state.analyze(frames: frames, source: .camera)
        }
    }
}
