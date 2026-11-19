import SwiftUI

/// Lucide icons bundled in SharedAssets.xcassets/Icons (stroke 1.75, template-rendered).
/// The style guide allows Lucide only: add new icons to the catalog instead of using SF Symbols.
enum Lucide: String {
    case bookmark, bus, car, check, clock, coffee, footprints, house, info, landmark, link, map, martini
    case navigation, play, plus, route, ticket, trees, users, utensils, video, wallet, x
    case moon
    case calendarDays = "calendar-days"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case arrowUpDown = "arrow-up-down"
    case undo = "undo-2"
    case circleAlert = "circle-alert"
    case circleCheck = "circle-check"
    case clipboardPaste = "clipboard-paste"
    case externalLink = "external-link"
    case loaderCircle = "loader-circle"
    case mapPin = "map-pin"
    case piggyBank = "piggy-bank"
    case share = "share-2"
    case shoppingBag = "shopping-bag"
    case sliders = "sliders-horizontal"
    case trainFront = "train-front"
    case trash = "trash-2"
    case userRound = "user-round"
}

struct Icon: View {
    let icon: Lucide
    var size: CGFloat

    init(_ icon: Lucide, size: CGFloat = 20) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image("Icons/\(icon.rawValue)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Official Plandit artwork copied from Design/Logo into SharedAssets.xcassets/Brand.
/// Never recolor, crop or approximate it. Below 24pt, use the favicon export instead of `mark`;
/// don't use a lockup below ~120pt wide.
///
/// `markSquare` is 1.0.1's mark, the white "P" on green that the app icon uses. In the app it
/// appears through `BrandLockup`; the share sheet shows it on its own. The other assets are 1.0's.
enum BrandArt: String {
    case mark
    case markSquare = "mark-square"
    case markOnDark = "mark-on-dark"
    case markBlack = "mark-black"
    case markWhite = "mark-white"
    case lockupStackedLight = "lockup-stacked-light"
    case lockupStackedDark = "lockup-stacked-dark"
    case avatar

    var image: Image { Image("Brand/\(rawValue)") }
}

/// The mark beside the word "Plandit" in Manrope: on the splash screen, Welcome and Profile's footer.
/// A logo, so it keeps its size at every Dynamic Type setting.
struct BrandLockup: View {
    var markSize: CGFloat = 40

    var body: some View {
        HStack(spacing: markSize * 0.25) {
            BrandArt.markSquare.image
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
            Text("Plandit")
                .font(Font(UIFont.manrope(.extraBold, size: markSize * 0.7)))
                .foregroundStyle(Color.ink)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plandit")
        .accessibilityAddTraits(.isImage)
    }
}
