import CoreGraphics

public enum PillState: Sendable {
    case rest, active, panel
}

public enum NotchGeometry {
    static let fallbackSize = CGSize(width: 200, height: 32)
    static let wing: CGFloat = 36
    public static let activeWidth: CGFloat = 420
    public static let stripHeight: CGFloat = 30
    static let panelSize = CGSize(width: 860, height: 540)

    public static func topBand(screen: CGRect, notch: CGRect?) -> CGRect {
        guard let notch else {
            return CGRect(
                x: screen.midX - fallbackSize.width / 2,
                y: screen.maxY - fallbackSize.height,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }
        return CGRect(x: notch.minX - wing, y: notch.minY, width: notch.width + 2 * wing, height: notch.height)
    }

    public static func frame(for state: PillState, screen: CGRect, notch: CGRect?) -> CGRect {
        let band = topBand(screen: screen, notch: notch)
        switch state {
        case .rest:
            return band
        case .active:
            let width = max(activeWidth, band.width)
            return CGRect(
                x: band.midX - width / 2,
                y: band.minY - stripHeight,
                width: width,
                height: band.height + stripHeight
            )
        case .panel:
            let width = min(panelSize.width, screen.width)
            let height = min(panelSize.height, screen.height)
            let x = min(max(band.midX - width / 2, screen.minX), screen.maxX - width)
            return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
        }
    }
}
