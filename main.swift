// Today HUD — a floating list of what you're working on today. Seven items, max.
//
// The list is saved for the current day only and starts fresh each morning
// (6 am by default, matching the focus blocks). There is no ticking timer: the
// app sleeps until you touch the list, plus one wake-up a day for the reset.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Storage

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
}

/// Override the reset time with `defaults write local.today-hud resetHour -int 6`.
enum Store {
    static let maxItems = 7

    static var resetHour: Int {
        let d = UserDefaults.standard
        return d.object(forKey: "resetHour") == nil ? 6 : d.integer(forKey: "resetHour")
    }

    /// Just today's list, overwritten each day: ~/Library/Application Support/TodayHUD/today.json
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodayHUD/today.json")
    }

    /// The list's day: before the reset hour it still belongs to yesterday.
    static func day(_ now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(resetHour) * 3600))
    }

    static func dayKey(_ now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day(now))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func nextReset(after now: Date) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: resetHour, minute: 0, second: 0),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }

    private struct File: Codable {
        var day: String
        var items: [Item]
    }

    static func load() -> [Item] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.day == dayKey() else { return [] }
        return Array(file.items.prefix(maxItems))
    }

    static func save(_ items: [Item]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(day: dayKey(), items: items)).write(to: url, options: .atomic)
        } catch {
            NSLog("Today HUD: couldn't save list: \(error)")
        }
    }
}

// MARK: - Model

final class TodayModel: ObservableObject {
    @Published private(set) var items: [Item] = Store.load() {
        didSet { scheduleSave() }
    }
    @Published var draft = ""
    @Published var hover = false
    @Published var hoveredRow: UUID?
    /// True while the HUD holds the keyboard (you clicked into a text field).
    @Published var editing = false
    /// Briefly true when the last item gets checked off.
    @Published private(set) var allDoneGlow = false
    @Published var scale: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "scale")
        return saved > 0 ? saved : 1
    }() {
        didSet { UserDefaults.standard.set(Double(scale), forKey: "scale") }
    }
    static let scaleRange: ClosedRange<CGFloat> = 0.7...2.5
    /// Where the resize grip is, in the hosting view's top-left coordinates.
    var gripRect: CGRect = .zero
    var onFinishEditing: (() -> Void)?
    var onHide: (() -> Void)?
    var soundOn: Bool {
        get { UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundOn") }
    }
    private var day = Store.dayKey()
    private var saveWork: DispatchWorkItem?
    private var resetTimer: Timer?

    var doneCount: Int { items.filter(\.done).count }
    var isFull: Bool { items.count >= Store.maxItems }
    var allDone: Bool { !items.isEmpty && doneCount == items.count }

    func start() {
        Store.save(items)  // replaces yesterday's file right away if the day has turned
        scheduleReset()
        // A timer doesn't fire while the Mac sleeps, so also check on wake and clock changes.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.checkDay() }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkDay()
            }
        }
    }

    /// Starts a fresh list once the reset hour has passed.
    func checkDay() {
        let key = Store.dayKey()
        if key != day {
            day = key
            onFinishEditing?()
            draft = ""
            items = []
        }
        scheduleReset()
    }

    private func scheduleReset() {
        resetTimer?.invalidate()
        let t = Timer(fire: Store.nextReset(after: Date()).addingTimeInterval(1), interval: 0, repeats: false) {
            [weak self] _ in self?.checkDay()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        resetTimer = t
    }

    /// Writes shortly after the last change, so typing doesn't hit the disk per keystroke.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { Store.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        saveWork?.perform()
        saveWork = nil
    }

    func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isFull else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(Item(text: text)) }
        draft = ""
    }

    func text(_ id: UUID) -> String { items.first { $0.id == id }?.text ?? "" }

    func setText(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
    }

    /// An item edited down to nothing is removed.
    func commit(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let text = items[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { remove(id) } else { items[i].text = text }
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { items[i].done.toggle() }
        if allDone { celebrate() }
    }

    func remove(_ id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        if hoveredRow == id { hoveredRow = nil }
    }

    func clearDone() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll(where: \.done) }
    }

    private func celebrate() {
        if soundOn { NSSound(named: "Glass")?.play() }
        withAnimation(.easeOut(duration: 0.3)) { allDoneGlow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            withAnimation(.easeInOut(duration: 0.5)) { self?.allDoneGlow = false }
        }
    }
}

// MARK: - Views

struct VisualEffect: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    // Round the blur itself (SwiftUI clipping doesn't reach AppKit views),
    // so the window shadow follows the card instead of a square outline.
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        guard v.maskImage?.capInsets.top != radius else { return }
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        v.maskImage = mask
    }
}

