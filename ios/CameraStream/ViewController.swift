import UIKit
import AVFoundation

class ViewController: UIViewController {

    private let camera = CameraCapture()
    private let server = TCPServer()
    private var isStreaming = false

    private let PORT: UInt16 = 8080

    // MARK: - UI Elements

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Not streaming"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let clientLabel: UILabel = {
        let label = UILabel()
        label.text = "No clients connected"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let startButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Start Streaming"
        config.cornerStyle = .large
        config.baseBackgroundColor = .systemGreen
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let switchCameraButton: UIButton = {
        var config = UIButton.Configuration.gray()
        config.title = "Switch Camera"
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        return button
    }()

    private let qualitySegment: UISegmentedControl = {
        let control = UISegmentedControl(items: ["720p", "1080p", "4K"])
        control.selectedSegmentIndex = 1
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private let portLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let fpsLabel: UILabel = {
        let label = UILabel()
        label.text = "FPS: --"
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var frameCount = 0
    private var lastFPSUpdate = Date()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupActions()
        setupCamera()
        requestCameraPermission()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "iPhone OBS Camera"

        let stack = UIStackView(arrangedSubviews: [
            makeSectionLabel("Resolution"),
            qualitySegment,
            startButton,
            switchCameraButton,
            statusLabel,
            clientLabel,
            portLabel,
            fpsLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])

        portLabel.text = "Connect: iproxy \(PORT) \(PORT)"
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    private func setupActions() {
        startButton.addTarget(self, action: #selector(toggleStreaming), for: .touchUpInside)
        switchCameraButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        qualitySegment.addTarget(self, action: #selector(qualityChanged), for: .valueChanged)
    }

    private func setupCamera() {
        camera.onFrame = { [weak self] jpegData in
            guard let self = self else { return }
            self.server.sendFrame(jpegData)
            self.frameCount += 1

            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastFPSUpdate)
            if elapsed >= 1.0 {
                let fps = Double(self.frameCount) / elapsed
                self.frameCount = 0
                self.lastFPSUpdate = now
                DispatchQueue.main.async {
                    self.fpsLabel.text = String(format: "FPS: %.1f", fps)
                }
            }
        }

        server.onClientConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.updateClientLabel()
            }
        }

        server.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.updateClientLabel()
            }
        }
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.showAlert("Camera Permission Required", message: "Please enable camera access in Settings.")
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleStreaming() {
        if isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    private func startStreaming() {
        let preset: AVCaptureSession.Preset
        switch qualitySegment.selectedSegmentIndex {
        case 0: preset = .hd1280x720
        case 1: preset = .hd1920x1080
        case 2: preset = .hd4K3840x2160
        default: preset = .hd1920x1080
        }
        camera.resolution = preset

        do {
            try server.start(port: PORT)
            try camera.start()

            isStreaming = true
            updateUI()
        } catch {
            showAlert("Error", message: error.localizedDescription)
        }
    }

    private func stopStreaming() {
        camera.stop()
        server.stop()
        isStreaming = false
        updateUI()
    }

    @objc private func switchCamera() {
        camera.switchCamera()
    }

    @objc private func qualityChanged() {
        // If already streaming, restart with new quality
        if isStreaming {
            stopStreaming()
            startStreaming()
        }
    }

    // MARK: - UI Updates

    private func updateUI() {
        var config = startButton.configuration
        config?.title = isStreaming ? "Stop Streaming" : "Start Streaming"
        config?.baseBackgroundColor = isStreaming ? .systemRed : .systemGreen
        startButton.configuration = config

        switchCameraButton.isEnabled = isStreaming
        qualitySegment.isEnabled = !isStreaming

        statusLabel.text = isStreaming ? "Streaming on port \(PORT)" : "Not streaming"
        statusLabel.textColor = isStreaming ? .systemGreen : .secondaryLabel

        if !isStreaming {
            fpsLabel.text = "FPS: --"
            clientLabel.text = "No clients connected"
        }
    }

    private func updateClientLabel() {
        let count = server.clientCount
        clientLabel.text = count == 0 ? "No clients connected" : "\(count) client(s) connected"
        clientLabel.textColor = count > 0 ? .systemGreen : .secondaryLabel
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
