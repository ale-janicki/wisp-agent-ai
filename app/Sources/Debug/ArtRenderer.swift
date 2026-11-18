#if DEBUG
import AppKit
import SwiftUI
import WispCore

@MainActor
enum ArtRenderer {
    static let dmgSize = CGSize(width: 640, height: 400)
    static let dmgAppCenter = CGPoint(x: 160, y: 250)
    static let dmgFolderCenter = CGPoint(x: 480, y: 250)

    private static let iconPoints = [16, 32, 128, 256, 512]

    static func isRequested(_ arguments: [String]) -> Bool {
        value(of: "-WispRenderIcon", in: arguments) != nil || value(of: "-WispRenderDMG", in: arguments) != nil
    }

    static func run(_ arguments: [String]) {
        AppSettings.shared.applyForSnapshot(WispSettings())
        if let path = value(of: "-WispRenderIcon", in: arguments) {
            renderIcons(into: URL(fileURLWithPath: path, isDirectory: true))
        }
        if let path = value(of: "-WispRenderDMG", in: arguments) {
            renderDMGBackground(into: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func renderIcons(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [[String: String]] = []
        for points in iconPoints {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                write(AppIconArt(size: CGFloat(pixels)), size: CGSize(width: pixels, height: pixels), scale: 1, to: directory.appendingPathComponent(name))
                images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
            }
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        if let data = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("Contents.json"))
        }
    }

    private static func renderDMGBackground(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(DMGBackgroundArt(), size: dmgSize, scale: 1, to: directory.appendingPathComponent("background.png"))
        write(DMGBackgroundArt(), size: dmgSize, scale: 2, to: directory.appendingPathComponent("background@2x.png"))
    }

    private static func write(_ view: some View, size: CGSize, scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\._accessibilityReduceMotion, true))
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else {
            print("render-art: failed \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("render-art: \(url.path) \(image.width)x\(image.height)")
        } catch {
            print("render-art: failed \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

private struct AppIconArt: View {
    let size: CGFloat

    private var tile: CGFloat { size * 824 / 1024 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color(hex: 0x2C2E33), Color(hex: 0x0C0D0F)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.4), radius: size * 0.012, y: size * 0.01)
            shape
                .fill(RadialGradient(
                    colors: [Theme.accent.opacity(0.32), Theme.accent.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.56),
                    startRadius: 0,
                    endRadius: tile * 0.55
                ))
            shape
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.5, size * 0.004)
                )
            WispAvatar(size: tile * 0.74, animates: false)
                .offset(y: tile * 0.01)
        }
        .frame(width: tile, height: tile)
        .frame(width: size, height: size)
    }
}

private struct DMGBackgroundArt: View {
    var body: some View {
        let size = ArtRenderer.dmgSize
        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x1B1C20), location: 0),
                    .init(color: Color(hex: 0x24262A), location: 0.42),
                    .init(color: Color(hex: 0x5A5D65), location: 0.76),
                    .init(color: Color(hex: 0x63666E), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0)],
                center: UnitPoint(x: 0.12, y: 0.1),
                startRadius: 0,
                endRadius: 340
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("Wisp")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xF2F2F3))
                Text("Arraste para Aplicativos para instalar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9A9BA1))
            }
            .offset(x: 48, y: 34)
            DMGArrow()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct DMGArrow: View {
    var body: some View {
        let start = CGPoint(x: ArtRenderer.dmgAppCenter.x + 92, y: ArtRenderer.dmgAppCenter.y + 4)
        let end = CGPoint(x: ArtRenderer.dmgFolderCenter.x - 96, y: ArtRenderer.dmgFolderCenter.y + 4)
        let control = CGPoint(x: (start.x + end.x) / 2, y: start.y - 56)
        let angle = atan2(end.y - control.y, end.x - control.x)
        let head: CGFloat = 18
        let gradient = LinearGradient(
            colors: [Theme.accent, Theme.accentTeal],
            startPoint: UnitPoint(x: start.x / ArtRenderer.dmgSize.width, y: 0),
            endPoint: UnitPoint(x: end.x / ArtRenderer.dmgSize.width, y: 0)
        )
        ZStack {
            Path { path in
                path.move(to: start)
                path.addQuadCurve(to: CGPoint(x: end.x - cos(angle) * head * 0.6, y: end.y - sin(angle) * head * 0.6), control: control)
            }
            .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Path { path in
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x - cos(angle - 0.5) * head, y: end.y - sin(angle - 0.5) * head))
                path.addLine(to: CGPoint(x: end.x - cos(angle + 0.5) * head, y: end.y - sin(angle + 0.5) * head))
                path.closeSubpath()
            }
            .fill(gradient)
        }
        .shadow(color: Theme.accent.opacity(0.35), radius: 8)
    }
}
#endif
