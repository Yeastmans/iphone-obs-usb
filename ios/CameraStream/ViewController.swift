import UIKit
import AVFoundation

class ViewController: UIViewController {

    private let camera = CameraCapture()
    private let server = TCPServer()
    private var isStreaming = false
    private var isLandscapeLocked = false
    private let PORT: UInt16 = 8080

    // MARK: - Preview Layer

    private var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Settings Screen

    private lazy var settingsView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let qualitySegment: UISegmentedControl = {
        let control = UISegmentedControl(items: ["720p", "1080p", "4K"])
        control.selectedSegmentIndex = 1
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
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

    private let settingsStatusLabel: UILabel = {
        let label = UILabel()
        label.text = "Tap Start Streaming to begin"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let portLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Live Preview Screen

    private lazy var previewView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    // ◀ Settings — top-left overlay button
    private let backToSettingsButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Settings"
        config.image = UIImage(systemName: "chevron.left")
        config.imagePadding = 4
        config.cornerStyle = .medium
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Bottom-left: swaps front ↔ back camera ONLY
    private let flipCameraButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Flip Camera"
        config.image = UIImage(systemName: "camera.rotate.fill")
        config.imagePlacement = .top
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Bottom-right: locks/unlocks landscape orientation ONLY
    private let landscapeToggleButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Landscape"
        config.image = UIImage(systemName: "rotate.right.fill")
        config.imagePlacement = .top
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let previewFPSLabel: UILabel = {
        let label = UILabel()
        label.text = "  FPS: --  "
        label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let previewClientLabel: UILabel = {
        let label = UILabel()
        label.text = "  No clients  "
        label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let liveBadgeLabel: UILabel = {
        let label = UILabel()
        label.text = "  ● LIVE  "
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .systemRed
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - State

    private var frameCount = 0
    private var lastFPSUpdate = Date()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSettingsUI()
        setupPreviewUI()
        setupPreviewLayer()
        setupActions()
        setupCamera()
        portLabel.text = "iproxy \(PORT) \(PORT)"
        requestCameraPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep preview layer filling the full screen as bounds change (rotation etc.)
        previewLayer?.frame = previewView.bounds
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return AppDelegate.shared.orientationLock
    }

    override var shouldAutorotate: Bool { true }

    override var prefersStatusBarHidden: Bool {
        // Hide status bar when in full-screen streaming preview
        return isStreaming
    }

    // MARK: - Settings UI Setup

    private func setupSettingsUI() {
        view.addSubview(settingsView)
        NSLayoutConstraint.activate([
            settingsView.topAnchor.constraint(equalTo: view.topAnchor),
            settingsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            settingsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let titleLabel = UILabel()
        titleLabel.text = "iPhone OBS Camera"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textAlignment = .center

        let resolutionHeader = makeSectionLabel("Resolution")
        let connectionHeader = makeSectionLabel("USB Connection (iproxy)")

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            resolutionHeader,
            qualitySegment,
            connectionHeader,
            portLabel,
            startButton,
            settingsStatusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: resolutionHeader)
        stack.setCustomSpacing(8, after: connectionHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false

        settingsView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: settingsView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: settingsView.trailingAnchor, constant: -28)
        ])
    }

    // MARK: - Preview UI Setup

    private func setupPreviewUI() {
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        previewView.addSubview(backToSettingsButton)
        previewView.addSubview(liveBadgeLabel)
        previewView.addSubview(previewFPSLabel)
        previewView.addSubview(previewClientLabel)
        previewView.addSubview(flipCameraButton)
        previewView.addSubview(landscapeToggleButton)

        let safe = previewView.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            // ◀ Settings — top-left
            backToSettingsButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            backToSettingsButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),

            // ● LIVE — top-center
            liveBadgeLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            liveBadgeLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),

            // FPS — top-right
            previewFPSLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            previewFPSLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),

            // Client count — below FPS
            previewClientLabel.topAnchor.constraint(equalTo: previewFPSLabel.bottomAnchor, constant: 6),
            previewClientLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),

