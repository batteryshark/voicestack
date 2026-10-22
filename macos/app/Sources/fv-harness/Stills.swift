import Foundation
import SwiftUI
import AppKit
import CoreImage
import FloatingVoiceCore
import FloatingVoiceUI

// Still images and animation frames of the pill, drawn with SwiftUI's ImageRenderer from the same views, view model
// and motion the app uses. No window is created and nothing is put on screen. The app's glass is the system's
// behind-window blur, which ImageRenderer cannot draw, so the pill is composed on a macOS wallpaper with that blur
// simulated (Gaussian blur and a saturation lift of the same wallpaper under the pill) and a drop shadow like the
// panel's.

// MARK: Scene

/// A desktop: a system wallpaper laid out like a 1512 × 982 pt screen, and its blurred copy for the glass.
@MainActor
struct Scene {
    let sharp: CGImage
    let blurred: CGImage
    /// Scene size in points (images are 2x).
    let size: CGSize

    static let screen = CGSize(width: 1512, height: 982)

    /// The region of the screen (points, top-left origin) that the scene covers.
    static func make(wallpaper: String, region: CGRect, blur: Double = 26, saturation: Double = 1.55) -> Scene {
        let scale = 2.0
        let px = CGSize(width: region.width * scale, height: region.height * scale)
        let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let path = "/System/Library/Desktop Pictures/\(wallpaper).heic"
        if let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Aspect-fill the screen, then take the region (CG's origin is bottom-left).
            let w = Double(cg.width), h = Double(cg.height)
            let fill = max(screen.width / w, screen.height / h)
            let drawn = CGSize(width: w * fill * scale, height: h * fill * scale)
            let ox = -(drawn.width - screen.width * scale) / 2 - region.minX * scale
            let oyTop = -(drawn.height - screen.height * scale) / 2 - region.minY * scale
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: ox, y: px.height - oyTop - drawn.height, width: drawn.width, height: drawn.height))
        } else {
            let colors = [CGColor(red: 0.30, green: 0.36, blue: 0.62, alpha: 1), CGColor(red: 0.86, green: 0.50, blue: 0.48, alpha: 1)]
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: px.width, y: px.height), options: [])
        }
        let sharp = ctx.makeImage()!
        let ci = CIImage(cgImage: sharp)
        let out = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .cropped(to: ci.extent)
        let blurred = CIContext().createCGImage(out, from: ci.extent)!
        return Scene(sharp: sharp, blurred: blurred, size: region.size)
    }

    var sharpImage: NSImage { NSImage(cgImage: sharp, size: size) }
    var blurredImage: NSImage { NSImage(cgImage: blurred, size: size) }
}

/// The pill at `origin` on the scene, with the panel's shadow.
@MainActor
func composed(_ pill: PillModel, settings: SettingsState, motion: PillMotion, theme: PillTheme, scene: Scene, origin: CGPoint) -> some View {
    let size = motion.size
    let radius = min(PillLayout.radius, size.height / 2)
    return ZStack(alignment: .topLeading) {
        Image(nsImage: scene.sharpImage).resizable().frame(width: scene.size.width, height: scene.size.height)
        ZStack(alignment: .topLeading) {
            // The panel's shadow (macOS draws one from the window's shape).
            RoundedRectangle(cornerRadius: radius, style: .circular)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(theme.name == .graphite ? 0.34 : 0.22), radius: 16, y: 9)
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
            PillRootView(model: pill, settings: settings, motion: motion, actions: PillActions())
                .frame(width: size.width, height: size.height)
                .environment(\.pillTheme, theme)
                .environment(\.pillBackdrop, PillBackdrop(image: scene.blurredImage, origin: origin))
        }
        .offset(x: origin.x, y: origin.y)
    }
    .frame(width: scene.size.width, height: scene.size.height, alignment: .topLeading)
}

@MainActor
func writePNG<V: View>(_ view: V, to path: String, scale: CGFloat = 2) -> Bool {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { print("could not render \(path)"); return false }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("could not write \(path): \(error)"); return false }
    return true
}

// MARK: States

@MainActor
private func makeState(_ configure: (PillModel, inout ConversationController.Status, (Double) -> Void) -> Void) -> PillModel {
    var clock = 1_000_000.0
    let pill = PillModel(now: { clock })
    var status = ConversationController.Status()
    status.running = true
    status.phase = "ready"
    status.connection = "connected"
    status.target = "ses_SYNTHETIC0022"
    status.targetTitle = "Chief of staff"
    pill.update(status: status)
    configure(pill, &status, { clock += $0 })
    status.pendingSpeech = status.hearing || status.holding != nil
    pill.update(status: status)
    return pill
}

