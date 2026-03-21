import AVFoundation
import VideoToolbox
import CoreMedia

// MARK: - Global VT callback (must be a C-compatible free function)

private func vtEncoderOutputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefcon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sb = sampleBuffer, let rc = refcon else { return }
    Unmanaged<CameraCapture>.fromOpaque(rc).takeUnretainedValue()
        .handleEncodedVideo(sampleBuffer: sb)
}

// MARK: - CameraCapture

class CameraCapture: NSObject {

    // Exposed so ViewController can attach AVCaptureVideoPreviewLayer
    let captureSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue  = DispatchQueue(label: "camera.video",  qos: .userInteractive)
    private let audioQueue  = DispatchQueue(label: "camera.audio",  qos: .userInteractive)

    // VideoToolbox H.264 encoder
    private var vtSession: VTCompressionSession?

    // AVAudioEngine for mic capture → AAC
    private let audioEngine        = AVAudioEngine()
    private var audioConverter:     AVAudioConverter?
    private var outputAudioFormat:  AVAudioFormat?

    // Callbacks — ViewController sets these
    var onVideoPacket:          ((Data) -> Void)?   // H.264 Annex B
    var onAudioPacket:          ((Data) -> Void)?   // AAC-ADTS
    var onCameraPositionChanged:((AVCaptureDevice.Position) -> Void)?

    var resolution: AVCaptureSession.Preset = .hd1920x1080  // kept for API compat; ignored at 60fps
    private(set) var currentPosition: AVCaptureDevice.Position = .back

    // Timestamps for relative PTS (seconds since stream start)
    private var streamStartTime: CMTime = .invalid

    // MARK: - Start

    func start() throws {
        // ── Audio session ───────────────────────────────────────────────
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord,
                                     mode: .videoRecording,
                                     options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)

