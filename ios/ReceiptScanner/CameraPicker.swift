import SwiftUI
import UIKit

/// Plain camera capture — the photo is used as taken, without auto-cropping. Uses its own shutter
/// instead of the system controls so there's no "Retake / Use Photo" step: the shot goes straight on.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.allowsEditing = false
        vc.showsCameraControls = false
        vc.delegate = context.coordinator

        let bounds = UIScreen.main.bounds
        // The 4:3 preview sits at the top by default; center it vertically.
        let previewHeight = bounds.width * 4 / 3
        vc.cameraViewTransform = CGAffineTransform(translationX: 0, y: max((bounds.height - previewHeight) / 2, 0))

        let overlay = CameraOverlay(frame: bounds)
        overlay.onShutter = { [weak vc] in vc?.takePicture() }
        overlay.onCancel = onCancel
        overlay.onFlash = { [weak vc, weak overlay] in
            guard let vc else { return }
            vc.cameraFlashMode = switch vc.cameraFlashMode {
            case .auto: .on
            case .on: .off
            default: .auto
            }
            overlay?.showFlash(vc.cameraFlashMode)
        }
        overlay.showFlash(vc.cameraFlashMode)
        vc.cameraOverlayView = overlay
        context.coordinator.overlay = overlay
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        weak var overlay: CameraOverlay?
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onFinish(img) } else { overlay?.reset() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}

/// Shutter, cancel and flash buttons over the live preview.
final class CameraOverlay: UIView {
    var onShutter: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFlash: () -> Void = {}

    private let shutter = UIButton(type: .custom)
    private let flash = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 34
        shutter.layer.borderWidth = 4
        shutter.layer.borderColor = UIColor.black.withAlphaComponent(0.25).cgColor
        shutter.accessibilityLabel = "Take photo"
        shutter.addAction(UIAction { [weak self] _ in
            guard let self, self.shutter.isEnabled else { return }
            self.shutter.isEnabled = false // one shot per tap; the picker closes when it's taken
            self.shutter.alpha = 0.5
            self.onShutter()
        }, for: .touchUpInside)

        let cancel = UIButton(type: .system)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancel.tintColor = .white
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel() }, for: .touchUpInside)

        flash.translatesAutoresizingMaskIntoConstraints = false
        flash.tintColor = .white
        flash.addAction(UIAction { [weak self] _ in self?.onFlash() }, for: .touchUpInside)

        [shutter, cancel, flash].forEach(addSubview)
        NSLayoutConstraint.activate([
            shutter.widthAnchor.constraint(equalToConstant: 68),
            shutter.heightAnchor.constraint(equalToConstant: 68),
            shutter.centerXAnchor.constraint(equalTo: centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            cancel.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            flash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            flash.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            flash.widthAnchor.constraint(equalToConstant: 44),
            flash.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showFlash(_ mode: UIImagePickerController.CameraFlashMode) {
        let (symbol, label) = switch mode {
        case .on: ("bolt.fill", "Flash on")
        case .off: ("bolt.slash.fill", "Flash off")
        default: ("bolt.badge.automatic.fill", "Flash auto")
        }
        flash.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
        flash.accessibilityLabel = label
    }

    func reset() {
        shutter.isEnabled = true
        shutter.alpha = 1
    }
}