/// Feed a level curve through the visualizer (mic or playback), one tick per value.
@MainActor
private func feedLevels(_ pill: PillModel, chief: Bool, _ advance: (Double) -> Void) {
    let curve: [Double] = [0.01, 0.03, 0.08, 0.05, 0.12, 0.2, 0.09, 0.15, 0.06, 0.18, 0.11, 0.04, 0.14, 0.07, 0.1]
    for v in curve {
        pill.handle(chief ? .outputLevel(v) : .micLevel(v))
        advance(50)
        pill.tick()
    }
}

@MainActor
private func roomNoise(_ pill: PillModel, _ advance: (Double) -> Void) {
    for v in [0.004, 0.006, 0.005, 0.008, 0.006, 0.005, 0.007, 0.006, 0.009, 0.006, 0.005, 0.007, 0.006, 0.008, 0.006] {
        pill.handle(.micLevel(v)); advance(50); pill.tick()
    }
}

@MainActor
func sampleSettings() -> SettingsState {
    let s = SettingsState()
    s.voices = [.init(id: "female_a", label: "Original (female_a)"), .init(id: "mizuki", label: "Mizuki"), .init(id: "ganyu", label: "Ganyu")]
    s.serverDefaultVoice = "mizuki"
    s.inputs = [.init(id: "nexigo", label: "NexiGo N960E Pro Webcam Audio"), .init(id: "builtin", label: "MacBook Pro Microphone")]
    s.outputs = [.init(id: "88-C9-E8-15-D0-18:output", label: "WH-1000XM5"), .init(id: "speakers", label: "MacBook Pro Speakers")]
    s.voice = "default"
    s.inputDevice = "nexigo"
    s.outputDevice = "88-C9-E8-15-D0-18:output"
    s.echoCancellation = "auto"
    s.pauseMs = 3200
    s.busyDelivery = .queue
    s.target = "chief"
    s.chiefSource = "chief.json"
    s.sessions = [.init(id: "ses_SYNTHETIC0022", label: "Chief of staff · SYNTHE"), .init(id: "ses_SYNTHETIC0018", label: "Pill behaviour · SYNTHE"),
                  .init(id: "ses_SYNTHETIC0025", label: "Synthetic sample project · SYNTHE")]
    s.running = true
    s.appFile = "~/.config/floating-voice/settings.json"
    return s
}

