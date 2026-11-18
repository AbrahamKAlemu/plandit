import Foundation

/// The category pictures across the top of Saved. "Others" holds shopping and any category added
/// later, so `PlaceCategory` can grow without a new picture.
enum SavedCategoryGroup: String, CaseIterable, Identifiable {
    case food, coffee, activity, outdoors, nightlife, culture, others

    init(_ category: PlaceCategory) {
        // A lookup rather than a switch, so a new PlaceCategory lands in Others without a code change.
        self = Self(rawValue: category.rawValue) ?? .others
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .food: "Food"
        case .coffee: "Coffee"
        case .activity: "Activity"
        case .outdoors: "Outdoors"
        case .nightlife: "Nightlife"
        case .culture: "Culture"
        case .others: "Others"
        }
    }

    /// Watercolor picture in `Assets.xcassets/Categories`.
    var imageName: String { "Categories/\(rawValue)" }
}

enum SavedFilter: CaseIterable {
    case all, freeOnly

    var label: String {
        switch self {
        case .all: "All"
        case .freeOnly: "Free only"
        }
    }
}

enum SavedSort: CaseIterable {
    case newest, oldest

    var label: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        }
    }
}

/// What the Saved list shows: one category group (or all), everything or only free places, newest
/// or oldest first. Pure, so the rules are unit-tested apart from the view.
struct SavedListQuery: Equatable {
    var group: SavedCategoryGroup?
    var filter: SavedFilter = .all
    var sort: SavedSort = .newest

    struct GroupCount: Equatable {
        let group: SavedCategoryGroup
        let count: Int

        /// "Food, 3 places".
        var accessibilityLabel: String {
            "\(group.label), \(count == 1 ? "1 place" : "\(count) places")"
        }
    }

    /// Groups with at least one saved place, in picture order.
    static func groups(in posts: [SavedPost]) -> [GroupCount] {
        let counts = Dictionary(grouping: posts.compactMap { $0.place.map { SavedCategoryGroup($0.category) } }, by: { $0 })
        return SavedCategoryGroup.allCases.compactMap { group in
            counts[group].map { GroupCount(group: group, count: $0.count) }
        }
    }

    /// Free means the place costs $0 in Plandit: the user's price, else the post's, else the typical one.
    static func isFree(_ post: SavedPost) -> Bool {
        post.place != nil && post.plannedCost == 0
    }

    /// A selected category, or Free only, shows only posts with a place. All also shows posts still
    /// being placed.
    func apply(to posts: [SavedPost]) -> [SavedPost] {
        let kept = posts.filter { post in
            if let group, post.place.map({ SavedCategoryGroup($0.category) }) != group { return false }
            if filter == .freeOnly, !Self.isFree(post) { return false }
            return true
        }
        // Stable: posts saved at the same moment keep their order.
        return kept.enumerated().sorted { lhs, rhs in
            if lhs.element.savedAt != rhs.element.savedAt {
                return sort == .newest ? lhs.element.savedAt > rhs.element.savedAt : lhs.element.savedAt < rhs.element.savedAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Tapping the selected picture again shows all.
    mutating func toggle(_ tapped: SavedCategoryGroup) {
        group = group == tapped ? nil : tapped
    }

    /// Drops a selected group whose last place was removed, since its picture is gone too.
    func resolved(for posts: [SavedPost]) -> SavedListQuery {
        guard let group, !Self.groups(in: posts).contains(where: { $0.group == group }) else { return self }
        var query = self
        query.group = nil
        return query
    }

    /// The Filter menu's label: "Filter", or the active choice.
    var filterTitle: String { filter == .all ? "Filter" : filter.label }

    /// The Sort menu's label: "Sort", or the active choice.
    var sortTitle: String { sort == .newest ? "Sort" : sort.label }
}

/// What sits at the right of a saved row, before the chevron.
enum SavedRowTrailing: Equatable {
    /// In today's plan.
    case inPlan
    /// A place that can go into today's plan.
    case add
    /// A post that isn't a plannable place yet.
    case status(String)
    case none

    init(post: SavedPost, isInToday: Bool) {
        if isInToday {
            self = .inPlan
            return
        }
        switch post.status {
        case .processing: self = .status("Finding…")
        case .needsEvidence: self = .status("Add the place")
        case .needsConfirmation: self = .status("Pick the place")
        case .needsReview: self = .status("Check this place")
        case .failed: self = .status("Couldn't find it")
        case .ready: self = post.isMappable ? .add : .none
        }
    }

    var text: String? {
        switch self {
        case .inPlan: "In plan"
        case .status(let word): word
        case .add, .none: nil
        }
    }
}

extension SavedPost {
    /// Free in the Saved list's sense (D-4, D-5).
    var isFreeInSaved: Bool { SavedListQuery.isFree(self) }

    /// "Food · Upper West Side", plus " · Free" when it costs nothing. Nil without a place.
    var savedRowDetail: String? {
        guard let place else { return nil }
        return ([place.category.label, place.neighborhood] + (isFreeInSaved ? ["Free"] : [])).joined(separator: " · ")
    }
}