enum Palette {
    static let calm = [Color(red: 0.40, green: 0.93, blue: 0.88), Color(red: 0.36, green: 0.55, blue: 1.00)]
    static let fresh = [Color(red: 0.55, green: 1.00, blue: 0.60), Color(red: 0.20, green: 0.80, blue: 0.50)]
}

struct TodayView: View {
    @ObservedObject var model: TodayModel

    private var s: CGFloat { model.scale }
    private var radius: CGFloat { 18 * s }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            header
            if !model.items.isEmpty {
                VStack(spacing: 2 * s) {
                    ForEach(model.items) { item in
                        ItemRow(model: model, item: item, scale: s)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            if model.isFull {
                Text("That's seven. Finish one before adding more.")
                    .font(.system(size: 11 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8 * s)
            } else {
                AddField(model: model, scale: s)
            }
        }
        .padding(14 * s)
        .frame(width: 300 * s, alignment: .leading)
        .background(
            // A soft top sheen gives the glass some depth.
            LinearGradient(colors: [.white.opacity(model.hover ? 0.12 : 0.08), .black.opacity(0.15)],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(VisualEffect(radius: radius))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    model.allDoneGlow
                        ? AnyShapeStyle(LinearGradient(colors: Palette.fresh, startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom)),
                    lineWidth: model.allDoneGlow ? 2 * s : 1)
        )
        .overlay(alignment: .bottomTrailing) { ResizeGrip(model: model, scale: s) }
        .contentShape(Rectangle())
        .onHover { if model.hover != $0 { model.hover = $0 } }
        .contextMenu {
            Picker("Size", selection: $model.scale) {
                ForEach(HUDSize.allCases) { Text($0.label).tag($0.scale) }
            }
            if model.doneCount > 0 { Button("Clear Completed") { model.clearDone() } }
            Button("Hide HUD (keep menu bar icon)") { model.onHide?() }
        }
        .fixedSize()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 1 * s) {
                Text(model.allDone ? "All done ✓" : "Today")
                    .font(.system(size: 18 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(model.allDone ? Palette.fresh[0] : .white)
                Text(Store.day().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(size: 11 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            if model.hover {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15 * s))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onHide?() }
                    .help("Hide HUD — stays in the menu bar (⌃⌥T brings it back)")
            }
            progress
        }
        .padding(.horizontal, 4 * s)
    }

    /// Done out of total, as a small ring.
    private var progress: some View {
        let total = model.items.count
        let fraction = total == 0 ? 0 : CGFloat(model.doneCount) / CGFloat(total)
        let colors = model.allDone ? Palette.fresh : Palette.calm
        return ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 4 * s)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(model.doneCount)/\(total)")
                .font(.system(size: 10 * s, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 36 * s, height: 36 * s)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .help("\(model.doneCount) of \(total) done")
    }
}

struct ItemRow: View {
    @ObservedObject var model: TodayModel
    let item: Item
    let scale: CGFloat
    @FocusState private var hasFocus: Bool

    private var hovered: Bool { model.hoveredRow == item.id }

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17 * scale, weight: .medium))
                .foregroundStyle(item.done ? Palette.fresh[0] : .white.opacity(hovered ? 0.7 : 0.45))
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(item.id) }
                .help(item.done ? "Mark as not done" : "Mark as done")
            TextField("", text: Binding(get: { model.text(item.id) }, set: { model.setText(item.id, $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(item.done ? .white.opacity(0.4) : .white.opacity(0.92))
                .lineLimit(1)
                .focused($hasFocus)
                .onSubmit { finish() }
                .onExitCommand { finish() }
            Image(systemName: "xmark")
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16 * scale, height: 16 * scale)
                .contentShape(Rectangle())
                .onTapGesture { model.remove(item.id) }
                .opacity(hovered ? 1 : 0)
                .help("Remove")
        }
        .padding(.vertical, 6 * scale)
        .padding(.horizontal, 8 * scale)
        .background(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(.white.opacity(hovered ? 0.07 : 0))
        )
        .onHover { inside in
            if inside { model.hoveredRow = item.id } else if hovered { model.hoveredRow = nil }
        }
    }

    private func finish() {
        hasFocus = false
        model.commit(item.id)
        model.onFinishEditing?()
    }
}

