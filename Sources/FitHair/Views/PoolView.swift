import SwiftUI

struct PoolView: View {
    @Environment(AppState.self) private var state
    @State private var hoveredID: String?
    @State private var preferencesShown = false
    @State private var angle: BustAngle = .front       // stays put between styles, to compare backs quickly

    var body: some View {
        @Bindable var state = state
        content(state: state)
            // The try-on is one click from here. Loading its model takes seconds, so it starts now.
            .task {
                guard state.photo != nil else { return }
                await Task.detached(priority: .utility) { await HairRepaint.shared.prepare() }.value
            }
    }

    @ViewBuilder private func content(state: AppState) -> some View {
        @Bindable var state = state
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Picker("性别", selection: $state.gender) {
                        ForEach(Gender.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("长度", selection: $state.lengthFilter) {
                        Text("全部长度").tag(HairLength?.none)
                        ForEach(HairLength.allCases) { Text($0.label).tag(HairLength?.some($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    // Recommended (score ≥ 80 for this shape) or everything for the gender and length.
                    Picker("范围", selection: $state.scope) {
                        Text("推荐").tag(StyleScope.recommended)
                        Text("全部").tag(StyleScope.all)
                        Text("收藏").tag(StyleScope.saved)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack(spacing: 12) {
                    if !state.hasResult {
                        Picker("脸型", selection: $state.shape) {
                            ForEach(FaceShape.allCases) { Text($0.name).tag($0) }
                        }
                        .fixedSize()
                    }
                    Button {
                        preferencesShown = true
                    } label: {
                        Label(state.hairPreferences.isActive ? "发质与打理 · 已设置" : "发质与打理", systemImage: "slider.horizontal.3")
                            .font(.fhSmall)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $preferencesShown, arrowEdge: .leading) { HairPreferencesView(preferences: $state.hairPreferences) }
                    Spacer(minLength: 0)
                }
                if state.hairPreferences.isActive {
                    Text(state.hairPreferences.summary + "。已结合偏好排序，时间按发型标注筛选。")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                }
                // A plain caption, not a control: how many styles, and why they are in this order.
                Text(caption).font(.fhSmall).foregroundStyle(Color.fhTertiary)
                if state.pool.isEmpty {
                    emptyPool.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        // Three tiles across from the narrowest window up.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 22)], spacing: 26) {
                            ForEach(state.pool) { style in tile(style) }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(maxWidth: .infinity)

            detail
                .frame(width: 340)
        }
        .padding(.horizontal, 36)
        .padding(.top, 6)
        .padding(.bottom, 24)
        .onChange(of: state.pool.map(\.id), initial: true) { state.synchronizePoolSelection() }
    }

    private var caption: String {
        let n = state.pool.count, total = state.poolTotal
        let who = state.recommendationTarget
        if state.scope == .saved {
            return n == 0 ? "当前筛选下没有收藏的发型。" : "找到 \(n) 款收藏，适合\(who)的排在前面。"
        }
        if state.scope == .all {
            return "当前条件下共 \(total) 款，适合\(who)的排在前面。"
        }
        if state.pool.contains(where: { state.suitability(of: $0) < Hairstyle.recommendedMinScore }) {
            return "当前条件下高适合度的款式较少，先列出较接近的 \(n) 款供比较。"
        }
        let base = n < total ? "先看最适合\(who)的 \(n) 款，其余 \(total - n) 款在「全部」里。" : "\(n) 款都比较适合\(who)。"
        return state.hasResult ? base : base + "拍一张照片可以量出你的脸型。"
    }

    private var emptyPool: some View {
        ContentUnavailableView {
            Label(state.scope == .saved ? "这里还没有收藏的发型" : "没有符合条件的发型", systemImage: state.scope == .saved ? "bookmark" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(state.scope == .saved ? "可以换个筛选条件，或到全部发型里点书签收藏。" : "试试选择全部长度，或放宽筛选条件。")
        } actions: {
            QuietButton(title: "清除筛选，看全部发型") {
                state.scope = .all
                state.lengthFilter = nil
                state.hairPreferences = HairPreferences()
            }
        }
    }

    private func tile(_ s: Hairstyle) -> some View {
        let on = s.id == state.selectedStyleID
        let hover = hoveredID == s.id
        let score = state.suitability(of: s)
        return Button { withAnimation(.easeInOut(duration: 0.2)) { state.selectedStyleID = s.id } } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Fixed 4:5 tile (the busts' own shape) so the whole bust shows at any window width.
                // The selection frame sits on the tile's own edge, so the scroll view can't clip it.
                let tileShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                StyleImage(style: s)
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .clipShape(tileShape)
                    .overlay(tileShape.strokeBorder(on ? Theme.ink : Color.black.opacity(hover ? 0.3 : 0.05), lineWidth: on ? 2 : 1))
                    .shadow(color: .black.opacity(hover && !on ? 0.1 : 0), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.system(size: 14, weight: on ? .semibold : .medium))
                    Text("\(s.length.label) · \(state.suitabilityLabel) \(score)").font(.fhSmall).foregroundStyle(Color.fhSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? s.id : (hoveredID == s.id ? nil : hoveredID) }
        .animation(.easeInOut(duration: 0.15), value: hover)
        .accessibilityLabel("\(s.name)，\(s.length.label)，\(state.suitabilityLabel) \(score)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        if let style = state.poolSelection {
            styleDetail(style)
        } else {
            LabelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选中一款，再看详情").font(.fhHeading)
                    Text("列表里有发型后，这里会显示剪法、打理方式和试戴入口。")
                        .font(.fhBody).foregroundStyle(Color.fhSecondary)
                }
            }
        }
    }

    /// The picture gives way first, so everything fits; the details scroll only if the text alone is too long.
    private func styleDetail(_ s: Hairstyle) -> some View {
        ViewThatFits(in: .vertical) {
            ForEach([380, 330, 310, 285, 240] as [CGFloat], id: \.self) { height in
                VStack(spacing: 14) { detailContent(s, imageHeight: height); detailActions(s) }
                    .padding(18)
                    .detailCard()
            }
            VStack(spacing: 0) {
                ScrollView { detailContent(s, imageHeight: 240).padding(18) }
                    .scrollIndicators(.automatic)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22).allowsHitTesting(false)
                    }
                detailActions(s).padding(.horizontal, 18).padding(.vertical, 14)
            }
            .detailCard()
        }
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func detailContent(_ s: Hairstyle, imageHeight: CGFloat) -> some View {
        let saved = state.savedStyleIDs.contains(s.id)
        return VStack(alignment: .leading, spacing: 14) {
            StyleImage(style: s, angle: s.hasAllViews ? angle : .front)
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) { if s.hasAllViews { anglePicker.padding(8) } }   // the corner stays clear of the face
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).font(.fhHeading)
                    Text("\(s.length.label) · \(s.ease) · \(state.suitabilityLabel) \(state.suitability(of: s))")
                        .font(.fhSmall).foregroundStyle(Color.fhSecondary)
                }
                Spacer()
                Button { state.toggleSaved(s.id) } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark").font(.system(size: 16))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(saved ? "取消收藏" : "收藏")
                .accessibilityLabel(saved ? "取消收藏" : "收藏")
            }
            Text(s.why.joined(separator: "；") + "。").font(.fhBody).fixedSize(horizontal: false, vertical: true)
            Text("每天打理\(s.care)，\(s.cycle)修剪一次。").font(.fhSmall).foregroundStyle(Color.fhSecondary)
            ForEach(s.hairProfile.notes(for: state.hairPreferences), id: \.self) { note in
                Text(note).font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("跟理发师这样说").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.fhSecondary)
                Text(s.say).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var anglePicker: some View {
        VStack(spacing: 2) {
            ForEach(BustAngle.allCases) { a in
                let on = a == angle
                Button { angle = a } label: {
                    Text(a.rawValue)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Color.fhSecondary)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(on ? Color.white : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看\(a.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func detailActions(_ s: Hairstyle) -> some View {
        let saved = state.savedStyleIDs.contains(s.id)
        return HStack(spacing: 10) {
            // Says what it does: making the card also keeps the style in the saved list.
            CapsuleButton(title: saved ? "生成理发师卡片" : "收藏并生成卡片") {
                state.selectedStyleID = s.id
                if !saved { state.toggleSaved(s.id) }
                state.go(.barber)
            }
            QuietButton(title: s.hairProfile.supportsTryOn ? "试戴" : "看示意", systemImage: "person.crop.square") {
                state.selectedStyleID = s.id
                state.go(.tryOn)
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    /// The white card the details and try-on panels sit on.
    func detailCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}
