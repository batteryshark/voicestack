import Foundation
import SwiftUI
import AppKit

// App icon options, drawn in SwiftUI and rendered offscreen. Each option is a background fill plus layers, written two
// ways into app/Icon/options/<option>/:
//   AppIcon.icon        an Icon Composer document (icon.json and one PNG per layer); Xcode's actool compiles it into
//                       Assets.car, so macOS 26 and later draw it as a native icon (Liquid Glass, dark and tinted looks)
//   AppIcon-1024.png    the flat icon on Apple's pre-26 grid (824 pt rounded square on a 1024 canvas, with shadow),
//                       for the .icns fallback when Xcode isn't there
// Previews go to logs/icon-options/. `--app-icon N` also makes option N the app's icon (as scripts/set-icon.sh does).

private let blue = Color(red: 0.35, green: 0.66, blue: 1.0)
private let blueDeep = Color(red: 0.15, green: 0.39, blue: 0.92)
private let amber = Color(red: 1.0, green: 0.71, blue: 0.33)
private let amberDeep = Color(red: 1.0, green: 0.45, blue: 0.24)
private let violet = Color(red: 0.69, green: 0.49, blue: 1.0)

/// An sRGB colour, kept as numbers so it can go into icon.json and SwiftUI alike.
private struct RGB {
    let r, g, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    var json: String { String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", r, g, b) }
}

/// One layer of an option: drawn on a transparent 824 pt body (the whole icon shape), front-most last.
private struct IconLayer {
    let name: String
    /// Liquid Glass on this layer (macOS 26+): refraction and specular edges from the system.
    let glass: Bool
    /// The system's drop shadow under this layer's group.
    let shadow: Bool
    let view: AnyView
}

private struct IconOption {
    let name: String
    let top: RGB
    let bottom: RGB
    let layers: [IconLayer]

    /// The flat icon on the pre-26 grid: fill and layers in the rounded square, with Apple's shadow and a hairline.
    var flat: some View {
        let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        return ZStack {
            shape.fill(Color.black).frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.30), radius: 14, y: 10)
            ZStack {
                LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom)
                ForEach(Array(layers.enumerated()), id: \.offset) { _, l in l.view }
            }
            .frame(width: 824, height: 824)
            .clipShape(shape)
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 2).frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
    }

    /// icon.json: the fill, then groups front-most first, one layer each.
    var iconJSON: [String: Any] {
        [
            "fill": [
                "linear-gradient": [top.json, bottom.json],
                "orientation": ["start": ["x": 0.5, "y": 0.0], "stop": ["x": 0.5, "y": 1.0]],
            ],
            "groups": layers.reversed().map { l -> [String: Any] in
                [
                    "layers": [[
                        "image-name": "\(l.name).png",
                        "name": l.name,
                        "glass": l.glass,
                        "position": ["scale": 1.0, "translation-in-points": [0.0, 0.0]],
                    ] as [String: Any]],
                    "shadow": ["kind": l.shadow ? "neutral" : "none", "opacity": 0.5] as [String: Any],
                    "translucency": ["enabled": l.glass, "value": 0.5] as [String: Any],
                ]
            },
            "supported-platforms": ["circles": ["watchOS"], "squares": "shared"] as [String: Any],
        ]
    }
}

/// A mirrored waveform of capsules.
private struct Bars: View {
    let heights: [CGFloat]
    let width: CGFloat
    let gap: CGFloat
    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in Capsule().frame(width: width, height: h) }
        }
    }
}

private func layer(_ name: String, glass: Bool = false, shadow: Bool = false, @ViewBuilder _ v: () -> some View) -> IconLayer {
    IconLayer(name: name, glass: glass, shadow: shadow, view: AnyView(v().frame(width: 824, height: 824)))
}

/// Option 1, "The pill": the floating module itself on graphite, both voices meeting in its waveform.
private let optionPill: IconOption = {
    let heights: [CGFloat] = [0.20, 0.36, 0.56, 0.78, 0.94, 1.0, 0.92, 0.74, 0.54, 0.34, 0.18].map { 40 + $0 * 132 }
    let wave = Bars(heights: heights, width: 30, gap: 17)
    let voices = LinearGradient(colors: [blue, violet, amber], startPoint: .leading, endPoint: .trailing)
    return IconOption(name: "1-pill", top: RGB(r: 0.19, g: 0.20, b: 0.26), bottom: RGB(r: 0.07, g: 0.07, b: 0.10), layers: [
        layer("glow") {
            ZStack {
                RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 520)
                Ellipse().fill(voices).frame(width: 600, height: 110).blur(radius: 60).opacity(0.55).offset(y: 150)
            }
        },
        layer("pill", glass: true, shadow: true) {
            ZStack {
                Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                Capsule().fill(Color(red: 0.10, green: 0.10, blue: 0.13).opacity(0.55))
                Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.06), Color.white.opacity(0.12)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 3)
            }
            .frame(width: 670, height: 252)
            .offset(y: -18)
        },
        layer("waveform") {
            ZStack {
                voices.frame(width: 500, height: 180).mask(wave).blur(radius: 18).opacity(0.85)
                voices.frame(width: 500, height: 180).mask(wave)
                LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                    .frame(width: 500, height: 180).mask(wave).blendMode(.plusLighter)
            }
            .offset(y: -18)
        },
    ])
}()