struct AddField: View {
    @ObservedObject var model: TodayModel
    let scale: CGFloat
    @FocusState private var hasFocus: Bool
    /// SwiftUI focuses fields on its own; only look focused while typing goes here.
    private var focused: Bool { hasFocus && model.editing }

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 17 * scale, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(focused ? Palette.calm[0] : .white.opacity(0.4))
            TextField("", text: $model.draft,
                      prompt: Text(model.items.isEmpty ? "What matters today?" : "Add to today")
                          .foregroundColor(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .focused($hasFocus)
                // Return adds and keeps the field ready for the next item.
                .onSubmit {
                    if model.draft.trimmingCharacters(in: .whitespaces).isEmpty { return done() }
                    model.add()
                    if model.isFull { done() }
                }
                .onExitCommand { done() }
        }
        .padding(.vertical, 7 * scale)
        .padding(.horizontal, 8 * scale)
        .background(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(.white.opacity(focused ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .strokeBorder(focused ? Palette.calm[0].opacity(0.6) : .clear, lineWidth: 1)
        )
        .help("Return adds it · Return on an empty line or Esc when you're done")
    }

    private func done() {
        hasFocus = false
        model.onFinishEditing?()
    }
}

/// Sits in the bottom-right corner and reports where it is, so a drag starting
/// there resizes instead of moving. Only visible while hovering.
struct ResizeGrip: View {
    @ObservedObject var model: TodayModel
    let scale: CGFloat
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8 * scale, weight: .bold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 18 * scale, height: 18 * scale)
            .opacity(model.hover ? 1 : 0)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { model.gripRect = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { model.gripRect = $0 }
            })
            .onHover { inside in
                guard #available(macOS 15, *) else { return }
                if inside {
                    NSCursor.frameResize(position: .bottomRight, directions: .all).push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

enum HUDSize: CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: Self { self }
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.3
        case .huge: return 1.7
        }
    }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .huge: return "Huge"
        }
    }
}

// MARK: - Global hotkey (Carbon; no Accessibility permission needed)

private var hotKeyHandler: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?

func registerHotKey(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
    hotKeyHandler = handler
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyHandler?()
        return noErr
    }, 1, &spec, nil, nil)
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x544F_4459), id: 1),
                        GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - Panel & app

final class HUDPanel: NSPanel {
    /// Only takes the keyboard when you click into a text field, so the HUD
    /// never steals typing from the app you're working in.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }

    // Clicks on a text field go straight to it (AppKit routes them past the
    // hosting view), so this is where the keyboard is let in.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow,
           let frameView = contentView?.superview,
           isTextEditor(frameView.hitTest(event.locationInWindow)) {
            allowKey = true
            makeKey()
        }
        super.sendEvent(event)
    }

    private func isTextEditor(_ view: NSView?) -> Bool {
        var v = view
        while let current = v {
            if current is NSTextField || current is NSTextView { return true }
            v = current.superview
        }
        return false
    }
}

/// The HUD is never the active window, so without this every first click
/// would be swallowed by AppKit instead of reaching SwiftUI.
final class HUDHostingView: NSHostingView<TodayView> {
    var onDragEnded: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var currentScale: (() -> CGFloat)?
    var isResizeZone: ((CGPoint) -> Bool)?
    private enum Mode { case undecided, moving, resizing(scale: CGFloat, width: CGFloat) }
    private var pending: (event: NSEvent, mouse: NSPoint, origin: NSPoint)?
    private var mode = Mode.undecided

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A press is held back until we know what it is: the grip resizes, other
    // drags move the window, plain clicks are replayed to SwiftUI.
    override func mouseDown(with event: NSEvent) {
        pending = (event, NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        mode = isResizeZone?(p) == true
            ? .resizing(scale: currentScale?() ?? 1, width: bounds.width)
            : .undecided
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pending, let window else { return super.mouseDragged(with: event) }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - p.mouse.x, dy = mouse.y - p.mouse.y
        switch mode {
        case let .resizing(scale, width):
            // Follow whichever direction the cursor moved most; down/right grows.
            let d = abs(dx) > abs(dy) ? dx : -dy
            onResize?(scale * (width + d) / width)
        case .undecided where hypot(dx, dy) < 3:
            return
        default:
            mode = .moving
            window.setFrameOrigin(NSPoint(x: p.origin.x + dx, y: p.origin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pending = nil; mode = .undecided }
        guard let p = pending else { return super.mouseUp(with: event) }
        switch mode {
        case .moving, .resizing:
            onDragEnded?()
        case .undecided:
            super.mouseDown(with: p.event)
            super.mouseUp(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TodayModel()
    var panel: HUDPanel!
    var host: HUDHostingView!
    var statusItem: NSStatusItem!
    var subscriptions: Set<AnyCancellable> = []
    /// Remembered across restarts, so a hidden HUD stays hidden.
    var userHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hudHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "hudHidden") }
    }
    private var shown = false
    private var statusKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        host = HUDHostingView(rootView: TodayView(model: model))
        host.sizingOptions = []
        host.currentScale = { [weak self] in self?.model.scale ?? 1 }
        host.onResize = { [weak self] in
            self?.model.scale = min(max($0, TodayModel.scaleRange.lowerBound), TodayModel.scaleRange.upperBound)
        }
        host.isResizeZone = { [weak self] p in
            guard let grip = self?.model.gripRect, !grip.isEmpty else { return false }
            return grip.insetBy(dx: -4, dy: -4).contains(p)
        }
        host.onDragEnded = { [weak self] in self?.saveFrame() }
        panel.contentView = host
        fitToContent()
        placeInitially()

        model.onHide = { [weak self] in
            self?.userHidden = true
            self?.updateVisibility()
        }
        // Hand the keyboard back to whatever app you were in once you're done typing.
        model.onFinishEditing = { [weak self] in
            guard let self, self.panel.isKeyWindow else { return }
            self.panel.makeFirstResponder(nil)
            self.panel.orderOut(nil)
            if self.shown { self.panel.orderFrontRegardless() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.model.editing = true
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.model.editing = false
            self?.panel.allowKey = false
            self?.panel.makeFirstResponder(nil)
        }
        // Nothing ticks, so re-measuring after each change costs nothing at rest.
        model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.fitToContent()
                self?.updateStatusItem()
            }
            .store(in: &subscriptions)
        registerHotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in self?.toggleHUD() }

        setupStatusItem()
        model.start()
        updateVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushSave()
    }

    private func saveFrame() {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "hudTopLeft")
    }

