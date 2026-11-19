import Foundation

/// How Plandit counts trips in words. Today's summary and the Budget sheet both use it, so they
/// can't drift apart ("2 drive" in one place, "2 drives" in another).
enum RideWording {
    /// The kinds of ride, in the order they're listed: subway, then bus, then drive.
    static let rideModes: [TravelMode] = [.subway, .bus, .drive]

    /// "1 subway ride", "2 bus rides", "1 drive", "2 drives", "3 walks".
    static func count(_ count: Int, _ mode: TravelMode) -> String {
        "\(count) \(noun(mode, count: count))"
    }

    /// The words after the number: "subway ride", "subway rides", "drive", "drives".
    static func noun(_ mode: TravelMode, count: Int) -> String {
        let one = count == 1
        switch mode {
        case .walk: return one ? "walk" : "walks"
        case .subway: return one ? "subway ride" : "subway rides"
        case .bus: return one ? "bus ride" : "bus rides"
        case .drive: return one ? "drive" : "drives"
        }
    }

    /// One kind in a list that follows "N rides": "1 subway", "2 bus", "2 drives".
    static func kind(_ count: Int, _ mode: TravelMode) -> String {
        switch mode {
        case .subway: "\(count) subway"
        case .bus: "\(count) bus"
        case .walk, .drive: Self.count(count, mode)
        }
    }

    /// Each kind of ride in these trips, walks left out: "1 subway, 2 bus, 2 drives".
    static func kinds(_ legs: [TravelLeg]) -> String {
        counts(legs).map { kind($0.count, $0.mode) }.joined(separator: ", ")
    }

    /// How many rides of each kind, in `rideModes` order, leaving out kinds with none.
    static func counts(_ legs: [TravelLeg]) -> [(mode: TravelMode, count: Int)] {
        rideModes.compactMap { mode in
            let count = legs.filter { $0.mode == mode }.count
            return count > 0 ? (mode, count) : nil
        }
    }
}