/// Option 2, "Two voices": a blue and an amber disc overlapping on white, a waveform where they meet.
private let optionTwoVoices: IconOption = {
    let d: CGFloat = 430
    let a = CGSize(width: -92, height: -70), b = CGSize(width: 92, height: 70)
    return IconOption(name: "2-two-voices", top: RGB(r: 0.995, g: 0.995, b: 1.0), bottom: RGB(r: 0.90, g: 0.91, b: 0.95), layers: [
        layer("blue", glass: true, shadow: true) {
            Circle().fill(LinearGradient(colors: [blue, blueDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: d, height: d).offset(a)
        },
        layer("amber", glass: true, shadow: true) {
            Circle().fill(LinearGradient(colors: [amber, amberDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: d, height: d).offset(b)
        },
        layer("overlap") {
            // Where they overlap: a deeper lens.
            LinearGradient(colors: [Color(red: 0.47, green: 0.33, blue: 0.98), Color(red: 0.86, green: 0.25, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 824, height: 824)
                .mask(Circle().frame(width: d, height: d).offset(a))
                .mask(Circle().frame(width: d, height: d).offset(b))
        },
        layer("waveform", shadow: true) {
            Bars(heights: [70, 130, 190, 130, 70], width: 30, gap: 20).foregroundStyle(Color.white)
        },
    ])
}()

/// Option 3, "Sound orb": a glowing orb on deep night, blue turning to amber, with rings of sound around it.
private let optionOrb: IconOption = {
    IconOption(name: "3-sound-orb", top: RGB(r: 0.10, g: 0.11, b: 0.22), bottom: RGB(r: 0.02, g: 0.02, b: 0.05), layers: [
        layer("rings") {
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(AngularGradient(colors: [blue, violet, amber, violet, blue], center: .center), lineWidth: 5 - CGFloat(i))
                        .frame(width: CGFloat(330 + i * 112), height: CGFloat(330 + i * 112))
                        .opacity(0.55 - Double(i) * 0.12)
                }
                Circle().fill(blue).frame(width: 300, height: 300).blur(radius: 70).opacity(0.7)
            }
        },
        layer("orb", glass: true, shadow: true) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.white, Color(red: 0.62, green: 0.82, blue: 1.0), blue, blueDeep],
                                             center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: 190))
                Circle().fill(RadialGradient(colors: [amber, amberDeep.opacity(0.6), .clear], center: UnitPoint(x: 0.78, y: 0.82), startRadius: 0, endRadius: 170))
                    .blendMode(.screen)
            }
            .frame(width: 270, height: 270)
        },
    ])
}()

private let iconOptions = [optionPill, optionTwoVoices, optionOrb]

@MainActor
private func render(_ view: some View, px: CGFloat, points: CGFloat) -> CGImage? {
    let r = ImageRenderer(content: view.frame(width: points, height: points))
    r.scale = px / points
    return r.cgImage
}

@MainActor
private func save(_ image: CGImage, _ path: String) -> Bool {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

/// Write the option's Icon Composer document: icon.json and its layers, each a 1024 px PNG of the whole icon shape.
@MainActor
private func writeIconDocument(_ option: IconOption, to path: String) -> Bool {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.createDirectory(atPath: path + "/Assets", withIntermediateDirectories: true)
    for l in option.layers {
        guard let img = render(l.view, px: 1024, points: 824), save(img, path + "/Assets/\(l.name).png") else { return false }
    }
    guard let json = try? JSONSerialization.data(withJSONObject: option.iconJSON, options: [.prettyPrinted, .sortedKeys]) else { return false }
    return fm.createFile(atPath: path + "/icon.json", contents: json)
}

/// A 128 px icon on a light or dark backdrop (as in Finder or the Dock), and the same at 64 and 32 px.
@MainActor
private func preview(_ option: IconOption, dark: Bool) -> some View {
    let bg = dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color(red: 0.93, green: 0.93, blue: 0.94)
    let images = [128, 64, 32].compactMap { px in render(option.flat, px: CGFloat(px) * 2, points: 1024).map { (px, $0) } }
    return HStack(alignment: .bottom, spacing: 18) {
        ForEach(images, id: \.0) { px, img in
            Image(decorative: img, scale: 2).resizable().interpolation(.high).frame(width: CGFloat(px), height: CGFloat(px))
        }
    }
    .padding(22)
    .background(bg)
}

@MainActor
func renderIcons(to dir: String, appIcon: Int?, appIconDir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for option in iconOptions {
        let name = option.name
        let sources = appIconDir + "/options/\(name)"
        try? FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: true)
        guard let big = render(option.flat, px: 1024, points: 1024),
              save(big, dir + "/option-\(name)-1024.png"), save(big, sources + "/AppIcon-1024.png"),
              writeIconDocument(option, to: sources + "/AppIcon.icon") else { return 1 }
        for dark in [false, true] {
            let r = ImageRenderer(content: preview(option, dark: dark))
            r.scale = 2
            guard let cg = r.cgImage, save(cg, dir + "/option-\(name)-128-\(dark ? "dark" : "light").png") else { return 1 }
        }
        print(sources + "/AppIcon.icon")
    }
    // All three side by side, light over dark, for the taste call.
    let sheet = VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { dark in
            HStack(spacing: 0) { ForEach(iconOptions, id: \.name) { preview($0, dark: dark) } }
        }
    }
    let r = ImageRenderer(content: sheet)
    r.scale = 2
    guard let cg = r.cgImage, save(cg, dir + "/all-options-128.png") else { return 1 }
    if let n = appIcon {
        guard (1...iconOptions.count).contains(n) else { print("--app-icon takes 1 to \(iconOptions.count)"); return 64 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: appIconDir + "/../../scripts/set-icon.sh")
        p.arguments = [String(n)]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { return 1 }
    }
    return 0
}
