import Foundation
import AVFoundation
import CoreMedia

public protocol CameraDelegate {
  func didCaptureBuffer(sampleBuffer: CMSampleBuffer)
}

public enum PhysicalCameraLocation {
  case BackFacing
  case FrontFacing

  // Documentation: "The front-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeLeft and the back-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeRight."
  func imageOrientation() -> ImageOrientation {
    switch self {
    case .BackFacing: return .LandscapeRight
    case .FrontFacing: return .LandscapeLeft
    }
  }

  func captureDevicePosition() -> AVCaptureDevicePosition {
    switch self {
    case .BackFacing: return .Back
    case .FrontFacing: return .Front
    }
  }

  func device() -> AVCaptureDevice? {
    let devices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
    for device in devices {
      if (device.position == self.captureDevicePosition()) {
        return device as? AVCaptureDevice
      }
    }

    return AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
  }
}

struct CameraError: ErrorType {
}

let initialBenchmarkFramesToIgnore = 5

public class Camera: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
  public var location: PhysicalCameraLocation {
    didSet {
      // TODO: Swap the camera locations, framebuffers as needed
    }
  }
  public var runBenchmark: Bool = false
  public var logFPS: Bool = false
  public var audioEncodingTarget: AudioEncodingTarget? {
    didSet {
      guard let audioEncodingTarget = audioEncodingTarget else {
        self.removeAudioInputsAndOutputs()
        return
      }
      do {
        try self.addAudioInputsAndOutputs()
        audioEncodingTarget.activateAudioTrack()
      } catch {
        fatalError("ERROR: Could not connect audio target with error: \(error)")
      }
    }
  }

  public var metadataEncodingTarget: MetadataEncodingTarget? {
    didSet {
      captureSession.beginConfiguration()
      defer {
        captureSession.commitConfiguration()
      }

      guard let metadataEncodingTarget = metadataEncodingTarget else {
        removeMetaInputsAndOutputs()
        return
      }
      do {
        try self.addMetaInputsAndOutputs()
        metadataEncodingTarget.activateMetadataTrack()
      } catch {
        fatalError("ERROR: Could not connect audio target with error: \(error)")
      }
    }
  }

  public let targets = TargetContainer()
  public var delegate: CameraDelegate?
  let captureSession: AVCaptureSession
  let inputCamera: AVCaptureDevice!
  let videoInput: AVCaptureDeviceInput!
  let videoOutput: AVCaptureVideoDataOutput!
  var microphone: AVCaptureDevice?
  var audioInput: AVCaptureDeviceInput?
  var audioOutput: AVCaptureAudioDataOutput?

  var metadataOutput: AVCaptureMetadataOutput?

  var supportsFullYUVRange: Bool = false
  let captureAsYUV: Bool
  let yuvConversionShader: ShaderProgram?

  let frameRenderingSemaphore = dispatch_semaphore_create(1)
  let cameraProcessingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
  let audioProcessingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)
  let metadataProcessingQueue = dispatch_queue_create("com.GPUImage.metadata", DISPATCH_QUEUE_SERIAL)
  let framesToIgnore = 5
  var numberOfFramesCaptured = 0
  var totalFrameTimeDuringCapture: Double = 0.0
  var framesSinceLastCheck = 0
  var lastCheckTime = CFAbsoluteTimeGetCurrent()

  public init(sessionPreset: String, cameraDevice: AVCaptureDevice? = nil, location: PhysicalCameraLocation = .BackFacing, captureAsYUV: Bool = true) throws {

    self.location = location
    self.captureAsYUV = captureAsYUV

    self.captureSession = AVCaptureSession()
    self.captureSession.beginConfiguration()

    if let cameraDevice = cameraDevice {
      self.inputCamera = cameraDevice
    } else {
      if let device = location.device() {
        self.inputCamera = device
      } else {
        self.videoInput = nil
        self.videoOutput = nil
        self.yuvConversionShader = nil
        self.inputCamera = nil
        super.init()
        throw CameraError()
      }
    }

    do {
      self.videoInput = try AVCaptureDeviceInput(device: inputCamera)
    } catch {
      self.videoInput = nil
      self.videoOutput = nil
      self.yuvConversionShader = nil
      super.init()
      throw error
    }
    if (captureSession.canAddInput(videoInput)) {
      captureSession.addInput(videoInput)
    }

    // Add the video frame output
    videoOutput = AVCaptureVideoDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = false

    if captureAsYUV {
      supportsFullYUVRange = false
      let supportedPixelFormats = videoOutput.availableVideoCVPixelFormatTypes
      for currentPixelFormat in supportedPixelFormats {
        if ((currentPixelFormat as! NSNumber).intValue == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
          supportsFullYUVRange = true
        }
      }

      if (supportsFullYUVRange) {
        yuvConversionShader = crashOnShaderCompileFailure("Camera") {
          try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader: YUVConversionFullRangeFragmentShader)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: NSNumber(int: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
      } else {
        yuvConversionShader = crashOnShaderCompileFailure("Camera") {
          try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader: YUVConversionVideoRangeFragmentShader)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: NSNumber(int: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))]
      }
    } else {
      yuvConversionShader = nil
      videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: NSNumber(int: Int32(kCVPixelFormatType_32BGRA))]
    }

    if (captureSession.canAddOutput(videoOutput)) {
      captureSession.addOutput(videoOutput)
    }
    captureSession.sessionPreset = sessionPreset

    captureSession.commitConfiguration()

    super.init()

    videoOutput.setSampleBufferDelegate(self, queue: cameraProcessingQueue)
  }

  deinit {
    sharedImageProcessingContext.runOperationSynchronously {
      self.stopCapture()
      self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
      self.audioOutput?.setSampleBufferDelegate(nil, queue: nil)
      self.metadataOutput?.setMetadataObjectsDelegate(nil, queue: nil)
    }
  }

  public func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
    guard (captureOutput != audioOutput) else {
      self.processAudioSampleBuffer(sampleBuffer)
      return
    }

    guard (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) == 0) else {
      return
    }

    let startTime = CFAbsoluteTimeGetCurrent()

    let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
    let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
    let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
    let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    CVPixelBufferLockBaseAddress(cameraFrame, 0)
    sharedImageProcessingContext.runOperationAsynchronously {
      let cameraFramebuffer: Framebuffer

      self.delegate?.didCaptureBuffer(sampleBuffer)
      if self.captureAsYUV {
        let luminanceFramebuffer: Framebuffer
        let chrominanceFramebuffer: Framebuffer
        if sharedImageProcessingContext.supportsTextureCaches() {
          var luminanceTextureRef: CVOpenGLESTextureRef? = nil
          let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, cameraFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceTextureRef)
          let luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef!)
          glActiveTexture(GLenum(GL_TEXTURE4))
          glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
          glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
          glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
          luminanceFramebuffer = try! Framebuffer(context: sharedImageProcessingContext, orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true, overriddenTexture: luminanceTexture)

          var chrominanceTextureRef: CVOpenGLESTextureRef? = nil
          let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, cameraFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceTextureRef)
          let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef!)
          glActiveTexture(GLenum(GL_TEXTURE5))
          glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
          glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
          glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
          chrominanceFramebuffer = try! Framebuffer(context: sharedImageProcessingContext, orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth / 2), height: GLint(bufferHeight / 2)), textureOnly: true, overriddenTexture: chrominanceTexture)
        } else {
          glActiveTexture(GLenum(GL_TEXTURE4))
          luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true)
          luminanceFramebuffer.lock()

          glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
          glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 0))

          glActiveTexture(GLenum(GL_TEXTURE5))
          chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth / 2), height: GLint(bufferHeight / 2)), textureOnly: true)
          chrominanceFramebuffer.lock()
          glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
          glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 1))
        }

        cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: .Portrait, size: luminanceFramebuffer.sizeForTargetOrientation(.Portrait), textureOnly: false)

        let conversionMatrix: Matrix3x3
        if (self.supportsFullYUVRange) {
          conversionMatrix = colorConversionMatrix601FullRangeDefault
        } else {
          conversionMatrix = colorConversionMatrix601Default
        }
        convertYUVToRGB(shader: self.yuvConversionShader!, luminanceFramebuffer: luminanceFramebuffer, chrominanceFramebuffer: chrominanceFramebuffer, resultFramebuffer: cameraFramebuffer, colorConversionMatrix: conversionMatrix)
      } else {
        cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true)
        glBindTexture(GLenum(GL_TEXTURE_2D), cameraFramebuffer.texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(cameraFrame))
      }
      CVPixelBufferUnlockBaseAddress(cameraFrame, 0)

      cameraFramebuffer.timingStyle = .VideoFrame(timestamp: Timestamp(currentTime))
      self.updateTargetsWithFramebuffer(cameraFramebuffer)

      if self.runBenchmark {
        self.numberOfFramesCaptured += 1
        if (self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore) {
          let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
          self.totalFrameTimeDuringCapture += currentFrameTime
          print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms")
          print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
      }

      if self.logFPS {
        if ((CFAbsoluteTimeGetCurrent() - self.lastCheckTime) > 1.0) {
          self.lastCheckTime = CFAbsoluteTimeGetCurrent()
          print("FPS: \(self.framesSinceLastCheck)")
          self.framesSinceLastCheck = 0
        }

        self.framesSinceLastCheck += 1
      }

      dispatch_semaphore_signal(self.frameRenderingSemaphore)
    }
  }

  public func startCapture() {
    self.numberOfFramesCaptured = 0
    self.totalFrameTimeDuringCapture = 0

    if (!captureSession.running) {
      captureSession.startRunning()
    }
  }

  public func stopCapture() {
    if (captureSession.running) {
      captureSession.stopRunning()
    }
  }

  public func transmitPreviousImageToTarget(target: ImageConsumer, atIndex: UInt) {
    // Not needed for camera inputs
  }

  // MARK: -
  // MARK: Audio processing

  func addAudioInputsAndOutputs() throws {
    guard (audioOutput == nil) else {
      return
    }

    captureSession.beginConfiguration()
    defer {
      captureSession.commitConfiguration()
    }
    microphone = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeAudio)
    audioInput = try AVCaptureDeviceInput(device: microphone)
    if captureSession.canAddInput(audioInput) {
      captureSession.addInput(audioInput)
    }
    audioOutput = AVCaptureAudioDataOutput()
    if captureSession.canAddOutput(audioOutput) {
      captureSession.addOutput(audioOutput)
    }
    audioOutput?.setSampleBufferDelegate(self, queue: audioProcessingQueue)
  }

  func removeAudioInputsAndOutputs() {
    guard (audioOutput != nil) else {
      return
    }

    captureSession.beginConfiguration()
    captureSession.removeInput(audioInput!)
    captureSession.removeOutput(audioOutput!)
    audioInput = nil
    audioOutput = nil
    microphone = nil
    captureSession.commitConfiguration()
  }

  func processAudioSampleBuffer(sampleBuffer: CMSampleBuffer) {
    self.audioEncodingTarget?.processAudioBuffer(sampleBuffer)
  }

  // MARK: -
  // MARK: MetaData processing

  func addMetaInputsAndOutputs() throws {
    guard (metadataOutput == nil) else {
      return
    }

    configureMetadataStream()
  }

  func removeMetaInputsAndOutputs() {
    guard (metadataOutput != nil) else {
      return
    }

    captureSession.removeOutput(metadataOutput!)
    metadataOutput = nil
  }

  private func configureMetadataStream() {

    let metaOutput = createMetaDataOutput()
    if captureSession.canAddOutput(metaOutput) {
      captureSession.addOutput(metaOutput)
      filterMetadataIfNeeded()
    }
  }

  private func createMetaDataOutput() -> AVCaptureMetadataOutput {
    let metadataOutput = AVCaptureMetadataOutput()
    metadataOutput.setMetadataObjectsDelegate(self, queue: metadataProcessingQueue)
    self.metadataOutput = metadataOutput
    return metadataOutput
  }

  private func filterMetadataIfNeeded() {
    guard let metaOutput = metadataOutput, let requestedTypes = metadataEncodingTarget?.expectedMetaTypes else { return }

    let available = NSSet(array: metaOutput.availableMetadataObjectTypes)
    available.intersectsSet(requestedTypes)
    metaOutput.metadataObjectTypes = available.allObjects
  }

}

extension Camera: AVCaptureMetadataOutputObjectsDelegate {

  public func captureOutput(captureOutput: AVCaptureOutput!, didOutputMetadataObjects metadataObjects: [AnyObject]!, fromConnection connection: AVCaptureConnection!) {
    metadataEncodingTarget?.processMetaObjects(metadataObjects)
  }

}