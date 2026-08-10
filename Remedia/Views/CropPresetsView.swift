import SwiftUI
import RemediaCore

/// Quick aspect-ratio presets for `CropOverlayView`'s crop rect (REQUIREMENTS §5).
///
/// `viewModel.selectedCropShape` tracks selection explicitly rather than
/// deriving it from the crop rect's ratio: landing on exact 1:1 via a Free
/// resize stays "Free" (matching a preset only happens via direct
/// selection), but drifting a preset's crop off its ratio does fall back to
/// "Free" automatically. `isCropDisabled` separately distinguishes
/// "Original" from "Free," since both leave `crop == nil`.
///
/// Selection/drift rules and crop-rect math are exposed as `internal` pure
/// functions so `RemediaTests` can exercise them directly.
struct CropPresetsView: View {
    var viewModel: ConversionViewModel

    enum Orientation: Equatable { case landscape, portrait }

    struct SelectionResult: Equatable {
        let selectedShape: String?
        let isCropDisabled: Bool
        let crop: CGRect?
    }

    private static let aspectPresets: [(label: String, ratio: CGFloat?)] = [
        ("Original", nil),
        ("Free", nil),
        ("1:1", 1.0),
        ("16:9", 16.0 / 9.0),
        ("4:3", 4.0 / 3.0)
    ]
    private static let namedRatioPresets: Set<String> = ["1:1", "16:9", "4:3"]
    private static let orientableRatioPresets: Set<String> = ["16:9", "4:3"]
    private static let labelWidth: CGFloat = 130
    // Tight enough to only absorb floating-point noise from presetRect's
    // own arithmetic, not real pixel-level differences.
    private static let ratioTolerance: CGFloat = 0.0005

    var body: some View {
        let crop = viewModel.crop
        let selectedLabel = viewModel.isCropDisabled ? "Original" : viewModel.selectedCropShape
        let orientation = Self.orientation(of: crop)
        let canReorient = !viewModel.isCropDisabled && Self.orientableRatioPresets.contains(viewModel.selectedCropShape)

        VStack(spacing: 8) {
            Picker(selection: Binding(
                get: { selectedLabel },
                set: { newLabel in
                    let sourceSize = viewModel.mediaFile?.resolution ?? .zero
                    let result = Self.selection(
                        afterSelecting: newLabel, currentOrientation: orientation,
                        sourceSize: sourceSize, existingCrop: viewModel.crop
                    )
                    viewModel.isCropDisabled = result.isCropDisabled
                    if let selectedShape = result.selectedShape {
                        viewModel.selectedCropShape = selectedShape
                    }
                    viewModel.crop = result.crop
                }
            )) {
                ForEach(Self.aspectPresets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
            } label: {
                Text("Crop")
                    .frame(width: Self.labelWidth, alignment: .trailing)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: crop) { _, newCrop in
                viewModel.selectedCropShape = Self.driftedSelection(currentShape: viewModel.selectedCropShape, crop: newCrop)
            }

            HStack {
                Text("")
                    .frame(width: Self.labelWidth, alignment: .trailing)
                Picker(selection: Binding(
                    get: { orientation },
                    set: { newValue in
                        guard canReorient, let crop = viewModel.crop else { return }
                        let sourceSize = viewModel.mediaFile?.resolution ?? .zero
                        viewModel.crop = Self.reoriented(crop, to: newValue, sourceSize: sourceSize)
                    }
                )) {
                    Text("Landscape").tag(Orientation.landscape)
                    Text("Portrait").tag(Orientation.portrait)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!canReorient)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `selectedShape == nil` means "leave `selectedCropShape` as-is" —
    /// only "Original" does this, since it's driven by `isCropDisabled` instead.
    static func selection(
        afterSelecting label: String, currentOrientation: Orientation,
        sourceSize: CGSize, existingCrop: CGRect?
    ) -> SelectionResult {
        switch label {
        case "Original":
            return SelectionResult(selectedShape: nil, isCropDisabled: true, crop: nil)
        case "Free":
            let crop = existingCrop ?? defaultFreeRect(sourceSize: sourceSize)
            return SelectionResult(selectedShape: "Free", isCropDisabled: false, crop: crop)
        default:
            guard let preset = aspectPresets.first(where: { $0.label == label }), let ratio = preset.ratio else {
                return SelectionResult(selectedShape: nil, isCropDisabled: false, crop: existingCrop)
            }
            let crop = presetRect(ratio: ratio, orientation: currentOrientation, sourceSize: sourceSize)
            return SelectionResult(selectedShape: label, isCropDisabled: false, crop: crop)
        }
    }

    /// Falls back to "Free" if `currentShape`'s ratio drifted off via a
    /// resize; never advances toward a preset the other way.
    static func driftedSelection(currentShape: String, crop: CGRect?) -> String {
        guard namedRatioPresets.contains(currentShape) else { return currentShape }
        return matchedPreset(for: crop) == currentShape ? currentShape : "Free"
    }

    static func matchedPreset(for crop: CGRect?) -> String? {
        guard let crop, crop.width > 0, crop.height > 0 else { return nil }
        let ratio = max(crop.width, crop.height) / min(crop.width, crop.height)
        for preset in aspectPresets {
            guard let target = preset.ratio else { continue }
            if abs(ratio - target) < ratioTolerance { return preset.label }
        }
        return nil
    }

    /// A 5:4 rect fitted to the source, then inset slightly so the corner
    /// handles land somewhere graspable rather than flush against the edge.
    static func defaultFreeRect(sourceSize: CGSize) -> CGRect? {
        guard let fitted = presetRect(ratio: 5.0 / 4.0, orientation: .landscape, sourceSize: sourceSize) else { return nil }
        let padding: CGFloat = 0.9
        let width = fitted.width * padding
        let height = fitted.height * padding
        return CGRect(x: (sourceSize.width - width) / 2, y: (sourceSize.height - height) / 2, width: width, height: height)
    }

    static func orientation(of crop: CGRect?) -> Orientation {
        guard let crop, crop.width < crop.height else { return .landscape }
        return .portrait
    }

    static func presetRect(ratio: CGFloat, orientation: Orientation, sourceSize: CGSize) -> CGRect? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let targetRatio = orientation == .landscape ? ratio : 1 / ratio
        let sourceAspect = sourceSize.width / sourceSize.height
        let width: CGFloat
        let height: CGFloat
        if targetRatio > sourceAspect {
            width = sourceSize.width
            height = width / targetRatio
        } else {
            height = sourceSize.height
            width = height * targetRatio
        }
        return CGRect(x: (sourceSize.width - width) / 2, y: (sourceSize.height - height) / 2, width: width, height: height)
    }

    /// Re-derives a fitted rect for the target orientation rather than
    /// swapping width/height in place — an in-place swap of an edge-to-edge
    /// rect can get clamped unevenly and collapse toward square.
    static func reoriented(_ crop: CGRect, to orientation: Orientation, sourceSize: CGSize) -> CGRect? {
        guard crop.width > 0, crop.height > 0 else { return nil }
        let ratio = max(crop.width, crop.height) / min(crop.width, crop.height)
        return presetRect(ratio: ratio, orientation: orientation, sourceSize: sourceSize)
    }
}
