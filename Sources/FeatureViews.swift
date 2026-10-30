import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Open island with tabs

@MainActor
struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        VStack(spacing: 0) {
            if layout.hasNotch {
                OpenStatusRow(model: model, layout: layout)   // clock / battery beside the camera
            } else {
                Color.clear.frame(height: 10)
            }

            IslandTabBar(model: model)
                .frame(height: 30)

            Group {
                switch model.openTab {
                case .music: MusicTabView(model: model)
                case .agenda: AgendaTabView(model: model)
                case .prayer: PrayerTabView(model: model)
                case .focus: FocusTabView(model: model)
                case .shelf: ShelfTabView(model: model)
                case .clipboard: ClipboardTabView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 8)
        // Files can be dropped anywhere on the open island.
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
            ExpandedView.acceptDrop(providers, into: model)
        }
    }

    /// Loads the dropped file URLs (on a background queue) and adds them to the shelf.
    nonisolated static func acceptDrop(_ providers: [NSItemProvider], into model: IslandModel) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL else { return }
                Task { @MainActor in
                    model.addToShelf([url])
                }
            }
        }
        return accepted
    }
}

@MainActor
struct IslandTabBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                let selected = model.openTab == tab
                Button(action: { model.openTab = tab }) {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        if selected {
                            Text(label(for: tab))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    .foregroundColor(selected ? .white : Color.white.opacity(0.5))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0)))
                    .overlay(alignment: .topTrailing) {
                        if !selected && hasActivity(tab) {
                            Circle()
                                .fill(activityColor(tab))
                                .frame(width: 5, height: 5)
                                .offset(x: -3, y: 3)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.openTab)
    }

    private func label(for tab: IslandTab) -> String {
        if tab == .shelf && !model.shelf.isEmpty { return "Shelf \(model.shelf.count)" }
        return tab.title
    }

    private func hasActivity(_ tab: IslandTab) -> Bool {
        switch tab {
        case .music: return model.track?.isPlaying == true
        case .agenda: return model.meetingAlert != nil
        case .prayer: return model.prayerAlert != nil
        case .focus: return model.focus != nil
        case .shelf: return !model.shelf.isEmpty
        case .clipboard: return false
        }
    }

    private func activityColor(_ tab: IslandTab) -> Color {
        switch tab {
        case .music: return model.accent
        case .agenda: return NoticeTint.blue.color
        case .prayer: return NoticeTint.yellow.color
        case .focus: return model.focus?.tint ?? .white
        case .shelf: return .white
        case .clipboard: return .white
        }
    }
}

// MARK: - Prayer tab

@MainActor
struct PrayerTabView: View {
    @ObservedObject var model: IslandModel

    private var highlight: Color { NoticeTint.yellow.color }

