// Today HUD — a floating list of what you're working on today (up to 25 items).
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
    static let maxItems = 25
    /// Past this many items the list scrolls instead of growing down the screen.
    static let visibleRows = 10

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

    /// `now` is the item you're working on right now, if any.
    struct File: Codable {
        var day: String
        var items: [Item]
        var now: UUID?
    }

    static func load() -> File {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.day == dayKey() else { return File(day: dayKey(), items: []) }
        return File(day: file.day, items: Array(file.items.prefix(maxItems)), now: file.now)
    }

    static func save(_ items: [Item], now: UUID?) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(day: dayKey(), items: items, now: now)).write(to: url, options: .atomic)
        } catch {
            NSLog("Today HUD: couldn't save list: \(error)")
        }
    }
}

// MARK: - Model

final class TodayModel: ObservableObject {
    @Published private(set) var items: [Item] = Store.load().items {
        didSet { scheduleSave() }
    }
    /// The one item you're working on right now (like Linear's In Progress).
    @Published private(set) var nowId: UUID? = Store.load().now {
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
    /// The card's width before scaling; drag the right edge to change it.
    @Published var width: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "width")
        return saved > 0 ? saved : 300
    }() {
        didSet { UserDefaults.standard.set(Double(width), forKey: "width") }
    }
    static let widthRange: ClosedRange<CGFloat> = 240...600
    @Published var theme = Theme.choice {
        didSet {
            Theme.choice = theme
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
        }
    }
    /// Where the resize grip is, in the hosting view's top-left coordinates.
    var gripRect: CGRect = .zero
    /// Where each row and the visible list are, same coordinates; used to drag rows.
    var rowFrames: [UUID: CGRect] = [:]
    var listRect: CGRect = .zero
    /// The row being dragged to a new place.
    @Published var draggingId: UUID?
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
    var nowItem: Item? { items.first { $0.id == nowId && !$0.done } }

    func start() {
        Store.save(items, now: nowItem?.id)  // replaces yesterday's file right away if the day has turned
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
            nowId = nil
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
        let snapshot = items, now = nowId
        let work = DispatchWorkItem { Store.save(snapshot, now: now) }
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
        withAnimation(.easeOut(duration: 0.2)) {
            items[i].done.toggle()
            if items[i].done, nowId == id { nowId = nil }  // finishing it ends "now"
        }
        if allDone { celebrate() }
    }

    func row(at point: CGPoint) -> UUID? {
        guard listRect.contains(point) else { return nil }
        return items.first { rowFrames[$0.id]?.contains(point) == true }?.id
    }

    /// Moves the dragged item into the slot of the row under the cursor.
    func drag(to point: CGPoint) {
        guard let id = draggingId, let from = items.firstIndex(where: { $0.id == id }),
              let target = row(at: point), target != id,
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            items.insert(items.remove(at: from), at: to)
        }
    }

    /// Marks an item as the one you're working on now; there's only ever one.
    /// Tapping the current one again clears it.
    func setNow(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { nowId = nowId == id ? nil : id }
    }

    func remove(_ id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        if hoveredRow == id { hoveredRow = nil }
        if nowId == id { nowId = nil }
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

/// Solid color themes. Opaque on purpose: the list stands out and reads the
/// same on any wallpaper, in light or dark mode, and skips a live blur.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case paper, teal, midnight, indigo, forest, plum, graphite
    var id: Self { self }

    var label: String { rawValue.capitalized }
    var isLight: Bool { self == .paper }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// Top and bottom of the card's gentle gradient.
    var card: [Color] {
        switch self {
        case .teal: return [Self.rgb(0.05, 0.38, 0.40), Self.rgb(0.02, 0.25, 0.27)]
        case .midnight: return [Self.rgb(0.09, 0.16, 0.36), Self.rgb(0.05, 0.09, 0.22)]
        case .indigo: return [Self.rgb(0.29, 0.19, 0.58), Self.rgb(0.18, 0.11, 0.40)]
        case .forest: return [Self.rgb(0.09, 0.32, 0.20), Self.rgb(0.04, 0.20, 0.12)]
        case .plum: return [Self.rgb(0.45, 0.12, 0.27), Self.rgb(0.29, 0.06, 0.17)]
        case .graphite: return [Color(white: 0.13), Color(white: 0.06)]
        case .paper: return [.white, Self.rgb(0.97, 0.97, 0.96)]
        }
    }

    var text: Color { isLight ? Self.rgb(0.09, 0.11, 0.18) : .white }  // ink on paper

    /// Paper is a ruled notebook page: blue lines under each item, a red margin.
    var ruled: Bool { self == .paper }
    var rule: Color { ruled ? Self.rgb(0.55, 0.72, 0.93) : text.opacity(0.22) }
    var margin: Color { Self.rgb(0.93, 0.42, 0.42) }

    /// The add line and caret; picked to pop against each card.
    var accent: Color {
        switch self {
        case .teal, .midnight, .forest: return Self.rgb(1.00, 0.86, 0.45)  // warm yellow
        case .indigo, .plum: return Self.rgb(1.00, 0.78, 0.60)  // peach
        case .graphite: return Self.rgb(0.45, 0.80, 1.00)  // sky blue
        case .paper: return Self.rgb(0.15, 0.38, 0.90)  // blue ink
        }
    }

    var green: Color { isLight ? Self.rgb(0.10, 0.55, 0.28) : Self.rgb(0.62, 1.00, 0.72) }
    /// In progress is a quiet gray; green stays for done.
    var progress: Color { isLight ? Self.rgb(0.42, 0.44, 0.50) : Color(white: 0.78) }

    static var saved: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .paper
    }
}

