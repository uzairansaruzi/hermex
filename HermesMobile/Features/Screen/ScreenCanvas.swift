import SwiftUI
import UIKit

/// The picture, in a layer `ScreenFrameStore` writes to directly, so a frame never runs SwiftUI.
/// It fits the view and never asks the desktop to resize. Pinch zooms and one finger pans, with an
/// inset showing where the view is. While `takesTouches`, a tap clicks what's under it, a hold
/// right-clicks and two fingers scroll. VoiceOver reads it as one element.
struct ScreenCanvas: UIViewRepresentable {
    let session: ScreenSession
    let takesTouches: Bool
    /// Hardware keys and the typing field are live.
    let isControlling: Bool
    @Binding var isTyping: Bool

    func makeUIView(context: Context) -> ScreenCanvasView {
        ScreenCanvasView(session: session, onKeyboardDismissed: { isTyping = false })
    }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        view.takesTouches = takesTouches
        view.setControlling(isControlling, typing: isTyping)
    }
}

final class ScreenCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var takesTouches = false
    private let session: ScreenSession
    private let scroll = UIScrollView()
    private let picture = UIView()
    private let inset = UIView()
    private let viewport = UIView()
    private let field: ScreenKeyField
    private var fitted = CGSize.zero
    /// Where the last tap landed, as a fraction of the picture, which typing zooms to. A fraction
    /// because the keyboard and rotation resize the picture.
    private var lastTap: CGPoint?
    private var isControlling = false
    private var isTyping = false
    /// Finger travel not yet turned into wheel clicks.
    private var scrollTravel: CGFloat = 0

    init(session: ScreenSession, onKeyboardDismissed: @escaping () -> Void) {
        self.session = session
        field = ScreenKeyField(session: session, onDismissed: onKeyboardDismissed)
        super.init(frame: .zero)
        backgroundColor = .black

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(scroll)

        picture.layer.contentsGravity = .resize
        picture.layer.magnificationFilter = .linear
        picture.layer.minificationFilter = .trilinear
        scroll.addSubview(picture)
        session.frames.layer = picture.layer
        session.frames.onSizeChange = { [weak self] in self?.pictureSizeChanged() }

        inset.layer.contentsGravity = .resize
        inset.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        inset.layer.borderWidth = 1
        inset.isHidden = true
        inset.isUserInteractionEnabled = false
        viewport.layer.borderColor = UIColor.white.cgColor
        viewport.layer.borderWidth = 1
        inset.addSubview(viewport)
        addSubview(inset)
        session.frames.insetLayer = inset.layer

        addSubview(field)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        picture.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        picture.addGestureRecognizer(hold)
        picture.isUserInteractionEnabled = true
        let twoFingers = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        twoFingers.delegate = self
        scroll.addGestureRecognizer(twoFingers)

        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = String(localized: "Bot's screen")
        accessibilityHint = String(localized: "VoiceOver can't read what's on this screen.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setControlling(_ controlling: Bool, typing: Bool) {
        let typing = controlling && typing
        let changed = controlling != isControlling || typing != isTyping
        isControlling = controlling
        isTyping = typing
        guard changed else { return }
        applyFocus()
        if typing { focusOnLastTap() }
    }

    /// Only a view in a window can become first responder, so this runs again when it joins one.
    private func applyFocus() {
        if isTyping {
            field.becomeFirstResponder()
        } else if isControlling {
            // Hardware keys reach whichever is first responder, with no keyboard on screen.
            becomeFirstResponder()
        } else {
            field.resignFirstResponder()
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyFocus() }
    }

    override var canBecomeFirstResponder: Bool { isControlling }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: true, to: session)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: false, to: session)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: false, to: session)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        layOutPicture()
        let width = min(bounds.width / 4, 112)
        let image = session.frames.image
        let aspect = image.map { CGFloat($0.height) / CGFloat($0.width) } ?? 0.625
        inset.frame = CGRect(x: bounds.width - width - 8, y: 8, width: width, height: width * aspect)
        updateInset()
    }

    private func pictureSizeChanged() {
        setNeedsLayout()
    }

    private func layOutPicture() {
        guard let image = session.frames.image, bounds.width > 0, bounds.height > 0 else { return }
        let ratio = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let fit = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        if fit != fitted {
            fitted = fit
            let zoom = scroll.zoomScale
            scroll.zoomScale = 1
            picture.frame = CGRect(origin: .zero, size: fit)
            scroll.contentSize = fit
            scroll.zoomScale = zoom
            if isTyping { focusOnLastTap() }
        }
        centerPicture()
    }

    private func centerPicture() {
        let x = max((bounds.width - scroll.contentSize.width) / 2, 0)
        let y = max((bounds.height - scroll.contentSize.height) / 2, 0)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    /// While typing, the view stays on the field that was tapped, so the user sees what they type.
    private func focusOnLastTap() {
        guard let lastTap, fitted.width > 0 else { return }
        let size = CGSize(width: fitted.width / 2.5, height: fitted.height / 2.5)
        let center = CGPoint(x: lastTap.x * fitted.width, y: lastTap.y * fitted.height)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        scroll.zoom(to: rect, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func updateInset() {
        let zoomed = scroll.zoomScale > 1.01
        if inset.isHidden == zoomed { inset.isHidden = !zoomed }
        guard zoomed, picture.bounds.width > 0, picture.bounds.height > 0 else { return }
        let visible = scroll.convert(scroll.bounds, to: picture).intersection(picture.bounds)
        let scaleX = inset.bounds.width / picture.bounds.width, scaleY = inset.bounds.height / picture.bounds.height
        viewport.frame = CGRect(x: visible.minX * scaleX, y: visible.minY * scaleY,
                                width: visible.width * scaleX, height: visible.height * scaleY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPicture()
        updateInset()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateInset()
    }

    // MARK: - Touch

    private func pixel(_ point: CGPoint) -> (x: Int, y: Int)? {
        guard let image = session.frames.image else { return nil }
        return screenPixel(at: point, in: picture.bounds.size, width: image.width, height: image.height)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard takesTouches else { return }
        let point = recognizer.location(in: picture)
        lastTap = CGPoint(x: point.x / max(picture.bounds.width, 1), y: point.y / max(picture.bounds.height, 1))
        if let at = pixel(point) { session.click(x: at.x, y: at.y, button: RFBMessage.Button.left) }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard takesTouches, recognizer.state == .began, let at = pixel(recognizer.location(in: picture)) else { return }
        session.click(x: at.x, y: at.y, button: RFBMessage.Button.right)
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard takesTouches else { return }
        if recognizer.state == .began { scrollTravel = 0 }
        scrollTravel += recognizer.translation(in: self).y
        recognizer.setTranslation(.zero, in: self)
        // Two fingers both scroll and pinch. A pinch that has started is zooming, so it doesn't scroll.
        if let pinch = scroll.pinchGestureRecognizer, pinch.state == .began || pinch.state == .changed {
            scrollTravel = 0
            return
        }
        guard let at = pixel(recognizer.location(in: picture)) else { return }
        ScreenWheel.spend(&scrollTravel) { button in session.click(x: at.x, y: at.y, button: button) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scroll.pinchGestureRecognizer
    }
}

/// Turns vertical finger travel into wheel clicks. Fingers moving up push the content up, which
/// is the wheel going down, as on a trackpad.
enum ScreenWheel {
    private static let pointsPerClick: CGFloat = 24

    static func spend(_ travel: inout CGFloat, click: (UInt8) -> Void) {
        while abs(travel) >= pointsPerClick {
            click(travel < 0 ? RFBMessage.Button.wheelDown : RFBMessage.Button.wheelUp)
            travel += travel < 0 ? pointsPerClick : -pointsPerClick
        }
    }
}

/// Carries the iOS keyboard: Paste and password AutoFill insert through it, and each scalar goes
/// out as a key. It stays empty, so nothing typed, a password least of all, is kept on the phone.
final class ScreenKeyField: UITextField, UITextFieldDelegate {
    private let session: ScreenSession
    private let onDismissed: () -> Void

    init(session: ScreenSession, onDismissed: @escaping () -> Void) {
        self.session = session
        self.onDismissed = onDismissed
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.01
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        textContentType = .password
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        session.type(string)
        return false
    }

    /// An empty field reports Backspace here and nowhere else.
    override func deleteBackward() {
        session.press(.backspace)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        session.press(.enter)
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onDismissed()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: true, to: session)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: false, to: session)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = ScreenHardwareKeys.forward(presses, down: false, to: session)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

/// Maps a hardware keyboard to the screen.
@MainActor enum ScreenHardwareKeys {
    /// Sends what it can and returns what it couldn't, for the responder chain.
    static func forward(_ presses: Set<UIPress>, down: Bool, to session: ScreenSession) -> Set<UIPress> {
        presses.filter { press in
            guard let uiKey = press.key, let key = key(uiKey) else { return true }
            session.hardwareKey(key, down: down)
            return false
        }
    }

    private static func key(_ key: UIKey) -> ScreenKey? {
        switch key.keyCode {
        case .keyboardEscape: return .escape
        case .keyboardTab: return .tab
        case .keyboardReturnOrEnter, .keypadEnter: return .enter
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardDeleteForward: return .delete
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .option
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        case .keyboardF1: return .function(1)
        case .keyboardF2: return .function(2)
        case .keyboardF3: return .function(3)
        case .keyboardF4: return .function(4)
        case .keyboardF5: return .function(5)
        case .keyboardF6: return .function(6)
        case .keyboardF7: return .function(7)
        case .keyboardF8: return .function(8)
        case .keyboardF9: return .function(9)
        case .keyboardF10: return .function(10)
        case .keyboardF11: return .function(11)
        case .keyboardF12: return .function(12)
        default:
            // Shift picks the character itself; with Control, Option or Command the key is what counts.
            let chorded = !key.modifierFlags.intersection([.control, .alternate, .command]).isEmpty
            let text = chorded ? key.charactersIgnoringModifiers : key.characters
            return text.unicodeScalars.first.flatMap(ScreenKey.init(typing:))
        }
    }
}

/// The trackpad panel: swipe to move, tap to click, hold to drag, two fingers to scroll or
/// right-click. The motion is the pointer's, in the session, which keeps it on the picture.
struct ScreenTrackpad: UIViewRepresentable {
    let session: ScreenSession

    func makeUIView(context: Context) -> ScreenTrackpadView {
        ScreenTrackpadView(session: session)
    }

    func updateUIView(_ view: ScreenTrackpadView, context: Context) {}
}

final class ScreenTrackpadView: UIView {
    private let session: ScreenSession
    private var dragFrom: CGPoint?
    private var scrollTravel: CGFloat = 0

    init(session: ScreenSession) {
        self.session = session
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Trackpad")
        accessibilityTraits = .allowsDirectInteraction

        let move = UIPanGestureRecognizer(target: self, action: #selector(moved))
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)
        let twoFingers = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingers)
        let click = UITapGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClicked))
        rightClick.numberOfTouchesRequired = 2
        addGestureRecognizer(rightClick)
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragged))
        drag.minimumPressDuration = 0.35
        addGestureRecognizer(drag)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pixels a point of finger travel moves the pointer: the panel's width crosses the picture
    /// about one and a half times, which is enough to reach a corner in one swipe.
    private var pointerSpeed: CGFloat {
        guard let image = session.frames.image, bounds.width > 0 else { return 1 }
        return CGFloat(image.width) / bounds.width * 1.5
    }

    private func move(by delta: CGPoint, buttons: UInt8) {
        session.movePointer(byX: Int((delta.x * pointerSpeed).rounded()), y: Int((delta.y * pointerSpeed).rounded()), buttons: buttons)
    }

    @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
        move(by: recognizer.translation(in: self), buttons: 0)
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { scrollTravel = 0 }
        scrollTravel += recognizer.translation(in: self).y
        recognizer.setTranslation(.zero, in: self)
        ScreenWheel.spend(&scrollTravel) { session.clickAtPointer(button: $0) }
    }

    @objc private func clicked() {
        session.clickAtPointer(button: RFBMessage.Button.left)
    }

    @objc private func rightClicked() {
        session.clickAtPointer(button: RFBMessage.Button.right)
    }

    @objc private func dragged(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dragFrom = point
            move(by: .zero, buttons: RFBMessage.Button.left)
        case .changed:
            guard let from = dragFrom else { return }
            move(by: CGPoint(x: point.x - from.x, y: point.y - from.y), buttons: RFBMessage.Button.left)
            dragFrom = point
        default:
            dragFrom = nil
            move(by: .zero, buttons: 0)
        }
    }
}
