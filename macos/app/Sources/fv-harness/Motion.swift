import Foundation
import SwiftUI
import AppKit
import FloatingVoiceCore
import FloatingVoiceUI

// Frames of the pill's grow and shrink, rendered offscreen at 50 frames a second: the same PillMotion spring the app
// runs on the display link, stepped by hand, with the view laid out at its size each frame. Writes PNG frames, a
// size log, a GIF and (with ffmpeg on the machine) an MP4, and a contact sheet.

private struct Cue {
    let at: Double
    let label: String
    let run: (PillModel, inout ConversationController.Status) -> Void
}

@MainActor
private func sequence(name: String, cues: [Cue], duration: Double, canvas: CGSize, quietJumpAt: Double?,
                      theme: PillTheme, dir: String) -> [(Double, CGSize, String)]? {
    let frames = dir + "/\(name)-frames"
    try? FileManager.default.removeItem(atPath: frames)
    try? FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
    var clock = 1_000_000.0
    let pill = PillModel(now: { clock })
    var status = ConversationController.Status()
    status.running = true; status.phase = "ready"; status.connection = "connected"
    status.target = "ses_SYNTHETIC0022c76RThXACt6GCT"; status.targetTitle = "Chief of staff"
    pill.update(status: status)
    let settings = sampleSettings()
    let motion = PillMotion()
    motion.snap(pill)
    let scene = Scene.make(wallpaper: "Sonoma", region: CGRect(x: 1000, y: 230, width: canvas.width, height: canvas.height))
    let fps = 50.0, dt = 1 / fps
    var pending = cues
    var nextTick = 0.0
    var log: [(Double, CGSize, String)] = []
    var caption = ""
    let total = Int(duration * fps)
    for i in 0...total {
        let t = Double(i) * dt
        if let jump = quietJumpAt, abs(t - jump) < dt / 2 { clock += 4000; caption = "4 s of quiet later" }
        while let c = pending.first, c.at <= t + 1e-9 {
            c.run(pill, &status)
            pill.update(status: status)
            caption = c.label
            pending.removeFirst()
        }
        // The app ticks the model every 50 ms with the latest levels.
        while nextTick <= t + 1e-9 {
            let speech = 0.03 + 0.17 * abs(sin(nextTick * 7.3)) * (0.6 + 0.4 * sin(nextTick * 2.1))
            if status.hearing { pill.handle(.micLevel(speech)) }
            else if status.speaking { pill.handle(.outputLevel(speech * 0.9)) }
            else { pill.handle(.micLevel(0.005 + 0.002 * sin(nextTick * 13))) }
            pill.tick()
            nextTick += 0.05
            clock += 50
        }
        motion.retarget(pill)
        if i > 0 { motion.step(dt) }
        let view = ZStack(alignment: .bottomLeading) {
            composed(pill, settings: settings, motion: motion, theme: theme, scene: scene, origin: CGPoint(x: 40, y: 36))
            Text(String(format: "%.2f s  ·  %@", t, caption))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.4)))
                .padding(10)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        guard writePNG(view, to: frames + String(format: "/%04d.png", i)) else { return nil }
        log.append((t, motion.size, caption))
    }
    let csv = "t,width,height,caption\n" + log.map { String(format: "%.2f,%.0f,%.0f,%@", $0.0, $0.1.width, $0.1.height, $0.2) }.joined(separator: "\n")
    try? csv.write(toFile: dir + "/\(name)-sizes.csv", atomically: true, encoding: .utf8)
    encode(frames: frames, name: name, dir: dir, fps: fps)
    print("\(name): \(log.count) frames in \(frames)")
    return log
}

/// GIF at 1x (palette per sequence) and MP4 at 2x, with the ffmpeg already installed; skipped if it is missing.
private func encode(frames: String, name: String, dir: String, fps: Double) {
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let ffmpeg else { print("ffmpeg not found; frames only"); return }
    func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        try? p.run(); p.waitUntilExit()
    }
    let input = ["-framerate", String(Int(fps)), "-i", frames + "/%04d.png"]
    run(input + ["-vf", "scale=iw/2:ih/2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a",
                 dir + "/\(name).gif"])
    run(input + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "-movflags", "+faststart", dir + "/\(name).mp4"])
}

