import SwiftUI

struct HairPreferencesView: View {
    @Binding var preferences: HairPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("你的头发与打理偏好").font(.fhHeading)
            Text("选你了解的就好，会据此调整排序；打理时间按发型标注筛选。")
                .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("发量")
                    Picker("发量", selection: $preferences.density) {
                        ForEach(HairPreferences.Density.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("发丝")
                    Picker("发丝", selection: $preferences.strand) {
                        ForEach(HairPreferences.Strand.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("天生卷度")
                    Picker("天生卷度", selection: $preferences.texture) {
                        ForEach(HairPreferences.Texture.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("每天打理")
                    Picker("每天打理", selection: $preferences.budget) {
                        ForEach(HairPreferences.Budget.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
            }
            .font(.fhBody)
            .pickerStyle(.menu)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("现在长度")
                    Picker("现在长度", selection: $preferences.currentLength) {
                        ForEach(HairPreferences.CurrentLength.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("烫染过吗")
                    Picker("烫染过吗", selection: $preferences.treatment) {
                        ForEach(HairPreferences.Treatment.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
            }
            .font(.fhBody)
            .pickerStyle(.menu)
            Text("这两项只写在理发师卡片上，不影响推荐。")
                .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            Text("卷发做直发、直发做卷发，实际可能需要更多时间。")
                .font(.fhSmall).foregroundStyle(Color.fhSecondary).fixedSize(horizontal: false, vertical: true)
            Button("清除这些偏好") { preferences = HairPreferences() }
                .disabled(preferences == HairPreferences())
        }
        .padding(22)
        .frame(width: 340)
    }
}
