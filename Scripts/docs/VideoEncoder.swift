// Re-encodes a screen recording as a compact, web-friendly H.264 MP4.
//
// avconvert presets use bitrates sized for camera footage, which makes a
// mostly-static screen recording far larger than it needs to be. This caps
// the width, frame rate and average bitrate instead.
//
// usage: video-encoder <source.mov> <output.mp4> [max-width] [bits-per-second] [fps]

import AVFoundation
import Foundation

nonisolated(unsafe) var workFolder: URL?

func fail(_ message: String) -> Never {
    if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
    FileHandle.standardError.write(Data("video-encoder: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: video-encoder <source.mov> <output.mp4> [max-width] [bits-per-second] [fps]")
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let maxWidth = arguments.count > 3 ? Int(arguments[3]) ?? 1440 : 1440
let bitRate = arguments.count > 4 ? Int(arguments[4]) ?? 1_000_000 : 1_000_000
let framesPerSecond = arguments.count > 5 ? Double(arguments[5]) ?? 30 : 30

let asset = AVURLAsset(url: source)
guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    fail("\(source.path) has no video track")
}
let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
let displaySize = naturalSize.applying(transform)
let sourceWidth = abs(displaySize.width)
let sourceHeight = abs(displaySize.height)
let scale = min(1, Double(maxWidth) / sourceWidth)
func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
let width = even(sourceWidth * scale)
let height = even(sourceHeight * scale)

let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
readerOutput.alwaysCopiesSampleData = false
guard reader.canAdd(readerOutput) else { fail("cannot read \(source.path)") }
reader.add(readerOutput)

// Network optimization leaves the pre-optimization file beside its output (`*.sb-*`), so
// encode in a private folder and move only the finished MP4 into place.
let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: output, create: true)
workFolder = folder
defer { try? FileManager.default.removeItem(at: folder) }
let encoded = folder.appendingPathComponent(output.lastPathComponent)
let writer = try AVAssetWriter(outputURL: encoded, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitRate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: framesPerSecond,
        AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond * 4),
        AVVideoAllowFrameReorderingKey: true,
    ],
])
writerInput.transform = transform
writerInput.expectsMediaDataInRealTime = false
guard writer.canAdd(writerInput) else { fail("cannot write \(output.path)") }
writer.add(writerInput)

guard reader.startReading() else { fail("reading failed: \(reader.error?.localizedDescription ?? "unknown error")") }
guard writer.startWriting() else { fail("writing failed: \(writer.error?.localizedDescription ?? "unknown error")") }
writer.startSession(atSourceTime: .zero)

let frameInterval = 1 / framesPerSecond
let queue = DispatchQueue(label: "video-encoder")
nonisolated(unsafe) var nextFrameTime = 0.0
nonisolated(unsafe) var firstTime: CMTime?
nonisolated(unsafe) var lastTime: CMTime?

await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
    writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished()
                finished.resume()
                return
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentation.isValid, CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let start = firstTime ?? presentation
            firstTime = start
            let time = CMTimeSubtract(presentation, start)
            // Drop frames above the target rate; screen recordings are often 60 fps.
            guard time.seconds + 0.0001 >= nextFrameTime else { continue }
            nextFrameTime = time.seconds + frameInterval
            guard let retimed = try? CMSampleBuffer(copying: sample, withNewTiming: [
                CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid),
            ]) else { continue }
            if !writerInput.append(retimed) {
                fail("encoding failed: \(writer.error?.localizedDescription ?? "unknown error")")
            }
            lastTime = time
        }
    }
}

if reader.status == .failed {
    fail("reading failed: \(reader.error?.localizedDescription ?? "unknown error")")
}
let end = lastTime.map { CMTimeAdd($0, CMTime(seconds: frameInterval, preferredTimescale: 600)) } ?? .zero
writer.endSession(atSourceTime: end)
await writer.finishWriting()
guard writer.status == .completed else {
    fail("encoding failed: \(writer.error?.localizedDescription ?? "unknown error")")
}
try? FileManager.default.removeItem(at: output)
try FileManager.default.moveItem(at: encoded, to: output)
print("\(width)x\(height) @ \(Int(framesPerSecond)) fps, \(bitRate / 1000) kbps")
