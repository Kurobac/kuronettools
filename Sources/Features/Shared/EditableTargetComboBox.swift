import Foundation
import NetToolCore
import SwiftUI

@MainActor
struct EditableTargetComboBox: View {
    let prompt: String
    let suggestions: [String]
    @Binding var value: String

    init(
        prompt: String,
        transport: DNSTransport = .udp,
        value: Binding<String>
    ) {
        self.prompt = prompt
        suggestions = PublicDNSPreset.all.compactMap {
            $0.endpoint(for: transport)
        }
        _value = value
    }

    init(
        prompt: String,
        suggestions: [String],
        value: Binding<String>
    ) {
        self.prompt = prompt
        self.suggestions = suggestions
        _value = value
    }

    var body: some View {
        TextField(prompt, text: $value)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.trailing, 28)
            .overlay(alignment: .trailing) {
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
                        .frame(
                            width: 72,
                            height: 44
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择常用目标")
                .offset(x: 30)
            }
    }

    private var normalizedValue: String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var availableEndpoints: [String] {
        var seen = Set<String>()
        return suggestions.filter {
            seen.insert($0).inserted
        }
    }
}
