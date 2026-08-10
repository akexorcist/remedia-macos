import SwiftUI
import RemediaCore

/// REQUIREMENTS §8: determinate progress + Cancel while running; inline
/// error state (message + Dismiss) on failure, both deleting the partial
/// output file (handled by ConversionJob itself).
struct ConversionProgressView: View {
    var viewModel: ConversionViewModel

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.phase {
            case .converting(let progress):
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                Button("Cancel") {
                    viewModel.cancelConversion()
                }

            case .failed(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Dismiss") {
                    viewModel.dismissError()
                }

            default:
                EmptyView()
            }
        }
        .padding()
    }
}
