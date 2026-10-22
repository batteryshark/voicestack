import XCTest
import AVFoundation
@testable import FloatingVoiceCore

@MainActor final class HoldPlaybackTests: XCTestCase {
    func testPCM16LittleEndianContractAndMalformedFrames() throws {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!
        let buffer=try PCMPlaybackBuffer.make(Data([0,128,255,127,0,0,0,192,0,64]),format:format)
        XCTAssertEqual(Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:5)),[-1,32767.0/32768,0,-0.5,0.5])
        XCTAssertThrowsError(try PCMPlaybackBuffer.make(Data([0]),format:format))
    }
    func testInstalledAndNormalizedMusicThroughSpeakerAndNativePCMConversionOffline() async throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let evidence = root.appendingPathComponent("output/call-comfort-build43-offline")
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        for (name,path) in [("installed42","output/call-comfort-build42/FloatingVoice.xcarchive/Products/Applications/FloatingVoice.app/HoldMusic.pcm"),("normalized43","native/HoldMusic.pcm")] {
            if name == "installed42" && !FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path) { continue }
            let pcm = try Data(contentsOf:root.appendingPathComponent(path))
            XCTAssertEqual(pcm.count,1_440_000)
            let output = OfflineMusicOutput(), speaker = Speaker(synth:HoldTestSynth(),output:output,onError:{ XCTFail("\($0)") })
            speaker.enqueueHold(HoldTestTicket(pcm))
            let done = await waitUntil { !output.rendered.isEmpty && !speaker.active }; XCTAssertTrue(done)
            XCTAssertEqual(output.rendered.count,pcm.count)
            let source = try PCMPlaybackBuffer.make(pcm,format:output.format)
            let rendered = try PCMPlaybackBuffer.make(output.rendered,format:output.format)
            var peak:Float = 0, power:Double = 0, maxError:Float = 0
            for i in 0..<Int(source.frameLength) {
                let x = rendered.floatChannelData![0][i]
                XCTAssertTrue(x.isFinite); peak = max(peak,abs(x)); power += Double(x*x)
                maxError = max(maxError,abs(x-source.floatChannelData![0][i]))
            }
            XCTAssertLessThanOrEqual(maxError,1.0/32768); XCTAssertLessThan(peak,0.5); XCTAssertGreaterThan(power,1)
            try WAV.encode(output.rendered,sampleRate:24000).write(to:evidence.appendingPathComponent(name+"-rendered.wav"))
            let stats:[String:Any] = ["sampleRate":24000,"channels":1,"frames":source.frameLength,"peak":peak,"rms":sqrt(power/Double(source.frameLength)),"maximumConversionError":maxError,"offline":true]
            try JSONSerialization.data(withJSONObject:stats,options:.prettyPrinted).write(to:evidence.appendingPathComponent(name+"-stats.json"))
        }
    }
    func testReplyEnqueueToggleIdleEndAndLateNaturalCompletionCannotRestartHold() async throws {
        let output = HeldMusicOutput(), speaker = Speaker(synth:HoldTestSynth(),output:output,onError:{ XCTFail("\($0)") })
        var starts = 0, projectedActive = true
        var music: ProcessingHoldMusic!
        music = ProcessingHoldMusic(delay:10_000_000,start:{
            starts += 1
            let token = music.playbackGeneration
            speaker.enqueueHold(HoldTestTicket(Data([1,0])),completion:{ music.clipEnded($0,generation:token) })
        },stop:{ speaker.stopHold() })
        speaker.onReplyEnqueue = { music.replyStarted() }
        // Reproduce the native status projection callback during stop; no reentrant rearm.
        speaker.onChange = { music.processing(projectedActive) }
        music.processing(true)
        let began = await waitUntil { speaker.isHolding && speaker.playing }; XCTAssertTrue(began)
        let old = music.playbackGeneration
        speaker.enqueue("Reply",label:"chief")
        let reply = await waitUntil { output.labels.contains("chief") }; XCTAssertTrue(reply)
        music.processing(true); music.clipEnded(true,generation:old)
        try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,1); XCTAssertFalse(speaker.isHolding)
        speaker.stop(); projectedActive = false; music.processing(false)
        for stop in [0,1,2] {
            projectedActive = true; music.enabled = true; music.processing(true)
            let active = await waitUntil { speaker.isHolding && speaker.playing }; XCTAssertTrue(active)
            let token = music.playbackGeneration, count = starts
            if stop == 0 { music.enabled = false } else if stop == 1 { projectedActive = false; music.processing(false) } else { projectedActive = false; music.end() }
            music.clipEnded(true,generation:token)
            try await Task.sleep(nanoseconds:30_000_000)
            XCTAssertEqual(starts,count); XCTAssertFalse(speaker.isHolding); XCTAssertFalse(speaker.playing)
        }
        music.end(); speaker.stop()
    }
}

private final class HoldTestTicket: SpeechTicket {
    let text = "fixture"; let pcm:Data
    init(_ pcm:Data) { self.pcm = pcm }
    func audio() async throws -> SpeechAudio { .whole(pcm,sampleRate:24000) }
    func cancel() {}
}
private final class HoldTestSynth: SpeechSynthesizer {
    func prepare(_ text:String) -> SpeechTicket { HoldTestTicket(Data([1,0])) }
}
@MainActor private final class HeldMusicOutput: AudioOutput {
    var labels:[String] = []
    private var waiter:CheckedContinuation<Void,Never>?
    func play(_ audio:SpeechAudio,label:String,onStart:@escaping ()->Void) async throws {
        labels.append(label); onStart(); await withCheckedContinuation { waiter = $0 }
    }
    func stopPlayback() { let pending=waiter;waiter=nil;pending?.resume() }
}
@MainActor private final class OfflineMusicOutput: AudioOutput {
    let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!
    var rendered = Data()
    func play(_ audio:SpeechAudio,label:String,onStart:@escaping ()->Void) async throws {
        XCTAssertEqual(audio.sampleRate,24000)
        let engine=AVAudioEngine(), player=AVAudioPlayerNode();engine.attach(player)
        engine.connect(player,to:engine.mainMixerNode,format:format)
        // No hardware output: explicit offline manual rendering before starting the engine.
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        defer { engine.stop() }
        var frames = 0
        for try await chunk in audio.chunks {
            var carry = chunk
            while !carry.isEmpty {
                let count = PlaybackBufferScheduler.frameCount(bytes:carry.count,sampleRate:audio.sampleRate)
                let part=Data(carry.prefix(count*2));carry.removeFirst(count*2)
                player.scheduleBuffer(try PCMPlaybackBuffer.make(part,format:format),completionHandler:nil)
                frames += count
            }
        }
        try engine.start();player.play();onStart()
        let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
        var remaining=frames, attempts=0
        while remaining>0 && attempts<1000 {
            attempts += 1
            let count=AVAudioFrameCount(min(remaining,4096))
            guard try engine.renderOffline(count,to:output) == .success else { continue }
            for i in 0..<Int(output.frameLength) {
                var sample=Int16(clamping:Int((output.floatChannelData![0][i]*32768).rounded())).littleEndian
                withUnsafeBytes(of:&sample) { rendered.append(contentsOf:$0) }
            }
            remaining -= Int(output.frameLength)
        }
        XCTAssertEqual(remaining,0)
    }
    func stopPlayback() {}
}
