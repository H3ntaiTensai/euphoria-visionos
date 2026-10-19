// Transcode one of the game's MPEG-1 movies to H.264/AAC MP4 with AVFoundation.
//
// Apple's MPEG-1 decoder stalls partway through several of these files when one
// reader decodes them start to finish (avconvert hangs on them too). Reading in
// short time ranges with a fresh reader each time avoids the stall. Each range
// feeds the writer until both tracks end or the writer stops taking samples
// (it waits to interleave the tracks); the next range then resumes from the
// earlier track's last sample, and samples already written are skipped.
//
// Usage: swiftc -O tools/transcode_movie.swift -o .build/transcode_movie
//        .build/transcode_movie input.mpg output.mp4
import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: transcode_movie input.mpg output.mp4\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)

func transcode() async throws -> Double {
    let asset = AVURLAsset(url: input)
    let duration = try await asset.load(.duration)
    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
    let audio = try await asset.loadTracks(withMediaType: .audio).first
    let size = try await video.load(.naturalSize)

    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
    ])
    videoInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)
    var audioInput: AVAssetWriterInput?
    if audio != nil {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        audioInput = input
    }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let chunk = CMTime(seconds: 4, preferredTimescale: 600)
    var start = CMTime.zero
    var lastVideo = CMTime.invalid
    var lastAudio = CMTime.invalid
    var videoEnded = false
    var audioEnded = audio == nil

    while !(videoEnded && audioEnded) {
        let end = min(start + chunk, duration)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: end)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audio {
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2])
            reader.add(out)
            audioOut = out
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var videoDone = false
        var audioDone = audioOut == nil
        var idle = 0
        while !(videoDone && audioDone), idle < 50 {
            var fed = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sample = videoOut.copyNextSampleBuffer() {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !lastVideo.isValid || time > lastVideo {
                        videoInput.append(sample)
                        lastVideo = time
                    }
                } else {
                    videoDone = true
                }
                fed = true
            }
            if !audioDone, let audioOut, let audioInput, audioInput.isReadyForMoreMediaData {
                if let sample = audioOut.copyNextSampleBuffer() {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !lastAudio.isValid || time > lastAudio {
                        audioInput.append(sample)
                        lastAudio = time
                    }
                } else {
                    audioDone = true
                }
                fed = true
            }
            if fed {
                idle = 0
            } else {
                // The writer is waiting for the other track (already ended in this range).
                idle += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        reader.cancelReading()
        if end >= duration {
            // Last range: a track that finished here has ended for good.
            if videoDone { videoEnded = true }
            if audioDone { audioEnded = true }
        }
        // Resume from the track that is furthest behind; already-written samples are skipped.
        let behind = [videoEnded ? nil : lastVideo, audioEnded ? nil : lastAudio]
            .compactMap { $0 }.filter(\.isValid).min() ?? end
        start = max(behind, start + CMTime(seconds: 0.05, preferredTimescale: 600))
        if start >= duration, !(videoEnded && audioEnded) {
            // Nothing left to read for the remaining track.
            break
        }
    }
    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return duration.seconds
}

let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var outcome: Result<Double, Error>?
Task.detached {
    do { outcome = .success(try await transcode()) } catch { outcome = .failure(error) }
    done.signal()
}
done.wait()
switch outcome {
case .success(let duration):
    print("wrote \(output.lastPathComponent) (\(String(format: "%.1f", duration))s)")
case .failure(let error):
    FileHandle.standardError.write("transcode failed: \(error)\n".data(using: .utf8)!)
    exit(1)
case nil:
    exit(1)
}
