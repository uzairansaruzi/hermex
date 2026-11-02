import SwiftUI
import UniformTypeIdentifiers

/// The full-screen Avatar studio, shared by Edit Bot and the create sheet: the face stays in view
/// above one tool at a time. Done hands the finished face back through `onDone`; Cancel drops it.
@MainActor struct BotAvatarStudioView: View {
    @State var studio: BotAvatarStudio
    let onDone: (BotAvatarStudio) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsPhoto = false
    @State private var description = ""
    @State private var pastedText = ""
    @State private var showsPaste = false
    @State private var showsFileImporter = false

    private static let heroSize: CGFloat = 148
    private static let tileFace: CGFloat = 42

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hero.padding(.top, 4).padding(.bottom, 10)
                ScrollView {
                    tool.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("This replaces the photo", isPresented: $confirmsPhoto, titleVisibility: .visible) {
                Button("Replace Photo", role: .destructive) { commit() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Saving this bot deletes its photo from the server.")
            }
            .sheet(isPresented: $showsPaste) { pasteSheet }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.json]) { importFile($0) }
        }
        .onDisappear { studio.stopWaiting() }
        // The editor closes its connection in the background, so no answer can arrive.
        .onChange(of: scenePhase) { if scenePhase == .background { studio.stopWaiting() } }
    }

    private func finish() {
        Task {
            await studio.settleEyes()
            if studio.replacesPhoto { confirmsPhoto = true } else { commit() }
        }
    }

    private func commit() {
        onDone(studio)
        dismiss()
    }

    @ViewBuilder private var hero: some View {
        if studio.tool == .eyes {
            eyeStage
        } else {
            BotInteractiveFaceView(name: studio.name, appearance: studio.appearance, size: Self.heroSize, cue: studio.cue)
        }
    }

    /// Dragging moves the eyes rather than turning the body while the Eyes tool is open.
    private var eyeStage: some View {
        BotAvatarMarkView(name: studio.name, appearance: studio.appearance, size: Self.heroSize)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                var eyes = studio.eyes
                eyes.x = (value.location.x / Self.heroSize * 100).rounded()
                eyes.y = (value.location.y / Self.heroSize * 100).rounded()
                studio.propose(eyes: eyes)
            })
    }

    @ViewBuilder private var tool: some View {
        switch studio.tool {
        case .avatar: avatarTool
        case .style: styleTool
        case .eyes: eyesTool
        case .create: createTool
        }
    }

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(BotAvatarStudio.Tool.allCases) { item in
                Button { studio.tool = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon(item)).font(.system(size: 17))
                        Text(title(item)).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                    .foregroundStyle(studio.tool == item ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(studio.tool == item ? .isSelected : [])
            }
        }
        .padding(.top, 6)
        .background(.bar)
    }

    private func title(_ tool: BotAvatarStudio.Tool) -> LocalizedStringKey {
        switch tool {
        case .avatar: return "Avatar"
        case .style: return "Style"
        case .eyes: return "Eyes"
        case .create: return "Create"
        }
    }

    private func icon(_ tool: BotAvatarStudio.Tool) -> String {
        switch tool {
        case .avatar: return "square.grid.2x2"
        case .style: return "paintpalette"
        case .eyes: return "eye"
        case .create: return "sparkles"
        }
    }

    // MARK: Avatar

    private var avatarTool: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Classic")
            row {
                ForEach(BotAvatarShape.allCases) { shape in
                    tile(selected: studio.isPicked(shape), name: shape.localizedName) { studio.pick(shape) } face: {
                        BotAvatarMarkView(name: studio.name, appearance: classicTile(shape), size: Self.tileFace)
                    }
                }
            }
            label("Creatures")
            catalogRow(BotAvatarCatalog.creatures)
            label("Objects")
            catalogRow(BotAvatarCatalog.objects)
            if studio.appearance.drawn != nil {
                Text("Hermes Desktop shows a simpler shape for this bot.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            Button("Reset to default", systemImage: "arrow.counterclockwise") { studio.reset() }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(.secondary)
                .padding(.top, 10)
        }
    }

    private func catalogRow(_ entries: [BotAvatarCatalog.Entry]) -> some View {
        row {
            ForEach(entries, id: \.definition.id) { entry in
                tile(selected: studio.isPicked(entry), name: BotAvatarCatalog.localizedName(of: entry.definition)) { studio.pick(entry) } face: {
                    BotAvatarMarkView(name: studio.name, appearance: catalogTile(entry), size: Self.tileFace)
                }
            }
        }
    }

    /// Lazy, so a row only builds the faces it scrolls into view.
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) { content() }.padding(.vertical, 2)
        }
    }

    private func tile<Face: View>(selected: Bool, name: String, action: @escaping () -> Void,
                                  @ViewBuilder face: () -> Face) -> some View {
        Button(action: action) {
            face()
                .frame(width: 58, height: 58)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func classicTile(_ shape: BotAvatarShape) -> BotProfileAppearance {
        var appearance = studio.appearance.withoutDrawnAvatar
        appearance.color = BotAvatarPresentation(name: studio.name, appearance: studio.appearance).hex
        appearance.shape = shape.rawValue
        appearance.custom = true
        appearance.expression = nil
        return appearance
    }

    private func catalogTile(_ entry: BotAvatarCatalog.Entry) -> BotProfileAppearance {
        var appearance = BotProfileAppearance(look: [:], fallbackTitle: "")
        appearance.color = entry.color
        appearance.custom = true
        appearance.drawn = BotDrawnAvatar(definition: entry.definition, depth: BotDrawnAvatar.naturalDepth)
        return appearance
    }

    // MARK: Style

    private var styleTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Body")
            swatches(selected: studio.appearance.color,
                     pick: { studio.setBodyColor($0) },
                     custom: Binding(get: { Color.botBody(studio.appearance.color ?? BotAvatarColor.adaptiveHex) },
                                     set: { if let hex = $0.botHex { studio.setBodyColor(hex) } }))
            label("Eyes")
            swatches(selected: studio.appearance.drawn?.eyeColor ?? BotAvatarColor.adaptiveHex,
                     pick: { studio.setEyeColor($0 == BotAvatarColor.adaptiveHex ? nil : $0) },
                     custom: Binding(get: { studio.appearance.drawn?.eyeColor.flatMap(Color.init(botHex:)) ?? .black },
                                     set: { if let hex = $0.botHex { studio.setEyeColor(hex) } }))
            HStack {
                label("Depth")
                Spacer()
                Text(depthName).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Slider(value: Binding(get: { Double(studio.depth) }, set: { studio.setDepth(Int($0.rounded())) }),
                   in: Double(BotDrawnAvatar.depthRange.lowerBound)...Double(BotDrawnAvatar.depthRange.upperBound), step: 1) {
                Text("Depth")
            }
            .accessibilityValue(depthName)
        }
    }

    private var depthName: String {
        switch studio.depth {
        case 0: return String(localized: "Flat")
        case BotDrawnAvatar.naturalDepth: return String(localized: "Natural")
        case BotDrawnAvatar.depthRange.upperBound: return String(localized: "Deep")
        default: return studio.depth.formatted()
        }
    }

    private func swatches(selected: String?, pick: @escaping (String) -> Void, custom: Binding<Color>) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
            ForEach(BotAvatarColor.palette) { color in
                Button { pick(color.hex) } label: {
                    Circle().fill(color.swatch).frame(width: 30, height: 30)
                        .overlay { if selected?.lowercased() == color.hex { Circle().stroke(.secondary, lineWidth: 3).padding(-5) } }
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Avatar color \(color.localizedName)"))
                .accessibilityAddTraits(selected?.lowercased() == color.hex ? .isSelected : [])
            }
            ColorPicker(selection: custom, supportsOpacity: false) { Text("Custom Color") }
                .labelsHidden()
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    // MARK: Eyes

    private var eyesTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Expression")
            row {
                ForEach(BotAvatarExpression.allCases) { expression in
                    let selected = BotAvatarExpression.resolve(studio.appearance.expression) == expression
                    tile(selected: selected, name: expression.localizedName) { studio.setExpression(expression) } face: {
                        VStack(spacing: 2) {
                            BotAvatarMarkView(name: studio.name, appearance: expressionTile(expression), size: 38)
                            Text(expression.localizedName).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            eyeSlider("Size", value: \.scale, range: 0.6...1.8)
            eyeSlider("Spacing", value: \.spacing, range: 7...40)
            eyeSlider("Across", value: \.x, range: 10...90)
            eyeSlider("Up and Down", value: \.y, range: 10...90)
            Text("Drag on the avatar to move the eyes.").font(.caption).foregroundStyle(.secondary)
            if studio.appearance.drawn != nil {
                Button("Reset Eyes", systemImage: "arrow.counterclockwise") { studio.resetEyes() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(.secondary)
            }
        }
    }

    private func expressionTile(_ expression: BotAvatarExpression) -> BotProfileAppearance {
        var appearance = studio.appearance
        appearance.expression = expression.rawValue
        if let baseEyes = studio.baseEyes { appearance.drawn?.definition.eyes = baseEyes }
        return appearance
    }

    private func eyeSlider(_ title: LocalizedStringKey, value: WritableKeyPath<BotAvatarDefinition.Eyes, Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title)
            Slider(value: Binding(get: { studio.eyes[keyPath: value] }, set: {
                var eyes = studio.eyes
                // Two decimals is finer than a finger can see, and keeps stored values short.
                eyes[keyPath: value] = ($0 * 100).rounded() / 100
                studio.propose(eyes: eyes)
            }), in: range) { Text(title) }
        }
    }

    // MARK: Create

    private var createTool: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Describe It")
            TextField("A tiny orange cat holding a wrench", text: $description, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(studio.generation == .running)
            if studio.generation == .running {
                Text("Generating. This can take a few minutes.").font(.subheadline)
                Button("Stop Waiting") { studio.stopWaiting() }.buttonStyle(.bordered)
            } else {
                Button("Generate") { studio.generate(description: description) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!studio.canGenerate || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .failed(let message) = studio.generation {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Text("Uses the host's model, with no tools. Your provider may bill for it, even if you stop waiting.")
                .font(.caption).foregroundStyle(.secondary)

            label("Import").padding(.top, 8)
            Button("Paste JSON", systemImage: "doc.on.clipboard") { pastedText = ""; studio.clearImportErrors(); showsPaste = true }
            Button("Import File", systemImage: "folder") { studio.clearImportErrors(); showsFileImporter = true }
            ShareLink(item: studio.exportText) { Label("Export This Avatar", systemImage: "square.and.arrow.up") }
            importErrorList
        }
    }

    private var importErrorList: some View {
        ForEach(studio.importErrors, id: \.self) { error in
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $pastedText)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxHeight: .infinity)
                importErrorList
            }
            .padding(16)
            .navigationTitle("Paste JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsPaste = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        Task { if await studio.importDefinition(Data(pastedText.utf8)) { showsPaste = false } }
                    }
                    .disabled(pastedText.isEmpty)
                }
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_768 else { return nil }
                return try? Data(contentsOf: url)
            }.value
            if let data { _ = await studio.importDefinition(data) }
            else { studio.noteImportFailure(String(localized: "Could not read this file.")) }
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

extension Color {
    /// This color as a stored `#rrggbb`, for the color picker.
    var botHex: String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return BotAvatarRGB(Double(red) * 255, Double(green) * 255, Double(blue) * 255).hex
    }
}
