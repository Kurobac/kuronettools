import Foundation
import NetToolCore
import SwiftUI

@MainActor
struct PublicDNSPresetMenu: View {
    let title: String
    let transport: DNSTransport
    @Binding var address: String

    init(
        title: String,
        transport: DNSTransport = .udp,
        address: Binding<String>
    ) {
        self.title = title
        self.transport = transport
        _address = address
    }

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
            $0.endpoint(for: transport) == normalizedAddress
        }
    }

    private func presetSection(
        title: String,
        presets: [PublicDNSPreset]
    ) -> some View {
        Section(title) {
            ForEach(presets) { preset in
                if let endpoint = preset.endpoint(for: transport) {
                    Button {
                        address = endpoint
                    } label: {
                        HStack {
                            Text("\(preset.name) · \(endpoint)")
                            if preset.id == selectedPreset?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}
