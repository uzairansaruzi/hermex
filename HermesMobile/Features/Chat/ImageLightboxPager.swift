import SwiftUI

/// The images one lightbox pages through: a message's images in message order, opened at
/// the one the user tapped. A single image is a gallery of one.
struct ImageLightboxGallery<Item: Identifiable>: Identifiable {
    let items: [Item]
    let startID: Item.ID

    var id: Item.ID { startID }

    /// Keeps the images among `siblings`, in order and without repeating an id. Built when
    /// the user taps, never on a streaming body pass. A tapped item that is not among them
    /// opens alone.
    init(tapped: Item, siblings: [Item], isImage: (Item) -> Bool) {
        var seen = Set<Item.ID>()
        let images = siblings.filter { isImage($0) && seen.insert($0.id).inserted }
        items = images.contains { $0.id == tapped.id } ? images : [tapped]
        startID = tapped.id
    }
}

/// Which pages exist: the selected one and its immediate neighbours, so a swipe lands on a
/// loaded image without a long gallery fetching them all.
enum ImageLightboxAdmission {
    static func admits(index: Int, selectedIndex: Int) -> Bool {
        abs(index - selectedIndex) <= 1
    }
}

/// What one lightbox page gets from its pager.
struct ImageLightboxPage {
    /// The page's place in a gallery of more than one; nil shows no counter.
    let position: (index: Int, count: Int)?
    /// One tap hides the chrome for every page, so comparing images keeps them uncovered.
    let showsChrome: Binding<Bool>
    let onZoomChange: (Bool) -> Void
    /// Moves to the next (+1) or previous (-1) page; VoiceOver's adjustable action.
    let onStep: ((Int) -> Void)?
}

/// A horizontal pager around lightbox pages. Each page is a whole `ImageLightboxView`
/// host with its own loader, retry, and actions, so a failed neighbour stays on its own
/// page. Paging stops while the selected image is zoomed, so a sideways drag pans it.
/// A gallery of one is drawn without the pager, exactly as before galleries.
///
/// The stack is not lazy: a page in the admission window keeps its host, loaded or still
/// loading, while it is off screen. A page that leaves the window becomes plain black,
/// which drops its host with its loader and image; coming back builds a fresh host that
/// loads again.
struct ImageLightboxPager<Item: Identifiable, Page: View>: View {
    private let items: [Item]
    private let page: (Item, ImageLightboxPage) -> Page
    /// Opens on the tapped page: across n pages, page i sits at unit point i / (n - 1). The
    /// starting `scrollPosition` id alone does not move a stack that is not lazy.
    private let startAnchor: UnitPoint

    @State private var selectedID: Item.ID?
    @State private var zoomedID: Item.ID?
    @State private var showsChrome = true

    init(
        gallery: ImageLightboxGallery<Item>,
        @ViewBuilder page: @escaping (Item, ImageLightboxPage) -> Page
    ) {
        items = gallery.items
        self.page = page
        let startIndex = gallery.items.firstIndex { $0.id == gallery.startID } ?? 0
        startAnchor = UnitPoint(x: CGFloat(startIndex) / CGFloat(max(1, gallery.items.count - 1)), y: 0.5)
        _selectedID = State(initialValue: gallery.startID)
    }

    var body: some View {
        if items.count == 1, let item = items.first {
            page(
                item,
                ImageLightboxPage(
                    position: nil,
                    showsChrome: $showsChrome,
                    onZoomChange: { _ in },
                    onStep: nil
                )
            )
        } else {
            pager
        }
    }

    /// The pager runs edge to edge so every image is full-bleed, which takes the safe area
    /// away from its pages; each page gets the screen's back so its chrome clears the
    /// Dynamic Island and the home indicator.
    private var pager: some View {
        let selectedIndex = items.firstIndex { $0.id == selectedID } ?? 0

        return GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Group {
                            if ImageLightboxAdmission.admits(index: index, selectedIndex: selectedIndex) {
                                page(item, pageContext(index: index, id: item.id, selectedIndex: selectedIndex))
                                    .safeAreaPadding(safeArea)
                            } else {
                                Color.black
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        // VoiceOver reads only the page on screen; the neighbours are
                        // laid out but are not where the user is.
                        .accessibilityHidden(index != selectedIndex)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedID)
            .defaultScrollAnchor(startAnchor, for: .initialOffset)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomedID != nil && zoomedID == selectedID)
            // VoiceOver can step away from a zoomed image; once its page is dropped, it comes
            // back at fit scale.
            .onChange(of: selectedIndex) { _, selectedIndex in
                guard let zoomedIndex = items.firstIndex(where: { $0.id == zoomedID }),
                      !ImageLightboxAdmission.admits(index: zoomedIndex, selectedIndex: selectedIndex)
                else { return }
                zoomedID = nil
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func pageContext(index: Int, id: Item.ID, selectedIndex: Int) -> ImageLightboxPage {
        ImageLightboxPage(
            position: (index, items.count),
            showsChrome: $showsChrome,
            onZoomChange: { isZoomed in
                if isZoomed {
                    zoomedID = id
                } else if zoomedID == id {
                    zoomedID = nil
                }
            },
            onStep: { step in
                let target = selectedIndex + step
                guard items.indices.contains(target) else { return }
                selectedID = items[target].id
            }
        )
    }
}