@MainActor
func stillStates() -> [(String, PillModel)] {
    [
        ("sender-voice-ended", makeState { pill, _, _ in
            let text = VoiceEnd.text
            pill.handle(.inbound(sender: SenderAttribution.classify(text: text), text: text))
        }),
        ("sender-lead-held", makeState { pill, status, _ in
            status.holding = "Keep my own held words exactly as they are."
            status.manualSend = true
            pill.handle(.youFinal("Keep my own held words exactly as they are."))
            let text = "From the Dream Studio lead: Offline review is ready."
            pill.handle(.inbound(sender: SenderAttribution.classify(text: text), text: text))
        }),
        ("sender-docket", makeState { pill, _, _ in
            let text = "Docket timer fired: Review the deadline."
            pill.handle(.inbound(sender: SenderAttribution.classify(text: text), text: text))
        }),
        ("sender-canvas", makeState { pill, _, _ in
            let text = "[Agent Canvas] Selected: review first."
            pill.handle(.inbound(sender: SenderAttribution.classify(text: text), text: text))
        }),
        ("01-resting-voice-off", makeState { pill, status, _ in
            status = ConversationController.Status()
            pill.update(status: status)
        }),
        ("02-resting-listening", makeState { pill, status, advance in
            feedLevels(pill, chief: false, advance)
        }),
        ("03-resting-quiet", makeState { pill, status, advance in
            roomNoise(pill, advance)
        }),
        ("04-resting-muted", makeState { pill, status, advance in
            status.micMuted = true
            status.outputMuted = true
            pill.update(status: status)
            pill.tick()
        }),
        ("05-card-you-live-words", makeState { pill, status, advance in
            status.hearing = true
            pill.update(status: status)
            pill.handle(.youSpeaking)
            for p in ["check on", "check on dream studio", "check on dream studio and tell", "check on dream studio and tell me if the", "check on dream studio and tell me if the PC test"] {
                pill.handle(.youLive(p))
            }
            feedLevels(pill, chief: false, advance)
        }),
        ("06-card-chief-speaking", makeState { pill, status, advance in
            pill.handle(.youFinal("Check on Dream Studio and tell me if the PC test passed."))
            pill.handle(.posted("Check on Dream Studio and tell me if the PC test passed."))
            status.speaking = true
            status.busy = true
            pill.update(status: status)
            pill.handle(.chiefQueued(label: "m:0", text: "Dream Studio's PC test passed."))
            pill.handle(.chiefQueued(label: "m:0", text: "The English patch is live."))
            pill.handle(.chiefStarted(label: "m:0", text: "Dream Studio's PC test passed."))
            pill.handle(.chiefEnded(label: "m:0", text: "Dream Studio's PC test passed.", outcome: "played"))
            pill.handle(.chiefStarted(label: "m:0", text: "The English patch is live."))
            feedLevels(pill, chief: true, advance)
        }),
        ("07-card-chief-long-sentence", makeState { pill, status, advance in
            pill.handle(.youFinal("What's left on the release?"))
            pill.handle(.posted("What's left on the release?"))
            status.speaking = true
            pill.update(status: status)
            let s1 = "Three things are left before the release."
            let s2 = "The installer still needs notarizing, the changelog is missing two entries from Tuesday's merge, and the Windows build has one flaky test that fails about one run in five, which I'd like to look at first."
            pill.handle(.chiefStarted(label: "m:1", text: s1))
            pill.handle(.chiefEnded(label: "m:1", text: s1, outcome: "played"))
            pill.handle(.chiefStarted(label: "m:1", text: s2))
            feedLevels(pill, chief: true, advance)
        }),
        ("08-card-holding", makeState { pill, status, advance in
            pill.handle(.youFinal("Although I don't see the mock-up that we wanted with"))
            status.holding = "Although I don't see the mock-up that we wanted with"
            status.busy = true
            pill.update(status: status)
            pill.handle(.youLive("all of the"))
            pill.handle(.youLive("all of the different voice"))
            status.hearing = true
            pill.update(status: status)
            feedLevels(pill, chief: false, advance)
        }),
        ("09-card-manual-send", makeState { pill, status, advance in
            status.manualSend = true
            pill.update(status: status)
            pill.handle(.youFinal("First check the build logs for the failing test."))
            status.holding = "First check the build logs for the failing test."
            pill.update(status: status)
            pill.handle(.youLive("then tell me"))
            pill.handle(.youLive("then tell me whether the cache"))
            status.hearing = true
            pill.update(status: status)
            feedLevels(pill, chief: false, advance)
        }),
        ("10-resting-error", makeState { pill, status, _ in
            status = ConversationController.Status()
            status.lastError = SpeechServiceError.notRunning("ws://127.0.0.1:8446/v1/transcribe")
            pill.update(status: status)
        }),
        ("11-card-error-details", makeState { pill, status, advance in
            status.lastError = SpeechServiceError.notRunning("http://127.0.0.1:8444/v1/audio/speech")
            pill.update(status: status)
            pill.handle(.youFinal("Please check the build."))
            pill.errorDetailsOpen = true
            feedLevels(pill, chief: false, advance)
        }),
        ("12-card-discarded", makeState { pill, status, _ in
            pill.update(status: status)
            pill.handle(.discarded(""))
        }),
        ("18-card-capture-before-words", makeState { pill, status, _ in
            status.hearing = true
            pill.update(status: status)
            pill.handle(.youStarted)
        }),
        ("19-card-awaiting-final-muted", makeState { pill, status, _ in
            status.hearing = true; status.micMuted = true
            pill.update(status: status)
            pill.handle(.youLive("Please check the build"))
        }),
        ("20-card-fresh-after-discard", makeState { pill, status, _ in
            pill.handle(.discarded(""))
            status.hearing = true
            pill.update(status: status)
            pill.handle(.youStarted)
            pill.handle(.youLive("A fresh thought"))
        }),
        ("13-settings", makeState { pill, _, _ in
            pill.settingsOpen = true
        }),
        ("14-card-sending-in-3", makeState { pill, status, advance in
            status.hearing = true
            pill.update(status: status)
            pill.handle(.youSpeaking)
            for p in ["Can you check on the build and tell me", "Can you check on the build and tell me whether the cache was cleared"] { pill.handle(.youLive(p)) }
            feedLevels(pill, chief: false, advance)
            pill.handle(.youFinal("Can you check on the build and tell me whether the cache was cleared"))
            // 500 ms into the silence of a 3.2 s pause, then 0.7 s on: 3 s left of the 3.2 s.
            pill.handle(.countdown(totalMs: 3200, elapsedMs: 500, hold: false))
            advance(700)
            pill.tick()
        }),
        ("15-card-sent", makeState { pill, status, advance in
            pill.handle(.youFinal("Can you check on the build and tell me whether the cache was cleared."))
            pill.handle(.posted("Can you check on the build and tell me whether the cache was cleared."))
            status.busy = true
            pill.update(status: status)
            advance(300)
            pill.tick()
        }),
        ("17-card-noisy-room", makeState { pill, status, advance in
            status.hearing = true
            pill.update(status: status)
            pill.handle(.youSpeaking)
            pill.handle(.youLive("so I was thinking about the build and"))
            feedLevels(pill, chief: false, advance)
            pill.handle(.noisy(true))
        }),
        ("16-card-chief-thinking", makeState { pill, status, advance in
            pill.handle(.youFinal("Can you check on the build and tell me whether the cache was cleared."))
            pill.handle(.posted("Can you check on the build and tell me whether the cache was cleared."))
            status.busy = true
            pill.update(status: status)
            for _ in 0..<40 { advance(50); pill.tick() }
        }),
    ]
}

