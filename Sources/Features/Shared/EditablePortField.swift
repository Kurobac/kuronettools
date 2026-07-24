import SwiftUI

@MainActor
struct EditablePortField: View {
    @Binding var port: Int
    let commonPorts: [Int]

    var body: some View {
        TextField(
            "端口",
            value: $port,
            format: .number.grouping(.never)
        )
        .keyboardType(.numberPad)
        .padding(.trailing, 28)
        .overlay(alignment: .trailing) {
            Menu {
                ForEach(commonPorts, id: \.self) { commonPort in
                    Button {
                        port = commonPort
                    } label: {
                        HStack {
                            Text(String(commonPort))
                            if commonPort == port {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择常用端口")
            .offset(x: 30)
        }
    }
}
