import SwiftUI

/// Numbered stop on today's route. A white halo keeps it legible on any map tile.
struct StopPin: View {
    let number: Int
    let status: StopStatus
    var isSelected = false

    var body: some View {
        StopBadge(number: number, status: status, size: isSelected ? 38 : 30)
            .padding(2)
            .background(Circle().fill(.white))
            .animation(.snappy, value: isSelected)
    }
}

/// A saved place. Ink by default; emerald when selected.
struct SavedPin: View {
    let category: PlaceCategory
    var isSelected = false

    var body: some View {
        Icon(category.icon, size: isSelected ? 18 : 14)
            .foregroundStyle(isSelected ? Color.onEmerald : Color.white)
            .frame(width: isSelected ? 38 : 28, height: isSelected ? 38 : 28)
            .background(Circle().fill(isSelected ? Color.emerald : Color.mapPinInk))
            .padding(2)
            .background(Circle().fill(.white))
            .animation(.snappy, value: isSelected)
            .accessibilityLabel(category.label)
    }
}

/// A place from a past plan.
struct VisitedDot: View {
    var body: some View {
        Circle()
            .fill(Color.mapPinInk)
            .frame(width: 10, height: 10)
            .padding(2)
            .background(Circle().fill(.white))
    }
}
