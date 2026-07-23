import Foundation
import NetToolCore
import SwiftUI

@MainActor
struct PublicDNSPresetMenu: View {
    let title: String
    @Binding var address: String

    var body: some View {
        Menu {
            presetSection(
                title: "大陆",
                presets: PublicDNSPreset.mainlandChina
            )
            presetSection(
                title: "国际",
                presets: PublicDNSPreset.global
            )
        } label: {
            LabeledContent(
                title,
                value: selectedPreset?.name ?? "手动"
            )
        }
    }

    private var selectedPreset: PublicDNSPreset? {
        let normalizedAddress = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return PublicDNSPreset.all.first {
            $0.address == normalizedAddress
        }
    }

    private func presetSection(
        title: String,
        presets: [PublicDNSPreset]
    ) -> some View {
        Section(title) {
            ForEach(presets) { preset in
                Button {
                    address = preset.address
                } label: {
                    HStack {
                        Text("\(preset.name) · \(preset.address)")
                        if preset.id == selectedPreset?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}