enum Theme {
    static var choice = ThemeChoice.saved
    static var card: [Color] { choice.card }
    static var text: Color { choice.text }
    static var dim: Color { choice.text.opacity(choice.isLight ? 0.65 : 0.72) }
    static var faint: Color { choice.text.opacity(choice.isLight ? 0.42 : 0.5) }
    static var accent: Color { choice.accent }
    static var green: Color { choice.green }
    static var progress: Color { choice.progress }
    static var rule: Color { choice.rule }

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .medium, design: .rounded)
    }
}

struct TodayView: View {
    @ObservedObject var model: TodayModel

    private var s: CGFloat { model.scale }
    private var radius: CGFloat { 16 * s }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            header
            // A thin rule under the heading.
            Capsule().fill(Theme.rule).frame(height: 1.5 * s)
            // The page: items and the add line, with a notebook margin on Paper
            // between the checkboxes and the writing.
            VStack(alignment: .leading, spacing: 8 * s) {
                if model.items.count > Store.visibleRows {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) { rows }
                            .frame(height: CGFloat(Store.visibleRows) * ItemRow.height(s))
                            // Only the rows in view can be dropped on.
                            .background(FrameReporter { model.listRect = $0 })
                            // A newly added item scrolls into view.
                            .onChange(of: model.items.count) { _ in
                                if let last = model.items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                            }
                    }
                } else if !model.items.isEmpty {
                    rows
                }
                if model.isFull {
                    Text("That's 25 — plenty for one day.")
                        .font(Theme.font(12 * s))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6 * s)
                        .padding(.top, 2 * s)
                } else {
                    AddField(model: model, scale: s)
                }
            }
            .background(alignment: .leading) {
                if Theme.choice.ruled {
                    Rectangle().fill(Theme.choice.margin.opacity(0.55))
                        .frame(width: 1.5 * s)
                        .padding(.leading, 29 * s)
                }
            }
        }
        .padding(16 * s)
        .frame(width: model.width * s, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: Theme.card, startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(model.allDoneGlow ? Theme.green.opacity(0.85) : Theme.text.opacity(0.14),
                              lineWidth: model.allDoneGlow ? 2 * s : 1)
        )
        .overlay(alignment: .trailing) { WidthEdge() }
        .overlay(alignment: .bottomTrailing) { ResizeGrip(model: model, scale: s) }
        .tint(Theme.accent)
        .contentShape(Rectangle())
        .onHover { if model.hover != $0 { model.hover = $0 } }
        .contextMenu {
            Picker("Size", selection: $model.scale) {
                ForEach(HUDSize.allCases) { Text($0.label).tag($0.scale) }
            }
            Picker("Color", selection: $model.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
            }
            if model.doneCount > 0 { Button("Clear Completed") { model.clearDone() } }
            Button("Hide HUD (keep menu bar icon)") { model.onHide?() }
        }
        .fixedSize()
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.items) { item in
                ItemRow(model: model, item: item, scale: s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Inside the scroll view the content runs past what's visible; that one reports instead.
        .background(FrameReporter { if model.items.count <= Store.visibleRows { model.listRect = $0 } })
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.allDone ? "All done ✓" : "Today")
                    .font(Theme.font(22 * s, bold: true))
                    .foregroundStyle(model.allDone ? Theme.green : Theme.text)
                Text(Store.day().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(Theme.font(12 * s))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
            if model.hover {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15 * s))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onHide?() }
                    .help("Hide HUD — stays in the menu bar (⌃⌥T brings it back)")
            }
            progress
        }
        .padding(.horizontal, 2 * s)
    }

    /// Done out of total, as a small ring.
    private var progress: some View {
        let total = model.items.count
        let fraction = total == 0 ? 0 : CGFloat(model.doneCount) / CGFloat(total)
        return ZStack {
            Circle().stroke(Theme.text.opacity(0.12), lineWidth: 3.5 * s)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(model.allDone ? Theme.green : Theme.text,
                        style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(model.doneCount)/\(total)")
                .font(Theme.font(11 * s, bold: true))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .frame(width: 38 * s, height: 38 * s)
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
    private var isNow: Bool { model.nowId == item.id && !item.done }
    private var dragging: Bool { model.draggingId == item.id }
    static func height(_ scale: CGFloat) -> CGFloat { 34 * scale }
    private var font: Font { Theme.font(15 * scale) }

    var body: some View {
        HStack(spacing: 10 * scale) {
            // A half-filled circle marks the one in progress, like Linear.
            Image(systemName: item.done ? "checkmark.circle" : isNow ? "circle.lefthalf.filled" : "circle")
                .font(.system(size: 17 * scale, weight: item.done || isNow ? .semibold : .regular))
                .foregroundStyle(item.done ? Theme.green : isNow ? Theme.progress : hovered ? Theme.text : Theme.dim)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(item.id) }
                .help(item.done ? "Mark as not done" : "Mark as done")
            // Done items are plain text with a real strike-through, so the line always
            // shows; uncheck an item to edit it again.
            if item.done {
                Text(item.text)
                    .font(font)
                    .strikethrough(true, color: Theme.dim)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: Binding(get: { model.text(item.id) }, set: { model.setText(item.id, $0) }))
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .focused($hasFocus)
                    .onSubmit { finish() }
                    .onExitCommand { finish() }
            }
            if !item.done {
                Image(systemName: isNow ? "pin.fill" : "pin")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .rotationEffect(.degrees(30))
                    .foregroundStyle(isNow ? Theme.green : Theme.dim)
                    .frame(width: 16 * scale, height: 16 * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { model.setNow(item.id) }
                    .opacity(isNow || hovered ? 1 : 0)
                    .help(isNow ? "Stop working on this" : "Working on this now")
            }
            Image(systemName: "xmark")
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(Theme.dim)
                .frame(width: 16 * scale, height: 16 * scale)
                .contentShape(Rectangle())
                .onTapGesture { model.remove(item.id) }
                .opacity(hovered ? 1 : 0)
                .help("Remove")
        }
        .frame(height: Self.height(scale))
        .padding(.horizontal, 6 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(dragging ? AnyShapeStyle(LinearGradient(colors: Theme.card, startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(Theme.text.opacity(hovered ? 0.06 : 0)))
        )
        .overlay(alignment: .bottom) {
            if Theme.choice.ruled { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
        }
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 6 * scale, y: 2 * scale)
        .zIndex(dragging ? 1 : 0)
        .background(FrameReporter { model.rowFrames[item.id] = $0 })
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

/// The next empty line of the list.
struct AddField: View {
    @ObservedObject var model: TodayModel
    let scale: CGFloat
    @FocusState private var hasFocus: Bool
    /// SwiftUI focuses fields on its own; only look focused while typing goes here.
    private var focused: Bool { hasFocus && model.editing }

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "plus")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.dim)
                .frame(width: 17 * scale)
            TextField("", text: $model.draft,
                      prompt: Text(model.items.isEmpty ? "What matters today?" : "Think, break it down")
                          .foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(Theme.font(15 * scale))
                .foregroundStyle(Theme.text)
                .focused($hasFocus)
                // Return adds and keeps the line ready for the next item.
                .onSubmit {
                    if model.draft.trimmingCharacters(in: .whitespaces).isEmpty { return done() }
                    model.add()
                    if model.isFull { done() }
                }
                .onExitCommand { done() }
        }
        .padding(.vertical, 7 * scale)
        .padding(.horizontal, 6 * scale)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(focused ? Theme.accent.opacity(0.75) : Theme.choice.ruled ? Theme.rule.opacity(0.6) : Theme.text.opacity(0.18))
                .frame(height: 1.5 * scale)
                .padding(.horizontal, 6 * scale)
        }
        .help("Return adds it · Return on an empty line or Esc when you're done")
    }

    private func done() {
        hasFocus = false
        model.onFinishEditing?()
    }
}

/// Reports a view's frame in the hosting view's top-left coordinates.
struct FrameReporter: View {
    let report: (CGRect) -> Void
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { report($0) }
        }
    }
}