    private func placeInitially() {
        let size = panel.frame.size
        if let saved = UserDefaults.standard.string(forKey: "hudTopLeft") {
            let topLeft = NSPointFromString(saved)
            let f = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) {
                panel.setFrameOrigin(f.origin)
                return
            }
        }
        // Top left, just under the menu bar.
        guard let vf = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.minX + 16, y: vf.maxY - size.height - 10))
    }

    /// Resizes the window to the card, keeping its top-left corner in place.
    private func fitToContent() {
        // A throwaway measurer: a long-lived one would observe the model and re-render for nothing.
        let measured = NSHostingController(rootView: TodayView(model: model))
            .sizeThatFits(in: CGSize(width: 4000, height: 4000))
        let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let f = panel.frame
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height),
                       display: true)
        panel.invalidateShadow()
    }

    private func updateVisibility() {
        let want = !userHidden
        guard want != shown else { return }
        shown = want
        if want {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        } else {
            model.onFinishEditing?()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = want ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let total = model.items.count
        let title = total == 0 ? "" : " \(model.doneCount)/\(total)"
        let symbol = model.allDone ? "checklist.checked" : "checklist"
        let key = symbol + title
        guard key != statusKey else { return }
        statusKey = key
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Today list")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ])
    }

    @objc func toggleHUD() {
        userHidden.toggle()
        updateVisibility()
    }

    @objc func toggleSound() { model.soundOn.toggle() }

    @objc func clearDone() { model.clearDone() }

    @objc func toggleItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.toggle(id)
    }

    @objc func setSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? HUDSize else { return }
        model.scale = size.scale
    }

    @objc func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "hudTopLeft")
        placeInitially()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let total = model.items.count
        menu.addItem(NSMenuItem(title: total == 0 ? "Nothing on today's list yet"
                                    : "Today · \(model.doneCount) of \(total) done",
                                action: nil, keyEquivalent: ""))
        for item in model.items {
            let entry = NSMenuItem(title: item.text, action: #selector(toggleItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.state = item.done ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        func add(_ title: String, _ action: Selector, key: String = "", checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        add(userHidden ? "Show HUD" : "Hide HUD", #selector(toggleHUD), key: "t")

        let sizes = NSMenu()
        for size in HUDSize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = abs(model.scale - size.scale) < 0.01 ? .on : .off
            sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "HUD Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        if model.doneCount > 0 { add("Clear Completed", #selector(clearDone)) }
        add("Chime When All Done", #selector(toggleSound), checked: model.soundOn)
        add("Reset HUD Position", #selector(resetPosition))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--print") {
    print("Today (\(Store.dayKey())), resets at \(Store.resetHour):00 — \(Store.url.path)")
    for item in Store.load() { print(item.done ? "[x]" : "[ ]", item.text) }
    exit(0)
}

// One instance only (launchd and a manual `open` could both start it).
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