        // ── Video device: pick highest resolution format at 60fps ───────
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video, position: .back) else {
            throw CameraError.noCamera
        }

        try videoDevice.lockForConfiguration()

        // Prefer 1080p60, fall back to best available 60fps format
        let fmt60 = videoDevice.formats
            .filter { fmt in
                fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
            }
            .sorted { a, b in
                CMVideoFormatDescriptionGetDimensions(a.formatDescription).width >
                CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
            }
            .first

        if let fmt = fmt60 {
            videoDevice.activeFormat = fmt
            videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        }
        if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
            videoDevice.exposureMode = .continuousAutoExposure
        }
        if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
            videoDevice.focusMode = .continuousAutoFocus
        }
        videoDevice.unlockForConfiguration()

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .inputPriority   // respect device's native format

        if captureSession.canAddInput(videoInput)  { captureSession.addInput(videoInput) }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

        if let conn = videoOutput.connection(with: .video),
           conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }

        captureSession.commitConfiguration()

        // ── VideoToolbox encoder ────────────────────────────────────────
        let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        try setupVideoEncoder(width: dims.width, height: dims.height)

        // ── AVAudioEngine mic tap → AAC ─────────────────────────────────
        try startAudioEngine()

        currentPosition  = .back
        streamStartTime  = .invalid

        videoQueue.async { self.captureSession.startRunning() }
    }

    // MARK: - VideoToolbox setup

    private func setupVideoEncoder(width: Int32, height: Int32) throws {
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var session: VTCompressionSession?

        let st = VTCompressionSessionCreate(
            allocator:                  kCFAllocatorDefault,
            width:                      width,
            height:                     height,
            codecType:                  kCMVideoCodecType_H264,
            encoderSpecification:       spec,
            imageBufferAttributes:      nil,
            compressedDataAllocator:    nil,
            outputCallback:             vtEncoderOutputCallback,
            refcon:                     Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut:      &session
        )
        guard st == noErr, let session = session else { throw CameraError.configurationFailed }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,         value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,       value: NSNumber(value: 8_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,    value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,  value: NSNumber(value: 120))
        VTCompressionSessionPrepareToEncodeFrames(session)

        vtSession = session
    }

    // MARK: - AVAudioEngine setup

    private func startAudioEngine() throws {
        let inputNode   = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Build AAC output format (44 100 Hz, mono, MPEG-4 AAC)
        var aacASBD = AudioStreamBasicDescription(
            mSampleRate:       44_100,
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  1024,
            mBytesPerFrame:    0,
            mChannelsPerFrame: 1,
            mBitsPerChannel:   0,
            mReserved:         0
        )
        guard let aacFormat = AVAudioFormat(streamDescription: &aacASBD) else {
            throw CameraError.configurationFailed
        }
        outputAudioFormat = aacFormat

        let conv = AVAudioConverter(from: inputFormat, to: aacFormat)
        conv?.bitRate = 96_000
        audioConverter = conv

        // Tap: 1024 frames matches one AAC packet exactly
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcm, _ in
            self?.encodeAudio(pcm)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Stop

    func stop() {
        // Stop audio first
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Flush and tear down video encoder
        if let vt = vtSession {
            VTCompressionSessionCompleteFrames(vt, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(vt)
            vtSession = nil
        }

        captureSession.stopRunning()
        captureSession.beginConfiguration()
        captureSession.inputs .forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.commitConfiguration()

        audioConverter    = nil
        outputAudioFormat = nil
        streamStartTime   = .invalid
    }

    // MARK: - Camera switch

    func switchCamera() {
        captureSession.beginConfiguration()
        guard let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput else {
            captureSession.commitConfiguration(); return
        }

        let newPos: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos),
              let newInput  = try? AVCaptureDeviceInput(device: newDevice) else {
            captureSession.commitConfiguration(); return
        }

        captureSession.removeInput(currentInput)
        if captureSession.canAddInput(newInput) { captureSession.addInput(newInput) }

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (newPos == .front) }
        }

        captureSession.commitConfiguration()
        currentPosition = newPos
        onCameraPositionChanged?(newPos)
    }

    // MARK: - Video encoding output

    func handleEncodedVideo(sampleBuffer: CMSampleBuffer) {
        // Track stream start time
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if streamStartTime == .invalid { streamStartTime = pts }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                   createIfNecessary: false)
                          as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var annexB = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])

        // Prepend SPS + PPS on keyframes
        if isKeyFrame, let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmtDesc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var sz  = 0
                let st  = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmtDesc, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let ptr = ptr {
                    annexB.append(startCode)
                    annexB.append(Data(bytes: ptr, count: sz))
                }
            }
        }

        // Convert AVCC length-prefixed NALUs → Annex B start-code-prefixed
        let totalLen = CMBlockBufferGetDataLength(dataBuffer)
        var offset   = 0
        while offset < totalLen {
            var naluLenBE: UInt32 = 0
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset, dataLength: 4,
                                       destination: &naluLenBE)
            let naluLen = Int(CFSwapInt32BigToHost(naluLenBE))
            offset += 4

            var nalu = Data(count: naluLen)
            nalu.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset,
                                           dataLength: naluLen, destination: $0.baseAddress!)
            }
            annexB.append(startCode)
            annexB.append(nalu)
            offset += naluLen
        }

        onVideoPacket?(annexB)
    }

    // MARK: - Audio encoding

    private func encodeAudio(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter    = audioConverter,
              let outputFormat = outputAudioFormat else { return }

        guard let outputBuffer = AVAudioCompressedBuffer(
            format:            outputFormat,
            packetCapacity:    1,
            maximumPacketSize: converter.maximumOutputPacketSize
        ) else { return }

        var inputConsumed = false
        var convError: NSError?

        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed     = true
            return inputBuffer
        }

        guard convError == nil, outputBuffer.byteLength > 0 else { return }

        let aacBytes  = Int(outputBuffer.byteLength)
        let aacData   = Data(bytes: outputBuffer.data, count: aacBytes)
        let adtsFrame = makeADTSHeader(aacDataLength: aacBytes) + aacData

        onAudioPacket?(adtsFrame)
    }

    // MARK: - ADTS header (7 bytes, no CRC)
    // AAC-LC, 44 100 Hz (index 4), mono (channel config 1)

    private func makeADTSHeader(aacDataLength: Int) -> Data {
        let totalLength = aacDataLength + 7
        var h = Data(count: 7)
        h[0] = 0xFF
        h[1] = 0xF1                                                          // MPEG-4, no CRC
        h[2] = 0x50                                                          // AAC-LC, 44100, ch-config bit2=0
        h[3] = UInt8(0x40 | ((totalLength >> 11) & 0x03))                   // ch-config bits1:0=01, frame_len hi
        h[4] = UInt8((totalLength >> 3) & 0xFF)
        h[5] = UInt8(((totalLength & 0x07) << 5) | 0x1F)
        h[6] = 0xFC
        return h
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let vt = vtSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(vt, imageBuffer: imageBuffer,
                                        presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: nil, sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }
}

// MARK: - Errors

enum CameraError: Error {
    case noCamera
    case noAudio
    case configurationFailed
}
