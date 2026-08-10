import SwiftUI
import RemediaCore

struct FormatPickerView: View {
    var viewModel: ConversionViewModel

    private static let displayOrder: [OutputFormat] = [.mp4, .mov, .webm, .gif]
    private static let labelWidth: CGFloat = 130

    var body: some View {
        Picker(selection: Binding(
            get: { viewModel.targetFormat ?? .mp4 },
            set: { viewModel.targetFormat = $0 }
        )) {
            // REQUIREMENTS §4: the source's own format is a valid target
            // (edit-only trim/crop/quality re-encode pass).
            ForEach(Self.displayOrder, id: \.self) { format in
                Text(format.rawValue.uppercased()).tag(format)
            }
        } label: {
            Text("Convert to")
                .frame(width: Self.labelWidth, alignment: .trailing)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
