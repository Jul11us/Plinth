import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false

    var body: some View {
        if state.isInBackground { Theme.stone } else { page }
    }

    private var page: some View {
        VStack(spacing: 0) {
            TopBar()
            ZStack {
                // The outer stack keeps both pages in one place while they cross-fade.
                ZStack {
                    switch state.route {
                    case .home: HomeView()
                    case .capture: CaptureView()
                    case .analyzing: AnalyzingView()
                    case .result: ResultView()
                    case .pool: PoolView()
                    case .tryOn: TryOnView()
                    case .barber: BarberView()
                    }
                }
                .id(state.route)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.stone)
        .ignoresSafeArea(.container, edges: .top)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { state.handleDrop($0) }
        .overlay {
            if dropTargeted {
                ZStack {
                    Theme.stone.opacity(0.85)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light))
                        Text("松开，开始分析").font(.fhHeading)
                        Text("照片只在这台 Mac 上分析").font(.fhSmall).foregroundStyle(Color.fhSecondary)
                    }
                    .padding(36)
                    .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// A quiet macOS-style toolbar: back on the left, where you are in the middle, one action on the right.
struct TopBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 12) {
                // On the home page the name is the big word on the wall; nothing needed here.
                if state.route != .home {
                    Button { state.go(backTarget) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text(backTitle)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Color.white.opacity(0.55), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("返回（⌘[）")
                }
                Spacer()
                trailing
            }
            .padding(.leading, 84)
            .padding(.trailing, 20)
        }
        .frame(height: 52)
    }

    private var title: String {
        switch state.route {
        case .home: ""
        case .capture: "拍照"
        case .analyzing: "测量"
        case .result: "你的脸型"
        case .pool: state.usesMixedRecommendations ? "综合推荐的发型" : (state.hasResult ? "适合\(state.shape.name)的发型" : "发型库")
        case .tryOn: "试戴"
        case .barber: "理发师卡片"
        }
    }

    private var backTarget: Route {
        switch state.route {
        case .home, .capture, .analyzing, .result: .home
        case .pool: state.hasResult ? .result : .home
        case .tryOn, .barber: .pool
        }
    }

    private var backTitle: String {
        switch backTarget {
        case .home: "首页"
        case .result: "脸型"
        case .pool: "发型"
        default: "返回"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state.route {
        case .home:
            Button("打开照片…") { state.pickPhoto() }.buttonStyle(.plain).font(.system(size: 13))
        case .capture, .analyzing:
            EmptyView()
        case .result, .pool, .tryOn, .barber:
            // Offer the way the photo actually came in; when browsing without a photo, offer to take one.
            if !state.hasResult {
                Button("拍一张测脸型") { state.go(.capture) }.buttonStyle(.plain).font(.system(size: 13))
            } else if state.photoSource == .camera {
                Button("重新拍") { state.go(.capture) }.buttonStyle(.plain).font(.system(size: 13))
            } else {
                Button("换一张照片…") { state.pickPhoto() }.buttonStyle(.plain).font(.system(size: 13))
            }
        }
    }
}
