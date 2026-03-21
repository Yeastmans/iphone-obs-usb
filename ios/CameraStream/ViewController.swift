import UIKit
import AVFoundation

class ViewController: UIViewController {

    private let camera = CameraCapture()
    private let server = TCPServer()
    private var isStreaming      = false
    private var isLandscapeLocked = false
    private let PORT: UInt16     = 8080

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
        let c = UISegmentedControl(items: ["720p", "1080p", "4K"])
        c.selectedSegmentIndex = 1
        c.translatesAutoresizingMaskIntoConstraints = false
        return c
    }()

    private let startButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Start Streaming"
        cfg.cornerStyle = .large
        cfg.baseBackgroundColor = .systemGreen
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let settingsStatusLabel: UILabel = {
        let l = UILabel()
        l.text = "Tap Start Streaming to begin"
        l.textAlignment = .center
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let portLabel: UILabel = {
        let l = UILabel()
        l.textAlignment = .center
        l.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        l.textColor = .label
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - Live Preview Screen

    private lazy var previewView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let backToSettingsButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Settings"
        cfg.image = UIImage(systemName: "chevron.left")
        cfg.imagePadding = 4
        cfg.cornerStyle = .medium
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let flipCameraButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Flip Camera"
        cfg.image = UIImage(systemName: "camera.rotate.fill")
        cfg.imagePlacement = .top
        cfg.imagePadding = 8
        cfg.cornerStyle = .large
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let landscapeToggleButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Landscape"
        cfg.image = UIImage(systemName: "rotate.right.fill")
        cfg.imagePlacement = .top
        cfg.imagePadding = 8
        cfg.cornerStyle = .large
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let previewFPSLabel: UILabel = {
        let l = UILabel()
        l.text = "  FPS: --  "
        l.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        l.textAlignment = .center
        l.layer.cornerRadius = 6
        l.layer.masksToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let previewClientLabel: UILabel = {
        let l = UILabel()
        l.text = "  No clients  "
        l.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        l.textAlignment = .center
        l.layer.cornerRadius = 6
        l.layer.masksToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let liveBadgeLabel: UILabel = {
        let l = UILabel()
        l.text = "  ● LIVE  "
        l.font = .systemFont(ofSize: 13, weight: .bold)
        l.textColor = .systemRed
        l.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        l.textAlignment = .center
        l.layer.cornerRadius = 8
        l.layer.masksToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - FPS tracking

    private var frameCount   = 0
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
        requestPermissions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppDelegate.shared.orientationLock
    }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { isStreaming }

    // MARK: - Settings UI

    private func setupSettingsUI() {
        view.addSubview(settingsView)
        NSLayoutConstraint.activate([
            settingsView.topAnchor.constraint(equalTo: view.topAnchor),
            settingsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            settingsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let title = UILabel()
        title.text = "iPhone OBS Camera"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [
            title,
            makeSectionLabel("Resolution"),
            qualitySegment,
            makeSectionLabel("USB Connection (iproxy)"),
            portLabel,
            startButton,
            settingsStatusLabel
        ])
        stack.axis    = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        settingsView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: settingsView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsView.leadingAnchor,  constant:  28),
            stack.trailingAnchor.constraint(equalTo: settingsView.trailingAnchor, constant: -28)
        ])
    }

    // MARK: - Preview UI

    private func setupPreviewUI() {
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        [backToSettingsButton, liveBadgeLabel, previewFPSLabel,
         previewClientLabel, flipCameraButton, landscapeToggleButton].forEach {
            previewView.addSubview($0)
        }

        let safe = previewView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            backToSettingsButton.topAnchor.constraint(equalTo: safe.topAnchor,     constant:  14),
            backToSettingsButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),

            liveBadgeLabel.topAnchor.constraint(equalTo: safe.topAnchor,           constant:  14),
            liveBadgeLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),

            previewFPSLabel.topAnchor.constraint(equalTo: safe.topAnchor,          constant:  14),
            previewFPSLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),

            previewClientLabel.topAnchor.constraint(equalTo: previewFPSLabel.bottomAnchor, constant: 6),
            previewClientLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor,     constant: -14),

            flipCameraButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor,   constant: -24),
            flipCameraButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant:  24),
            flipCameraButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            landscapeToggleButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor,    constant: -24),
            landscapeToggleButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            landscapeToggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func setupPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: camera.captureSession)
        layer.videoGravity = .resizeAspectFill
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    // MARK: - Actions wiring

    private func setupActions() {
        startButton.addTarget(self,          action: #selector(startStreaming),    for: .touchUpInside)
        backToSettingsButton.addTarget(self, action: #selector(returnToSettings), for: .touchUpInside)
        flipCameraButton.addTarget(self,     action: #selector(flipCamera),        for: .touchUpInside)
        landscapeToggleButton.addTarget(self,action: #selector(toggleLandscape),   for: .touchUpInside)
        qualitySegment.addTarget(self,       action: #selector(qualityChanged),     for: .valueChanged)
    }

    private func setupCamera() {
        // Video frames → FPS counter + forward to server
        camera.onVideoPacket = { [weak self] data in
            guard let self = self else { return }
            self.server.sendPacket(type: .video, data: data)
            self.frameCount += 1
            let now     = Date()
            let elapsed = now.timeIntervalSince(self.lastFPSUpdate)
            if elapsed >= 1.0 {
                let fps = Double(self.frameCount) / elapsed
                self.frameCount   = 0
                self.lastFPSUpdate = now
                DispatchQueue.main.async {
                    self.previewFPSLabel.text = String(format: "  FPS: %.1f  ", fps)
                }
            }
        }

        // Audio frames → forward to server
        camera.onAudioPacket = { [weak self] data in
            self?.server.sendPacket(type: .audio, data: data)
        }

        server.onClientConnected    = { [weak self] in DispatchQueue.main.async { self?.updateClientLabel() } }
        server.onClientDisconnected = { [weak self] in DispatchQueue.main.async { self?.updateClientLabel() } }
    }

    // MARK: - Streaming

    @objc private func startStreaming() {
        // Resolution selector kept for future use; at 60fps we use .inputPriority
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
        if isLandscapeLocked {
            setOrientationLock(.portrait)
            isLandscapeLocked = false
            resetLandscapeButton()
        }
        camera.stop()
        server.stop()
        isStreaming = false
        previewFPSLabel.text    = "  FPS: --  "
        previewClientLabel.text = "  No clients  "
        settingsStatusLabel.text  = "Tap Start Streaming to begin"
        settingsStatusLabel.textColor = .secondaryLabel
        hidePreview()
    }

    // MARK: - Flip Camera (camera only — no orientation change)

    @objc private func flipCamera() {
        camera.switchCamera()
    }

    // MARK: - Landscape Toggle (orientation only — no camera switch)

    @objc private func toggleLandscape() {
        if isLandscapeLocked {
            setOrientationLock(.portrait)
            isLandscapeLocked = false
            resetLandscapeButton()
        } else {
            setOrientationLock(.landscape)
            isLandscapeLocked = true
            activateLandscapeButton()
        }
    }

    @objc private func qualityChanged() { /* takes effect on next stream start */ }

    // MARK: - Orientation

    private func setOrientationLock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.shared.orientationLock = mask
        if #available(iOS 16.0, *) {
            guard let scene = view.window?.windowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { e in
                print("[Orientation] \(e.localizedDescription)")
            }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            let raw = (mask == .landscape)
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue
            UIDevice.current.setValue(raw, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func activateLandscapeButton() {
        var cfg = landscapeToggleButton.configuration
        cfg?.title = "Portrait"
        cfg?.image = UIImage(systemName: "rotate.left.fill")
        cfg?.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.75)
        landscapeToggleButton.configuration = cfg
    }

    private func resetLandscapeButton() {
        var cfg = landscapeToggleButton.configuration
        cfg?.title = "Landscape"
        cfg?.image = UIImage(systemName: "rotate.right.fill")
        cfg?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        landscapeToggleButton.configuration = cfg
    }

    // MARK: - Screen transitions

    private func showPreview() {
        settingsView.isHidden = true
        previewView.isHidden  = false
        setNeedsStatusBarAppearanceUpdate()
    }

    private func hidePreview() {
        previewView.isHidden  = true
        settingsView.isHidden = false
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Helpers

    private func updateClientLabel() {
        let n = server.clientCount
        previewClientLabel.text  = n == 0 ? "  No clients  " : "  \(n) client(s)  "
        previewClientLabel.textColor = n > 0 ? .systemGreen : .white
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        return l
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    private func showAlert(_ title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