/// Every `every`-th frame from `from` to `to` (seconds), in a grid, at 1x.
@MainActor
private func contactSheet(name: String, dir: String, from: Double, to: Double, every: Int, columns: Int, fps: Double = 50) {
    let frames = dir + "/\(name)-frames"
    var images: [NSImage] = []
    var i = Int(from * fps)
    while Double(i) <= to * fps {
        if let img = NSImage(contentsOfFile: frames + String(format: "/%04d.png", i)) { images.append(img) }
        i += every
    }
    guard let first = images.first else { return }
    let w = first.size.width / 2, h = first.size.height / 2
    let rows = (images.count + columns - 1) / columns
    let sheet = NSImage(size: NSSize(width: w * CGFloat(columns), height: h * CGFloat(rows)))
    sheet.lockFocus()
    for (k, img) in images.enumerated() {
        let x = CGFloat(k % columns) * w, y = CGFloat(rows - 1 - k / columns) * h
        img.draw(in: NSRect(x: x, y: y, width: w, height: h))
    }
    sheet.unlockFocus()
    if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir + "/\(name)-sheet.png"))
    }
}

@MainActor
func renderMotion(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let first = "Check on Dream Studio and tell me if the PC test passed."
    let s1 = "Dream Studio's PC test passed."
    let s2 = "The English patch is live, and the Windows build is queued right behind it."
    let talk: [Cue] = [
        Cue(at: 0.0, label: "listening") { _, _ in },
        Cue(at: 0.5, label: "you start talking") { p, s in s.hearing = true; p.update(status: s); p.handle(.youSpeaking) },
        Cue(at: 0.95, label: "live words") { p, _ in p.handle(.youLive("check on")) },
        Cue(at: 1.25, label: "live words") { p, _ in p.handle(.youLive("check on dream studio")) },
        Cue(at: 1.55, label: "live words") { p, _ in p.handle(.youLive("check on dream studio and tell")) },
        Cue(at: 1.85, label: "live words wrap") { p, _ in p.handle(.youLive("check on dream studio and tell me if the")) },
        Cue(at: 2.15, label: "live words wrap") { p, _ in p.handle(.youLive("check on dream studio and tell me if the PC test")) },
        Cue(at: 2.80, label: "final text, sent") { p, s in
            s.hearing = false; s.busy = true; p.update(status: s)
            p.handle(.youFinal(first)); p.handle(.posted(first))
        },
        Cue(at: 3.40, label: "the chief speaks") { p, s in
            s.speaking = true; p.update(status: s)
            p.handle(.chiefQueued(label: "m:0", text: s1)); p.handle(.chiefStarted(label: "m:0", text: s1))
        },
        Cue(at: 4.60, label: "next sentence") { p, _ in
            p.handle(.chiefEnded(label: "m:0", text: s1, outcome: "played"))
            p.handle(.chiefQueued(label: "m:0", text: s2)); p.handle(.chiefStarted(label: "m:0", text: s2))
        },
        Cue(at: 6.20, label: "quiet") { p, s in
            p.handle(.chiefEnded(label: "m:0", text: s2, outcome: "played"))
            s.speaking = false; s.busy = false; p.update(status: s)
        },
    ]
    guard let talkLog = sequence(name: "grow-shrink", cues: talk, duration: 8.2, canvas: CGSize(width: 440, height: 300), quietJumpAt: 7.0,
                                 theme: .graphite, dir: dir) else { return 1 }
    contactSheet(name: "grow-shrink", dir: dir, from: 0.5, to: 1.12, every: 2, columns: 4)

    let settingsCues: [Cue] = [
        Cue(at: 0.0, label: "resting") { _, _ in },
        Cue(at: 0.3, label: "gear: settings open") { p, _ in p.settingsOpen = true },
        Cue(at: 1.6, label: "Done: settings close") { p, _ in p.settingsOpen = false },
    ]
    guard sequence(name: "settings", cues: settingsCues, duration: 2.6, canvas: CGSize(width: 440, height: 660), quietJumpAt: nil,
                   theme: .graphite, dir: dir) != nil else { return 1 }

    // How long each size change took to settle (to the nearest frame), for the README.
    var changes: [String] = []
    var start: (Double, CGSize)?
    for (k, entry) in talkLog.enumerated() where k > 0 {
        let prev = talkLog[k - 1].1
        if entry.1 != prev && start == nil { start = (talkLog[k - 1].0, prev) }
        if let s = start, entry.1 == (k + 1 < talkLog.count ? talkLog[k + 1].1 : entry.1), entry.1 != s.1 {
            changes.append(String(format: "%.2f s: %.0fx%.0f → %.0fx%.0f in %.2f s", s.0, s.1.width, s.1.height, entry.1.width, entry.1.height, entry.0 - s.0))
            start = nil
        }
    }
    try? changes.joined(separator: "\n").write(toFile: dir + "/grow-shrink-transitions.txt", atomically: true, encoding: .utf8)
    print(changes.joined(separator: "\n"))
    return 0
}
