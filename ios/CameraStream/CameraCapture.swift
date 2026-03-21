import AVFoundation
import UIKit
import CoreImage

class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // Exposed so ViewController can attach AVCaptureVideoPreviewLayer
    let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "camera.processing", qos: .userInteractive)
    private let ciContext = CIContext()

    var onFrame: ((Data) -> Void)?
    var onCameraPositionChanged: ((AVCaptureDevice.Position) -> Void)?

    var quality: CGFloat = 1.0  // 1.0 = highest quality JPEG (near-lossless)
    var resolution: AVCaptureSession.Preset = .hd1920x1080

    /// Tracks which camera is currently active (back or front).
    private(set) var currentPosition: AVCaptureDevice.Position = .back

    // MARK: - Start / Stop

    func start() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }

        // Configure camera for best quality
        try device.lockForConfiguration()
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = resolution

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Set stream output orientation to landscape (horizontal video for OBS)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        captureSession.commitConfiguration()
        currentPosition = .back

        processingQueue.async {
            self.captureSession.startRunning()
        }
    }

    func stop() {
        captureSession.stopRunning()
        // Clean up inputs/outputs so start() can reconfigure cleanly on next call
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.commitConfiguration()
    }

    // MARK: - Camera Switch

    /// Swaps between back and front camera. Does NOT change orientation.
    func switchCamera() {
        captureSession.beginConfiguration()

        guard let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput else {
            captureSession.commitConfiguration()
            return
        }

        let currentPos = currentInput.device.position
        let newPosition: AVCaptureDevice.Position = currentPos == .back ? .front : .back

        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.removeInput(currentInput)
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
        }

        // Mirror front camera output so OBS receives a natural image
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = (newPosition == .front)
            }
        }

        captureSession.commitConfiguration()
        currentPosition = newPosition
        onCameraPositionChanged?(newPosition)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)

        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return }

        onFrame?(jpegData)
    }
}

enum CameraError: Error {
    case noCamera
    case configurationFailed
}
