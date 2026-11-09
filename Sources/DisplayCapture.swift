import AppKit
import CoreMedia
import ScreenCaptureKit

@MainActor
final class DisplayCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    var onFrame: ((CVPixelBuffer, CGRect) -> Void)?
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var request: Task<Void, Never>?
    private var displayID: CGDirectDisplayID?
    private var displayFrame = CGRect.zero

    func capture(_ screen: NSScreen) {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return
        }
        guard displayID != id || displayFrame != screen.frame else { return }

        stop()
        displayID = id
        displayFrame = screen.frame
        request = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                try await self?.start(content: content, displayID: id)
            } catch {
                if !Task.isCancelled { self?.fail(error) }
            }
        }
    }

    private func start(content: SCShareableContent, displayID: CGDirectDisplayID) async throws {
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw LoupeError("无法找到当前显示器，或无法从采集中排除 macOS Loupe。")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        self.stream = stream
        try await stream.startCapture()
        // A stop requested before start finished may have raced with the asynchronous start.
        if Task.isCancelled {
            try? await stream.stopCapture()
        }
    }

    func stop() {
        request?.cancel()
        request = nil
        displayID = nil
        let previous = stream
        stream = nil
        if let previous {
            Task { try? await previous.stopCapture() }
        }
    }

    private func fail(_ error: Error) {
        stop()
        onFailure?(error)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.fail(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // Screen samples are explicitly delivered on the main queue.
        MainActor.assumeIsolated {
            guard self.stream === stream, type == .screen,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let buffer = sampleBuffer.imageBuffer else { return }
            onFrame?(buffer, displayFrame)
        }
    }
}
