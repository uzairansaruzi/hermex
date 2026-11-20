import SwiftUI

struct ImageLightboxGallery<Item: Identifiable>: Identifiable {
    let items: [Item]
    let startID: Item.ID

    var id: Item.ID { startID }

    init(tapped: Item, siblings: [Item], isImage: (Item) -> Bool) {
        var seen = Set<Item.ID>()
        let images = siblings.filter { isImage($0) && seen.insert($0.id).inserted }
        items = images.contains { $0.id == tapped.id } ? images : [tapped]
        startID = tapped.id
    }
}

enum ImageLightboxAdmission {
    static func admits(index: Int, selectedIndex: Int) -> Bool {
        abs(index - selectedIndex) <= 1
    }
}

struct ImageLightboxPage {
    let position: (index: Int, count: Int)?
    let showsChrome: Binding<Bool>
    let onZoomChange: (Bool) -> Void
    let onStep: ((Int) -> Void)?
}

struct ImageLightboxPager<Item: Identifiable, Page: View>: View {
    private let items: [Item]
    private let page: (Item, ImageLightboxPage) -> Page
    private let startAnchor: UnitPoint

    @State private var selectedID: Item.ID?
    @State private var zoomedIDs: Set<Item.ID> = []
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
                        .accessibilityHidden(index != selectedIndex)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedID)
            .defaultScrollAnchor(startAnchor, for: .initialOffset)
            .scrollIndicators(.hidden)
            .scrollDisabled(selectedID.map(zoomedIDs.contains) ?? false)
            .onChange(of: selectedIndex) { _, selectedIndex in
                let admitted = items.indices
                    .filter { ImageLightboxAdmission.admits(index: $0, selectedIndex: selectedIndex) }
                    .map { items[$0].id }
                zoomedIDs.formIntersection(admitted)
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
                    zoomedIDs.insert(id)
                } else {
                    zoomedIDs.remove(id)
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