/// The right edge: drag it to make the card wider or narrower. Matches the
/// zone the hosting view treats as a width drag.
struct WidthEdge: View {
    static let thickness: CGFloat = 6
    var body: some View {
        Color.clear
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
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

    /// Row dragging, in the hosting view's top-left coordinates.
    var rowAt: ((CGPoint) -> UUID?)?
    var onRowDragBegan: ((UUID) -> Void)?
    var onRowDragged: ((CGPoint) -> Void)?
    var onRowDragEnded: (() -> Void)?
    private var pendingRow: (event: NSEvent, id: UUID)?
    private var draggingRow = false

    // A press on a row is held back until we know what it is: a drag moves the
    // row, a click is replayed so it edits the text or checks the item off.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Selecting text in the field you're typing in stays a text drag.
            if let id = rowAt?(point(event)), !(isKeyWindow && hitsFieldEditor(event)) {
                pendingRow = (event, id)
                draggingRow = false
                return
            }
            press(event)
        case .leftMouseDragged where pendingRow != nil:
            guard let pending = pendingRow else { return }
            let a = pending.event.locationInWindow, b = event.locationInWindow
            if !draggingRow, hypot(b.x - a.x, b.y - a.y) >= 4 {
                draggingRow = true
                NSCursor.closedHand.push()
                onRowDragBegan?(pending.id)
            }
            if draggingRow { onRowDragged?(point(event)) }
        case .leftMouseUp where pendingRow != nil:
            guard let pending = pendingRow else { return }
            pendingRow = nil
            if draggingRow {
                draggingRow = false
                NSCursor.pop()
                onRowDragEnded?()
            } else {
                // A text field tracks the click itself, waiting for the release,
                // so the release goes back in the queue before the press is replayed.
                NSApp.postEvent(event, atStart: true)
                press(pending.event)
            }
        default:
            super.sendEvent(event)
        }
    }

    // Clicks on a text field go straight to it (AppKit routes them past the
    // hosting view), so this is where the keyboard is let in.
    private func press(_ event: NSEvent) {
        if !isKeyWindow, let frameView = contentView?.superview,
           isTextEditor(frameView.hitTest(event.locationInWindow)) {
            allowKey = true
            makeKey()
        }
        super.sendEvent(event)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        guard let view = contentView else { return .zero }
        var p = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        return p
    }

    private func hitsFieldEditor(_ event: NSEvent) -> Bool {
        contentView?.superview?.hitTest(event.locationInWindow) is NSTextView
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
    var currentWidth: (() -> CGFloat)?
    var onWidth: ((CGFloat) -> Void)?
    private enum Mode {
        case undecided, moving, resizing(scale: CGFloat, width: CGFloat), widening(width: CGFloat, scale: CGFloat)
    }
    private var pending: (event: NSEvent, mouse: NSPoint, origin: NSPoint)?
    private var mode = Mode.undecided

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A press is held back until we know what it is: the grip resizes, other
    // drags move the window, plain clicks are replayed to SwiftUI.
    override func mouseDown(with event: NSEvent) {
        pending = (event, NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        if isResizeZone?(p) == true {
            mode = .resizing(scale: currentScale?() ?? 1, width: bounds.width)
        } else if p.x >= bounds.width - WidthEdge.thickness {
            mode = .widening(width: currentWidth?() ?? 300, scale: currentScale?() ?? 1)
        } else {
            mode = .undecided
        }
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
        case let .widening(width, scale):
            onWidth?(width + dx / scale)
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
        case .moving, .resizing, .widening:
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
        applyAppearance()

        host = HUDHostingView(rootView: TodayView(model: model))
        host.sizingOptions = []
        host.currentScale = { [weak self] in self?.model.scale ?? 1 }
        host.onResize = { [weak self] in
            self?.model.scale = min(max($0, TodayModel.scaleRange.lowerBound), TodayModel.scaleRange.upperBound)
        }
        host.currentWidth = { [weak self] in self?.model.width ?? 300 }
        host.onWidth = { [weak self] in
            self?.model.width = min(max($0, TodayModel.widthRange.lowerBound), TodayModel.widthRange.upperBound)
        }
        host.isResizeZone = { [weak self] p in
            guard let grip = self?.model.gripRect, !grip.isEmpty else { return false }
            return grip.insetBy(dx: -4, dy: -4).contains(p)
        }
        host.onDragEnded = { [weak self] in self?.saveFrame() }
        panel.rowAt = { [weak self] in self?.model.row(at: $0) }
        panel.onRowDragBegan = { [weak self] id in
            withAnimation(.easeOut(duration: 0.15)) { self?.model.draggingId = id }
        }
        panel.onRowDragged = { [weak self] in self?.model.drag(to: $0) }
        panel.onRowDragEnded = { [weak self] in
            withAnimation(.easeOut(duration: 0.15)) { self?.model.draggingId = nil }
        }
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
        model.$theme.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &subscriptions)
        registerHotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in self?.toggleHUD() }

        setupStatusItem()
        model.start()
        updateVisibility()
    }

    /// Menus and text-field chrome follow the card: light on Paper, dark otherwise.
    private func applyAppearance() {
        panel.appearance = NSAppearance(named: model.theme.isLight ? .aqua : .darkAqua)
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
            // SwiftUI parks the cursor in the first field on its own, which shows a
            // stray selection; nothing should be focused until you click in.
            DispatchQueue.main.async { [weak self] in self?.panel.makeFirstResponder(nil) }
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
        // While something is pinned as "now", the menu bar shows it instead of the count.
        let now = model.nowItem.map { $0.text.count > 30 ? $0.text.prefix(29) + "…" : $0.text }
        let title = now.map { " \($0)" } ?? (total == 0 ? "" : " \(model.doneCount)/\(total)")
        let symbol = now != nil ? "circle.lefthalf.filled" : model.allDone ? "checklist.checked" : "checklist"
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

    @objc func clearNow() { if let id = model.nowItem?.id { model.setNow(id) } }

    @objc func toggleItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.toggle(id)
    }

    @objc func setSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? HUDSize else { return }
        model.scale = size.scale
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = ThemeChoice(rawValue: raw) else { return }
        model.theme = theme
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
        if let now = model.nowItem {
            let entry = NSMenuItem(title: "Stop Working on “\(now.text)”", action: #selector(clearNow), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        for item in model.items {
            let entry = NSMenuItem(title: item.text, action: #selector(toggleItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.state = item.done ? .on : item.id == model.nowItem?.id ? .mixed : .off
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

        let colors = NSMenu()
        for theme in ThemeChoice.allCases {
            let item = NSMenuItem(title: theme.label, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = model.theme == theme ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

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
    let file = Store.load()
    for item in file.items { print(item.done ? "[x]" : item.id == file.now ? "[>]" : "[ ]", item.text) }
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