    var body: some View {
        if !model.prayerEnabled {
            VStack(spacing: 10) {
                Text("Jadwal sholat sedang dimatikan")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.6))
                CapsuleButton(title: "Aktifkan", symbol: "moon.stars.fill", prominent: true) {
                    model.prayerEnabled = true
                }
            }
        } else {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headerTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.55))
                        if let target = target {
                            HStack(spacing: 6) {
                                Image(systemName: target.prayer.symbol)
                                    .foregroundColor(highlight)
                                Text("\(target.prayer.name)  \(target.time.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    if let alert = model.prayerAlert {
                        VStack(alignment: .trailing, spacing: 6) {
                            if alert.isNow {
                                Text("Sekarang")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(highlight)
                            } else {
                                TimelineView(.periodic(from: Date(), by: 1)) { context in
                                    Text("-" + Countdown.text(alert.time.timeIntervalSince(context.date)))
                                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                        .foregroundColor(highlight)
                                }
                            }
                            CapsuleButton(title: "Oke", symbol: "checkmark", prominent: true) {
                                model.dismissPrayer()
                            }
                        }
                    } else if let next = model.nextPrayer {
                        TimelineView(.periodic(from: Date(), by: 1)) { context in
                            Text(Countdown.text(next.time.timeIntervalSince(context.date)))
                                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundColor(.white)
                        }
                    }
                }

                HStack(spacing: 0) {
                    ForEach(model.prayerTimes, id: \.prayer) { item in
                        let isTarget = item.key == target?.key
                        VStack(spacing: 3) {
                            Text(item.prayer.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isTarget ? highlight : Color.white.opacity(0.5))
                            Text(item.time.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundColor(isTarget ? .white : Color.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    /// The prayer being counted down to (or that has just started).
    private var target: PrayerTime? {
        if let alert = model.prayerAlert { return PrayerTime(prayer: alert.prayer, time: alert.time) }
        return model.nextPrayer
    }

    private var headerTitle: String {
        let city = model.prayerCityName
        if let alert = model.prayerAlert {
            return alert.isNow ? "Sudah masuk waktu · \(city)" : "Sebentar lagi · \(city)"
        }
        return "Berikutnya · \(city)"
    }
}

// MARK: - Focus tab

@MainActor
struct FocusTabView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let session = model.focus
            let remaining = session?.remaining(at: context.date) ?? TimeInterval(model.focusMinutes * 60)
            let progress = session?.progress(at: context.date) ?? 0
            let tint = session?.tint ?? Color(red: 1.0, green: 0.62, blue: 0.22)

            HStack(spacing: 20) {
                ZStack {
                    FocusRing(progress: progress, tint: tint, lineWidth: 6)
                    Text(Countdown.text(remaining))
                        .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: session))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text(subtitle(for: session))
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                    }

                    if session == nil {
                        HStack(spacing: 6) {
                            ForEach([15, 25, 45, 60], id: \.self) { minutes in
                                let selected = model.focusMinutes == minutes
                                Button(action: { model.focusMinutes = minutes }) {
                                    Text("\(minutes)m")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundColor(selected ? .black : .white)
                                        .frame(width: 40, height: 22)
                                        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.12)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        primaryButton(for: session)
                        if session != nil {
                            CapsuleButton(title: "Berhenti", symbol: "stop.fill") { model.stopFocus() }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func primaryButton(for session: FocusSession?) -> some View {
        if let session = session {
            if session.isRunning {
                CapsuleButton(title: "Jeda", symbol: "pause.fill", prominent: true) { model.pauseFocus() }
            } else {
                CapsuleButton(title: "Lanjut", symbol: "play.fill", prominent: true) { model.resumeFocus() }
            }
        } else {
            CapsuleButton(title: "Mulai", symbol: "play.fill", prominent: true) { model.startFocus() }
        }
    }

    private func title(for session: FocusSession?) -> String {
        guard let session = session else { return "Timer fokus" }
        return session.phase == .focus ? "Fokus" : "Istirahat"
    }

    private func subtitle(for session: FocusSession?) -> String {
        guard let session = session else { return "Pilih durasi, lalu mulai" }
        if !session.isRunning { return "Dijeda" }
        return session.phase == .focus ? "Istirahat 5 menit setelah ini" : "Rehat sebentar dari layar"
    }
}

// MARK: - Shelf tab

@MainActor
struct ShelfTabView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.shelf.isEmpty {
            VStack(spacing: 6) {
                if model.mascot != .off {
                    MascotView(model: model, size: 32)   // opens its mouth while a file hovers
                } else {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .medium))
                }
                Text(dropHint)
                    .font(.system(size: 12, weight: .medium))
                Text("Lalu seret keluar ke app lain, atau kirim lewat AirDrop")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.45))
            }
            .foregroundColor(Color.white.opacity(model.isDropTargeted ? 0.95 : 0.65))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropOutline)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.shelf, id: \.self) { url in
                            ShelfTile(model: model, url: url)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }
                .frame(height: 94)
                .background(dropOutline)
                .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    if model.availableUpdate != nil || model.isUpdating {
                        CapsuleButton(title: model.isUpdating ? "Memasang…" : "Pasang update",
                                      symbol: "arrow.down.app.fill", prominent: true) {
                            model.installUpdate()
                        }
                    }
                    CapsuleButton(title: "AirDrop", symbol: "square.and.arrow.up",
                                  prominent: model.availableUpdate == nil && !model.isUpdating) {
                        model.airDrop(model.shelf)
                    }
                    CapsuleButton(title: "Kosongkan", symbol: "trash") { model.clearShelf() }
                    Spacer(minLength: 4)
                    Text("Seret keluar untuk memindahkan")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
                .padding(.horizontal, 18)
            }
            .padding(.top, 4)
        }
    }

    private var dropHint: String {
        if model.isDropTargeted && model.mascot != .off {
            return "Lepaskan, biar \(model.mascot.shortName) yang simpan"
        }
        return "Seret file ke notch untuk menyimpannya di sini"
    }

    private var dropOutline: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(model.isDropTargeted ? 0.7 : 0.16),
                          style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(model.isDropTargeted ? 0.08 : 0)))
    }
}

@MainActor
struct ShelfTile: View {
    @ObservedObject var model: IslandModel
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 68)
        }
        .frame(width: 74, height: 78)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            Button(action: { model.removeFromShelf(url) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.55))
            }
            .buttonStyle(PressScaleStyle())
        }
        .onTapGesture(count: 2) { model.openFile(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Buka") { model.openFile(url) }
            Button("Tampilkan di Finder") { model.revealInFinder(url) }
            Button("Kirim lewat AirDrop") { model.airDrop([url]) }
            if Updater.isUpdateZip(url) {
                Button("Pasang sebagai update DynaIsland") { model.installUpdate(from: url) }
            }
            Divider()
            Button("Hapus dari shelf") { model.removeFromShelf(url) }
        }
        .help(url.path)
    }
}

// MARK: - Compact states for the new features

/// Focus running: progress ring left of the camera, time left on the right.
@MainActor
struct FocusCompactView: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let session = model.focus
            let remaining = session?.remaining(at: context.date) ?? 0
            let progress = session?.progress(at: context.date) ?? 0
            let tint = session?.tint ?? .white
            let paused = session?.isRunning == false

            HStack(spacing: 0) {
                ZStack {
                    FocusRing(progress: progress, tint: tint, lineWidth: 2.5)
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(tint)
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: layout.hasNotch ? IslandLayout.wing : nil)

                Spacer(minLength: layout.hasNotch ? layout.notchWidth : 8)

                Text(Countdown.text(remaining))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(paused ? Color.white.opacity(0.5) : .white)
                    .frame(width: layout.hasNotch ? IslandLayout.wing : nil)
            }
            .padding(.horizontal, layout.hasNotch ? 0 : 9)
        }
    }
}

/// Prayer countdown: name left of the camera, countdown on the right.
struct PrayerCompactView: View {
    let alert: PrayerAlert
    let layout: IslandLayout

    var body: some View {
        let tint = NoticeTint.yellow.color
        HStack(spacing: 8) {
            Image(systemName: alert.prayer.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            Text(alert.isNow ? "Waktu \(alert.prayer.name)" : alert.prayer.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: layout.hasNotch ? layout.notchWidth + 12 : 6)
            if alert.isNow {
                Text("Sekarang")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text("-" + Countdown.text(alert.time.timeIntervalSince(context.date)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(tint)
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Small building blocks

struct FocusRing: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.001, min(1, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

struct CapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(prominent ? .black : .white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}
