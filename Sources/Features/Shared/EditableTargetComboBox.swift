import Foundation
import NetToolCore
import SwiftUI

@MainActor
struct EditableTargetComboBox: View {
    let prompt: String
    let transport: DNSTransport
    @Binding var value: String

    init(
        prompt: String,
        transport: DNSTransport = .udp,
        value: Binding<String>
    ) {
        self.prompt = prompt
        self.transport = transport
        _value = value
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField(prompt, text: $value)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.trailing, 12)

            Divider()
                .frame(height: 24)

            Menu {
                ForEach(availableEndpoints, id: \.self) { endpoint in
                    Button {
                        value = endpoint
                    } label: {
                        HStack {
                            Text(endpoint)
                            if endpoint == normalizedValue {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择常用目标")
        }
    }

    private var normalizedValue: String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var availableEndpoints: [String] {
        var seen = Set<String>()
        return PublicDNSPreset.all.compactMap {
            $0.endpoint(for: transport)
        }.filter {
            seen.insert($0).inserted
        }
    }
}
