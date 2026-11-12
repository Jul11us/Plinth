import SwiftUI

struct ResultView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Both columns hang from the same top edge, so the photo and the verdict start level.
        HStack(alignment: .top, spacing: 40) {
            if let img = state.photo {
                MeasuredPhoto(image: img, measurement: state.measurement, showAllPoints: false)
                    .aspectRatio(0.8, contentMode: .fit)
                    .frame(maxWidth: 460, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            }

            // The way on stays pinned below the details, whatever the window height.
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let m = state.measurement { measurements(m) }
                        correction
                        advice
                    }
                    .padding(.bottom, 8)
                    .padding(.trailing, 16)     // keeps the cards clear of the scroll bar
                    .frame(maxWidth: 536, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                nextStep
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    /// Remembers 女生 / 男生 once chosen; the first time it asks, so nobody starts on the wrong list.
    private var nextStep: some View {
        HStack(spacing: 10) {
            if state.genderChosen {
                let first = state.gender, other: Gender = first == .female ? .male : .female
                CapsuleButton(title: "看\(first.label)发型") { state.showStyles(for: first) }
                QuietButton(title: "看\(other.label)发型") { state.showStyles(for: other) }
            } else {
                Text("想看哪一类发型？").font(.system(size: 13, weight: .semibold))
                ForEach(Gender.allCases) { g in
                    CapsuleButton(title: "看\(g.label)发型") { state.showStyles(for: g) }
                }
            }
        }
    }

    // MARK: Header — the verdict in words (the top bar already says "你的脸型")

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 40, weight: .semibold))
            Text(verdict).font(.system(size: 16)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let share = shareLine {
                Text(share).font(.fhSmall).foregroundStyle(Color.fhSecondary)
            }
            ForEach(state.measurement?.warnings ?? [], id: \.self) { w in
                Label(w, systemImage: "exclamationmark.circle").font(.fhSmall).foregroundStyle(Color.fhSecondary)
            }
        }
    }

    /// Leads with the most likely shape even when it's close; only a photo that can't be judged gets no answer.
    private var title: String {
        guard state.usesMixedRecommendations, let c = state.classification else { return state.shape.name }
        return c.needsRetake ? "脸型待确认" : "偏\(c.primary.name)"
    }

    private var verdict: String {
        guard let c = state.classification else { return state.shape.note }
        if state.shapeConfirmed { return "已按你的选择确认为\(state.shape.name)，接下来按这个脸型推荐。" }
        if state.shape != c.primary {
            return "你把结果改成了\(state.shape.name)。测量更接近\(c.primary.name)，按你的选择来推荐。"
        }
        if c.needsRetake { return "这张照片还不足以确定脸型，建议正对镜头、露出额头和下颌再拍。也可以先看综合推荐。" }
        if c.isUncertain {
            let others = c.candidates.dropFirst().map(\.name).joined(separator: "、")
            return "最接近\(c.primary.name)，也有点像\(others)。发型先按这几种一起推荐，也可以在下面选定一个。"
        }
        if let s = c.secondary { return "最接近\(c.primary.name)，也带一点\(s.shape.name)的特点。" }
        return "比较典型的\(c.primary.name)。"
    }

    private var shareLine: String? {
        guard state.classification != nil else { return nil }
        return "根据面部比例作参考判断，拍摄角度和遮挡会影响结果。"
    }

    // MARK: Measurements as sentences

    private func measurements(_ m: FaceMeasurement) -> some View {
        let r = m.ratios
        let rows: [(String, String)] = [
            ("arrow.up.and.down", lengthSentence(r.lengthToWidth)),
            ("arrow.left.and.right", foreheadSentence(r.foreheadToCheek)),
            ("chevron.down", jawSentence(r.jawToCheek)),
            ("angle", angleSentence(r.jawAngle)),
        ]
        return LabelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("量出来的").font(.system(size: 13, weight: .semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: row.0).font(.system(size: 12)).foregroundStyle(Color.fhTertiary).frame(width: 16)
                        Text(row.1).font(.fhBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(footnote(m)).font(.fhSmall).foregroundStyle(Color.fhTertiary).padding(.top, 2)
            }
        }
    }

    private func lengthSentence(_ v: Double) -> String {
        let q = v < 1.25 ? "，长宽很接近" : (v > 1.4 ? "，脸偏长" : "")
        return String(format: "脸长约是脸宽的 %.2f 倍", v) + q + "。"
    }
    private func foreheadSentence(_ v: Double) -> String {
        let t = v > 0.83 ? "额头和颧骨差不多宽" : (v >= 0.78 ? "额头比颧骨窄一点" : "额头明显比颧骨窄")
        return t + String(format: "（%.2f）。", v)
    }
    private func jawSentence(_ v: Double) -> String {
        let t = v > 0.78 ? "下颌和颧骨差不多宽" : (v >= 0.74 ? "下颌比颧骨窄一些" : "往下巴收得比较尖")
        return t + String(format: "（%.2f）。", v)
    }
    private func angleSentence(_ v: Double) -> String {
        let t = v > 136 ? "线条圆润" : (v < 131 ? "有棱角" : "线条适中")
        return String(format: "下颌角约 %.0f°，", v) + t + "。"
    }
    private func footnote(_ m: FaceMeasurement) -> String {
        var s: String
        switch (m.hairlineMeasured, m.foreheadMeasured) {
        case (true, true): s = "发际线和额头两侧是从照片里认出头发的位置量的。"
        case (false, false): s = "发际线和额头宽度看不清，是按比例估算的（照片上的虚线）。"
        case (true, false): s = "额头宽度看不清，是按比例估算的（照片上的虚线）。"
        case (false, true): s = "发际线看不清，脸长是按比例估算的。"
        }
        if m.sampleCount > 1 { s = "连拍 \(m.sampleCount) 张取了中间值。" + s }
        return s
    }

    // MARK: Manual correction

    private var correction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.usesMixedRecommendations ? "你觉得更像哪种？选一个确认" : "不像你？换一个").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(FaceShape.allCases) { s in
                    let on = s == state.shape && !state.usesMixedRecommendations
                    Button { withAnimation(.easeInOut(duration: 0.2)) { state.chooseShape(s) } } label: {
                        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
                        VStack(spacing: 6) {
                            // A small 4:5 portrait card: the whole head plus a little neck.
                            // Busts are 704×880 and eye-aligned; the head sits in x 160–544, y 90–570.
                            Image(nsImage: Res.image(s.imageName))
                                .resizable()
                                .frame(width: 88, height: 110)
                                .offset(y: 14)
                                .frame(width: 48, height: 60)
                                .clipShape(tile)
                                .overlay(tile.strokeBorder(on ? Theme.ink : Color.black.opacity(0.06), lineWidth: on ? 1.5 : 1))
                                .opacity(on ? 1 : 0.85)
                            Text(s.short).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.ink : Color.fhSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("改成\(s.name)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Advice

    private var advice: some View {
        LabelCard {
            VStack(alignment: .leading, spacing: 12) {
                if state.usesMixedRecommendations {
                    Text("先综合看发型").font(.system(size: 13, weight: .semibold))
                    Text("会兼顾相近脸型的推荐，先选喜欢的长度和打理方式。选定脸型后，再按你的选择排序。")
                        .font(.fhBody).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("适合").font(.system(size: 13, weight: .semibold))
                        Text(state.shape.suits).font(.fhBody).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("尽量避免").font(.system(size: 13, weight: .semibold))
                        Text(state.shape.avoid).font(.fhBody).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
