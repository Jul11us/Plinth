import SwiftUI

struct AnalyzingView: View {
    @Environment(AppState.self) private var state
    @State private var reveal = 0
    @State private var scan: CGFloat = 0

    private let lines = ["正在找你的脸…", "正在找面部轮廓上的点…", "正在量额头、颧骨和下颌…", "正在和七种脸型比对…"]

    var body: some View {
        VStack(spacing: 22) {
            if let img = state.photo {
                MeasuredPhoto(image: img, measurement: nil, zoomToFace: false)
                    .overlay(alignment: .top) {
                        if state.analysisError == nil {
                            GeometryReader { g in
                                Rectangle().fill(.white.opacity(0.6)).frame(height: 2).offset(y: g.size.height * scan)
                            }
                        }
                    }
                    .aspectRatio(0.8, contentMode: .fit)
                    .frame(maxWidth: 440, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            }

            if let error = state.analysisError {
                VStack(spacing: 10) {
                    Text("这张照片量不了").font(.fhHeading)
                    Text(error).font(.fhBody).foregroundStyle(Color.fhSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    HStack(spacing: 10) {
                        // Lead with the way this photo came in.
                        if state.photoSource == .camera {
                            CapsuleButton(title: "重新拍", systemImage: "camera") { state.go(.capture) }
                            QuietButton(title: "换一张照片…") { state.pickPhoto() }
                        } else {
                            CapsuleButton(title: "换一张照片…") { state.pickPhoto() }
                            QuietButton(title: "拍一张", systemImage: "camera") { state.go(.capture) }
                        }
                    }
                    .padding(.top, 6)
                }
            } else {
                VStack(spacing: 12) {
                    Text(lines[step])
                        .font(.system(size: 17, weight: .medium))
                        .id(step)
                        .transition(.opacity)
                    ProgressView(value: Double(step + 1), total: Double(lines.count))
                        .progressViewStyle(.linear)
                        .tint(Theme.ink)
                        .frame(width: 220)
                    Text("全程在这台 Mac 上完成").font(.fhSmall).foregroundStyle(Color.fhTertiary)
                }
                .animation(.easeInOut(duration: 0.3), value: step)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { scan = 1 }
            Task { @MainActor in
                for i in 1...3 {
                    try? await Task.sleep(for: .milliseconds(380))
                    withAnimation(.easeOut(duration: 0.3)) { reveal = i }
                }
            }
        }
    }

    private var step: Int { min(3, reveal + (state.measurement == nil ? 0 : 1)) }
}