/// Where on the screen the pill sits in the stills: upper right, as the app first places it.
let stillsRegion = CGRect(x: 1000, y: 230, width: 440, height: 720)

@MainActor
func renderStills(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let settings = sampleSettings()
    let scene = Scene.make(wallpaper: "Sonoma", region: stillsRegion)
    let margin: CGFloat = 40
    for theme in [PillTheme.graphite, PillTheme.frost] {
        let letter = theme.name == .graphite ? "A" : "B"
        let sub = dir + "/\(letter)-\(theme.name.rawValue)"
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for (name, pill) in stillStates() {
            let motion = PillMotion()
            motion.snap(pill)
            let size = motion.size
            let origin = CGPoint(x: margin, y: margin)
            // Crop the scene to the pill plus its margin.
            let crop = CGRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
            let view = composed(pill, settings: settings, motion: motion, theme: theme, scene: scene, origin: origin)
                .frame(width: crop.width, height: crop.height, alignment: .topLeading)
                .clipped()
            let path = sub + "/\(name).png"
            guard writePNG(view, to: path) else { return 1 }
            print("\(path)  \(Int(size.width))x\(Int(size.height)) pt  expanded=\(pill.expanded) you=\"\(pill.you.final)|\(pill.you.tail)\" chief=\"\(pill.chief.earlier)|\(pill.chief.current)\" voice=\(pill.voice.rawValue)")
        }
    }
    return renderContexts(to: dir)
}