            // Flip Camera — bottom-left
            flipCameraButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            flipCameraButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            flipCameraButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            // Landscape toggle — bottom-right
            landscapeToggleButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            landscapeToggleButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            landscapeToggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func setupPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: camera.captureSession)
        layer.videoGravity = .resizeAspectFill
        // Insert below all overlay controls
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    // MARK: - Actions Setup

    private func setupActions() {
        startButton.addTarget(self, action: #selector(startStreaming), for: .touchUpInside)
        backToSettingsButton.addTarget(self, action: #selector(returnToSettings), for: .touchUpInside)
        flipCameraButton.addTarget(self, action: #selector(flipCamera), for: .touchUpInside)
        landscapeToggleButton.addTarget(self, action: #selector(toggleLandscape), for: .touchUpInside)
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
                    self.previewFPSLabel.text = String(format: "  FPS: %.1f  ", fps)
                }
            }
        }

        server.onClientConnected = { [weak self] in
            DispatchQueue.main.async { self?.updateClientLabel() }
        }
        server.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async { self?.updateClientLabel() }
        }
    }

    // MARK: - Streaming Actions

    @objc private func startStreaming() {
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
            showPreview()
        } catch {
            showAlert("Error", message: error.localizedDescription)
        }
    }

    @objc private func returnToSettings() {
        // Always reset to portrait when leaving the preview screen
        if isLandscapeLocked {
            setOrientationLock(.portrait)
            isLandscapeLocked = false
            resetLandscapeButtonAppearance()
        }
        camera.stop()
        server.stop()
        isStreaming = false
        // Reset preview stats
        previewFPSLabel.text = "  FPS: --  "
        previewClientLabel.text = "  No clients  "
        settingsStatusLabel.text = "Tap Start Streaming to begin"
        settingsStatusLabel.textColor = .secondaryLabel
        hidePreview()
    }

    // MARK: - Flip Camera (camera swap ONLY — no orientation change)

    @objc private func flipCamera() {
        camera.switchCamera()
    }

    // MARK: - Landscape Toggle (orientation ONLY — no camera swap)

    @objc private func toggleLandscape() {
        if isLandscapeLocked {
            setOrientationLock(.portrait)
            isLandscapeLocked = false
            resetLandscapeButtonAppearance()
        } else {
            setOrientationLock(.landscape)
            isLandscapeLocked = true
            setLandscapeButtonActiveAppearance()
        }
    }

    @objc private func qualityChanged() {
        // Quality change takes effect on the next stream start — no action needed here
    }

    // MARK: - Orientation Lock

    private func setOrientationLock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.shared.orientationLock = mask

        if #available(iOS 16.0, *) {
            guard let windowScene = view.window?.windowScene else { return }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(prefs) { error in
                print("[Orientation] Update error: \(error.localizedDescription)")
            }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            let rawValue: Int = (mask == .landscape)
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue
            UIDevice.current.setValue(rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func setLandscapeButtonActiveAppearance() {
        var config = landscapeToggleButton.configuration
        config?.title = "Portrait"
        config?.image = UIImage(systemName: "rotate.left.fill")
        config?.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.75)
        landscapeToggleButton.configuration = config
    }

    private func resetLandscapeButtonAppearance() {
        var config = landscapeToggleButton.configuration
        config?.title = "Landscape"
        config?.image = UIImage(systemName: "rotate.right.fill")
        config?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        landscapeToggleButton.configuration = config
    }

    // MARK: - Screen Transitions

    private func showPreview() {
        settingsView.isHidden = true
        previewView.isHidden = false
        setNeedsStatusBarAppearanceUpdate()
    }

    private func hidePreview() {
        previewView.isHidden = true
        settingsView.isHidden = false
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - UI Helpers

    private func updateClientLabel() {
        let count = server.clientCount
        previewClientLabel.text = count == 0 ? "  No clients  " : "  \(count) client(s)  "
        previewClientLabel.textColor = count > 0 ? .systemGreen : .white
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.showAlert("Camera Permission Required",
                                   message: "Please enable camera access in Settings.")
                }
            }
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
