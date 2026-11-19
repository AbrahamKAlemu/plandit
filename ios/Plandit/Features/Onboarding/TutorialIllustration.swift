import SwiftUI

/// The tutorial's drawings, after the design draft: a white card over a field of blocks, some with
/// hatching. (1) a saved post with a bookmark, (2) three sliders, (3) a map with a dotted route.
/// Existing colors only. Drawn in a 300 × 200 space and scaled to fit; decorative, so VoiceOver
/// skips it. To be swapped for the designer's files if they arrive.
struct TutorialIllustration: View {
    let page: TutorialPage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let page = page
        let palette = IllustrationPalette(scheme: colorScheme)
        let design = IllustrationPalette.designSize
        Canvas { context, size in
            let scale = min(size.width / design.width, size.height / design.height)
            context.translateBy(x: (size.width - design.width * scale) / 2, y: (size.height - design.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let pen = IllustrationPen(palette: palette)
            switch page {
            case .share: pen.drawSavedPost(in: &context)
            case .shape: pen.drawSliders(in: &context)
            case .plan: pen.drawMap(in: &context)
            }
        }
        .aspectRatio(IllustrationPalette.designSize.width / IllustrationPalette.designSize.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Which existing token plays each role. In dark mode `emeraldDeep` equals `emerald`, so hatching
/// on emerald blocks switches to the canvas color there to stay visible.
private struct IllustrationPalette {
    static let designSize = CGSize(width: 300, height: 200)

    let line: Color = .emeraldDeep
    let green: Color = .emerald
    let tint: Color = .emeraldTint
    let paper: Color = .surface
    let rule: Color = .border
    let hatchOnGreen: Color

    init(scheme: ColorScheme) {
        hatchOnGreen = scheme == .dark ? .canvas : .emeraldDeep
    }
}

private enum BlockFill { case green, tint, paper }

private struct Block {
    let column: Int
    let row: Int
    let fill: BlockFill
    var hatched = false
}

private struct IllustrationPen {
    let palette: IllustrationPalette

    // MARK: Pages

    func drawSavedPost(in context: inout GraphicsContext) {
        drawBlocks([
            Block(column: 0, row: 0, fill: .tint, hatched: true),
            Block(column: 1, row: 0, fill: .green),
            Block(column: 3, row: 0, fill: .paper),
            Block(column: 0, row: 1, fill: .tint),
            Block(column: 0, row: 2, fill: .green, hatched: true),
            // Tint, so the emerald bookmark in front of it stands out.
            Block(column: 4, row: 1, fill: .tint),
            Block(column: 4, row: 2, fill: .green, hatched: true),
            Block(column: 2, row: 2, fill: .tint, hatched: true),
        ], hatch: .degrees(45), in: &context)

        let card = Path(roundedRect: CGRect(x: 84, y: 30, width: 110, height: 132), cornerRadius: 14, style: .continuous)
        context.fill(card, with: .color(palette.paper))
        context.stroke(card, with: .color(palette.line), lineWidth: 2.5)

        let photoRect = CGRect(x: 97, y: 44, width: 84, height: 64)
        let photo = Path(roundedRect: photoRect, cornerRadius: 8, style: .continuous)
        context.fill(photo, with: .color(palette.tint))
        var mountain = Path()
        mountain.addLines([
            point(in: photoRect, 0.05, 0.92), point(in: photoRect, 0.32, 0.5), point(in: photoRect, 0.5, 0.74),
            point(in: photoRect, 0.7, 0.42), point(in: photoRect, 0.95, 0.9),
        ])
        var clipped = context
        clipped.clip(to: photo)
        clipped.stroke(mountain, with: .color(palette.line), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        context.stroke(photo, with: .color(palette.line), lineWidth: 2.2)

        strokeLine(from: CGPoint(x: 104, y: 125), to: CGPoint(x: 160, y: 125), width: 2.6, in: &context)
        strokeLine(from: CGPoint(x: 104, y: 138), to: CGPoint(x: 140, y: 138), width: 2.6, in: &context)

        var bookmark = Path()
        bookmark.addLines([
            CGPoint(x: 203, y: 86), CGPoint(x: 229, y: 86), CGPoint(x: 229, y: 128),
            CGPoint(x: 216, y: 117), CGPoint(x: 203, y: 128),
        ])
        bookmark.closeSubpath()
        context.fill(bookmark, with: .color(palette.green))
        context.stroke(bookmark, with: .color(palette.line), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
    }

    func drawSliders(in context: inout GraphicsContext) {
        drawBlocks([
            Block(column: 0, row: 0, fill: .tint),
            Block(column: 1, row: 0, fill: .green, hatched: true),
            Block(column: 3, row: 0, fill: .tint, hatched: true),
            Block(column: 0, row: 1, fill: .green),
            Block(column: 4, row: 1, fill: .green),
            Block(column: 0, row: 2, fill: .paper),
            Block(column: 4, row: 2, fill: .paper),
            Block(column: 2, row: 2, fill: .tint),
        ], hatch: .degrees(45), in: &context)

        let panel = Path(roundedRect: CGRect(x: 58, y: 36, width: 184, height: 128), cornerRadius: 16, style: .continuous)
        context.fill(panel, with: .color(palette.paper))
        context.stroke(panel, with: .color(palette.line), lineWidth: 2.5)

        for (y, knob) in [(CGFloat(70), CGFloat(140)), (100, 194), (130, 164)] {
            strokeLine(from: CGPoint(x: 77, y: y), to: CGPoint(x: 86, y: y), width: 2.6, in: &context)
            strokeLine(from: CGPoint(x: 98, y: y), to: CGPoint(x: 220, y: y), width: 2.6, color: palette.rule, in: &context)
            drawDot(at: CGPoint(x: knob, y: y), in: &context)
        }
    }

    func drawMap(in context: inout GraphicsContext) {
        drawBlocks([
            Block(column: 0, row: 0, fill: .green, hatched: true),
            Block(column: 1, row: 0, fill: .paper),
            Block(column: 3, row: 0, fill: .green),
            Block(column: 0, row: 1, fill: .paper, hatched: true),
            Block(column: 4, row: 1, fill: .paper, hatched: true),
            Block(column: 0, row: 2, fill: .tint, hatched: true),
            Block(column: 2, row: 2, fill: .green, hatched: true),
            Block(column: 4, row: 2, fill: .tint, hatched: true),
        ], hatch: .degrees(-10), in: &context)

        let panel = Path(roundedRect: CGRect(x: 50, y: 34, width: 200, height: 132), cornerRadius: 16, style: .continuous)
        context.fill(panel, with: .color(palette.paper))
        var streets = Path()
        for x in [96, 140, 189, 224] as [CGFloat] {
            streets.move(to: CGPoint(x: x, y: 34))
            streets.addLine(to: CGPoint(x: x, y: 166))
        }
        for y in [68, 100, 132] as [CGFloat] {
            streets.move(to: CGPoint(x: 50, y: y))
            streets.addLine(to: CGPoint(x: 250, y: y))
        }
        var clipped = context
        clipped.clip(to: panel)
        clipped.stroke(streets, with: .color(palette.rule), lineWidth: 2.5)

        var route = Path()
        route.addLines([
            CGPoint(x: 80, y: 132), CGPoint(x: 140, y: 132), CGPoint(x: 140, y: 100),
            CGPoint(x: 189, y: 100), CGPoint(x: 189, y: 68), CGPoint(x: 224, y: 68),
        ])
        context.stroke(route, with: .color(palette.line), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round, dash: [0.1, 6.5]))
        context.stroke(panel, with: .color(palette.line), lineWidth: 2.5)

        for stop in [CGPoint(x: 80, y: 132), CGPoint(x: 189, y: 100), CGPoint(x: 224, y: 68)] {
            drawDot(at: stop, in: &context)
        }
    }

    // MARK: Pieces

    /// A 5 × 3 field of 51 pt cells behind the card; cells left out stay empty.
    private func drawBlocks(_ blocks: [Block], hatch angle: Angle, in context: inout GraphicsContext) {
        for block in blocks {
            let rect = CGRect(x: 22 + CGFloat(block.column) * 51.5, y: 22 + CGFloat(block.row) * 52, width: 51, height: 51.5)
            let shape = Path(rect)
            let (fill, hatch): (Color, Color) = switch block.fill {
            case .green: (palette.green, palette.hatchOnGreen)
            case .tint: (palette.tint, palette.line)
            case .paper: (palette.paper, palette.rule)
            }
            context.fill(shape, with: .color(fill))
            if block.hatched {
                var clipped = context
                clipped.clip(to: shape)
                clipped.stroke(hatching(in: rect, angle: angle, spacing: 6), with: .color(hatch), lineWidth: 1)
            }
            context.stroke(shape, with: .color(palette.rule), lineWidth: 1)
        }
    }

    /// Parallel lines across `rect`; 45° rises to the right like "/".
    private func hatching(in rect: CGRect, angle: Angle, spacing: CGFloat) -> Path {
        let reach = hypot(rect.width, rect.height)
        let direction = CGVector(dx: cos(angle.radians), dy: -sin(angle.radians))
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        var path = Path()
        var offset = -reach / 2
        while offset <= reach / 2 {
            let center = CGPoint(x: rect.midX + normal.dx * offset, y: rect.midY + normal.dy * offset)
            path.move(to: CGPoint(x: center.x - direction.dx * reach, y: center.y - direction.dy * reach))
            path.addLine(to: CGPoint(x: center.x + direction.dx * reach, y: center.y + direction.dy * reach))
            offset += spacing
        }
        return path
    }

    private func drawDot(at center: CGPoint, in context: inout GraphicsContext) {
        let dot = Path(ellipseIn: CGRect(x: center.x - 8.5, y: center.y - 8.5, width: 17, height: 17))
        context.fill(dot, with: .color(palette.green))
        context.stroke(dot, with: .color(palette.line), lineWidth: 2.2)
    }

    private func strokeLine(from start: CGPoint, to end: CGPoint, width: CGFloat, color: Color? = nil, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color ?? palette.line), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func point(in rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}