/// The card in both themes on a vivid, a light and a busy wallpaper, side by side.
@MainActor
func renderContexts(to dir: String) -> Int32 {
    let settings = sampleSettings()
    let states = stillStates()
    let card = states.first { $0.0 == "06-card-chief-speaking" }!.1
    let resting = states.first { $0.0 == "02-resting-listening" }!.1
    var tiles: [AnyView] = []
    for wallpaper in ["Sonoma", "iMac Silver", "Mac Blue"] {
        let scene = Scene.make(wallpaper: wallpaper, region: CGRect(x: 980, y: 90, width: 440, height: 360))
        for theme in [PillTheme.graphite, PillTheme.frost] {
            let mc = PillMotion(); mc.snap(card)
            let mr = PillMotion(); mr.snap(resting)
            tiles.append(AnyView(ZStack(alignment: .topLeading) {
                composed(card, settings: settings, motion: mc, theme: theme, scene: scene, origin: CGPoint(x: 40, y: 30))
                // The resting pill below it, drawn on the same scene.
                PillRootView(model: resting, settings: settings, motion: mr, actions: PillActions())
                    .frame(width: mr.size.width, height: mr.size.height)
                    .environment(\.pillTheme, theme)
                    .environment(\.pillBackdrop, PillBackdrop(image: scene.blurredImage, origin: CGPoint(x: 40, y: 30 + mc.size.height + 22)))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                    .offset(x: 40, y: 30 + mc.size.height + 22)
                Text("\(theme.name == .graphite ? "A · Graphite" : "B · Frost")  on  \(wallpaper)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.black.opacity(0.45)))
                    .offset(x: 236, y: 30 + mc.size.height + 34)
            }.frame(width: 440, height: 360, alignment: .topLeading).clipped()))
        }
    }
    let grid = VStack(spacing: 0) {
        ForEach(0..<3, id: \.self) { r in HStack(spacing: 0) { tiles[r * 2]; tiles[r * 2 + 1] } }
    }
    let path = dir + "/contexts-both-directions.png"
    guard writePNG(grid, to: path) else { return 1 }
    print(path)
    return 0
}

/// The settings panel and the assistant-speaking card, in both looks, for a quick look at the fixed "Agent" label.
/// Same views and motion as the app; nothing is put on screen.
@MainActor
func renderNameStills(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let settings = sampleSettings()
    let scene = Scene.make(wallpaper: "Sonoma", region: stillsRegion)
    let margin: CGFloat = 40
    let wanted: Set<String> = ["13-settings", "06-card-chief-speaking"]
    for theme in [PillTheme.graphite, PillTheme.frost] {
        let letter = theme.name == .graphite ? "A" : "B"
        let sub = dir + "/\(letter)-\(theme.name.rawValue)"
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for (stateName, pill) in stillStates() where wanted.contains(stateName) {
            let motion = PillMotion()
            motion.snap(pill)
            let size = motion.size
            let origin = CGPoint(x: margin, y: margin)
            let crop = CGRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
            let view = composed(pill, settings: settings, motion: motion, theme: theme, scene: scene, origin: origin)
                .frame(width: crop.width, height: crop.height, alignment: .topLeading)
                .clipped()
            let path = sub + "/\(stateName).png"
            guard writePNG(view, to: path) else { return 1 }
            print("\(path)  label=\"\(pill.assistantLabel)\"")
        }
    }
    return 0
}

/// The two error states (resting and the card's details), both looks: the plain wording when a speech service is not
/// running. Same views and motion as the app; nothing is put on screen.
@MainActor
func renderErrorStills(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let settings = sampleSettings()
    let scene = Scene.make(wallpaper: "Sonoma", region: stillsRegion)
    let margin: CGFloat = 40
    let wanted: Set<String> = ["10-resting-error", "11-card-error-details"]
    for theme in [PillTheme.graphite, PillTheme.frost] {
        let letter = theme.name == .graphite ? "A" : "B"
        let sub = dir + "/\(letter)-\(theme.name.rawValue)"
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for (stateName, pill) in stillStates() where wanted.contains(stateName) {
            let motion = PillMotion()
            motion.snap(pill)
            let size = motion.size
            let origin = CGPoint(x: margin, y: margin)
            let crop = CGRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
            let view = composed(pill, settings: settings, motion: motion, theme: theme, scene: scene, origin: origin)
                .frame(width: crop.width, height: crop.height, alignment: .topLeading)
                .clipped()
            let path = sub + "/\(stateName).png"
            guard writePNG(view, to: path) else { return 1 }
            print("\(path)  error=\"\(pill.errorText ?? "")\"")
        }
    }
    return 0
}

/// Local private status and pending state, production views; no window/audio/backend.
@MainActor func renderCutInStills(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let settings = sampleSettings()
    let scene = Scene.make(wallpaper: "Sonoma", region: stillsRegion)
    for theme in [PillTheme.graphite, PillTheme.frost] {
        for pending in [true, false] {
            let pill = PillModel()
            var status = ConversationController.Status()
            status.running = true; status.connection = "connected"; status.phase = "ready"
            status.pendingSpeech = pending; status.hearing = pending; status.speaking = true
            status.notice = pending ? nil : PrivateVoiceNotice.didntCatchThat.rawValue
            pill.update(status: status)
            if pending { pill.handle(.youStarted) }
            let motion = PillMotion(); motion.snap(pill)
            let size = motion.size
            let view = composed(pill, settings: settings, motion: motion, theme: theme, scene: scene,
                                origin: CGPoint(x: 40, y: 40))
                .frame(width: size.width + 80, height: size.height + 80, alignment: .topLeading).clipped()
            let path = dir + "/\(theme.name.rawValue)-\(pending ? "pending" : "private-cue").png"
            guard writePNG(view, to: path) else { return 1 }
            print("\(path) pending=\(pending) notice=\(status.notice ?? "none")")
        }
    }
    return 0
}
