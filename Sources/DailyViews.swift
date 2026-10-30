import AppKit
import SwiftUI

// MARK: - Agenda tab

@MainActor
struct AgendaTabView: View {
    @ObservedObject var model: IslandModel

    private var tint: Color { NoticeTint.blue.color }

    var body: some View {
        if !model.meetingEnabled {
            AgendaMessage(symbol: "calendar", title: "Pengingat meeting sedang dimatikan", detail: nil) {
                CapsuleButton(title: "Aktifkan", symbol: "calendar", prominent: true) {
                    model.meetingEnabled = true
                    model.calendar?.settingsChanged()
                }
            }
        } else if model.calendarAccess != .granted {
            AgendaMessage(symbol: "calendar.badge.exclamationmark",
                          title: "Izinkan DynaIsland membaca Kalender",
                          detail: "Untuk hitung mundur meeting dan tombol Gabung. Datanya tidak keluar dari Mac.") {
                CapsuleButton(title: model.calendarAccess == .denied ? "Buka pengaturan" : "Izinkan",
                              symbol: "lock.open.fill", prominent: true) {
                    model.calendar?.requestAccess()
                }
            }
        } else if let next = nextTimed ?? model.agenda.first {
            VStack(spacing: 8) {
                header(for: next)
                    .padding(.horizontal, 20)
                let rest = model.agenda.filter { $0.id != next.id }
                if rest.isEmpty {
                    Text("Tidak ada acara lain hari ini dan besok")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(rest) { item in
                                AgendaRow(model: model, item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 6)
        } else {
            AgendaMessage(symbol: "calendar", title: "Tidak ada acara lagi hari ini dan besok",
                          detail: "Acara dari app Calendar (iCloud, Google, Outlook) muncul di sini.") {
                EmptyView()
            }
        }
    }

    /// The next event with a start time (all-day events are only listed).
    private var nextTimed: MeetingInfo? {
        model.agenda.first { !$0.isAllDay }
    }

    @ViewBuilder
    private func header(for item: MeetingInfo) -> some View {
        let alert = model.meetingAlert
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerLabel(for: item))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.55))
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(AgendaRow.timeText(for: item) + (item.location.map { "  ·  " + $0 } ?? ""))
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.isAllDay {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        let left = item.start.timeIntervalSince(context.date)
                        Text(left > 0 ? Countdown.text(left) : "Berlangsung")
                            .font(.system(size: left > 0 ? 18 : 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(alert != nil ? tint : .white)
                    }
                }
                HStack(spacing: 6) {
                    if let url = item.joinURL {
                        CapsuleButton(title: "Gabung", symbol: "video.fill", prominent: true) { model.join(url) }
                    }
                    if alert?.key == item.id {
                        CapsuleButton(title: "Oke", symbol: "checkmark") { model.dismissMeeting() }
                    }
                }
            }
        }
    }

    private func headerLabel(for item: MeetingInfo) -> String {
        if item.isAllDay { return "Hari ini · seharian" }
        if item.start <= Date() { return "Sedang berlangsung" }
        if model.meetingAlert?.key == item.id { return "Sebentar lagi" }
        return Calendar.current.isDateInTomorrow(item.start) ? "Besok" : "Berikutnya"
    }
}

/// Icon, title, optional detail and a button, centred in the tab.
struct AgendaMessage<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Color.white.opacity(0.7))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            action()
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
struct AgendaRow: View {
    @ObservedObject var model: IslandModel
    let item: MeetingInfo

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(item.color)
                .frame(width: 6, height: 6)
            Text(AgendaRow.timeText(for: item))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 92, alignment: .leading)
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let url = item.joinURL {
                Button(action: { model.join(url) }) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 18)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(PressScaleStyle())
                .help("Gabung")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// "Besok 09.00" / "14.30–15.00" / "Seharian".
    static func timeText(for item: MeetingInfo) -> String {
        let tomorrow = Calendar.current.isDateInTomorrow(item.start)
        if item.isAllDay { return tomorrow ? "Besok, seharian" : "Seharian" }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        if tomorrow { return "Besok \(start)" }
        return "\(start)–\(item.end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Meeting soon: title left of the camera, countdown on the right.
struct MeetingCompactView: View {
    let alert: MeetingAlert
    let layout: IslandLayout

    var body: some View {
        let tint = NoticeTint.blue.color
        HStack(spacing: 8) {
            Image(systemName: alert.joinURL != nil ? "video.fill" : "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            Text(alert.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: layout.hasNotch ? layout.notchWidth + 12 : 6)
            if alert.isNow {
                Text("Mulai")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text("-" + Countdown.text(alert.start.timeIntervalSince(context.date)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(tint)
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Clipboard tab

@MainActor
struct ClipboardTabView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if !model.clipboardEnabled {
            AgendaMessage(symbol: "doc.on.clipboard", title: "Riwayat clipboard sedang dimatikan", detail: nil) {
                CapsuleButton(title: "Aktifkan", symbol: "doc.on.clipboard", prominent: true) {
                    model.clipboardEnabled = true
                }
            }
        } else if model.clips.isEmpty {
            AgendaMessage(symbol: "doc.on.clipboard",
                          title: "Teks dan gambar yang kamu copy muncul di sini",
                          detail: "Klik untuk copy lagi. Hanya disimpan di memori dan hilang saat app ditutup. Password dari password manager tidak dicatat.") {
                EmptyView()
            }
        } else {
            VStack(spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(model.clips) { item in
                            ClipRow(model: model, item: item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
                HStack(spacing: 8) {
                    Text("\(model.clips.count) item · klik untuk copy lagi")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.4))
                    Spacer(minLength: 4)
                    CapsuleButton(title: "Bersihkan", symbol: "trash") { model.clearClips() }
                }
                .padding(.horizontal, 18)
            }
        }
    }
}

@MainActor
struct ClipRow: View {
    @ObservedObject var model: IslandModel
    let item: ClipItem

    var body: some View {
        Button(action: { model.copyClip(item) }) {
            HStack(spacing: 8) {
                preview
                Spacer(minLength: 4)
                if model.copiedClipID == item.id {
                    Label("Disalin", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NoticeTint.green.color)
                } else {
                    Text(ClipRow.age(of: item.date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            Button("Copy") { model.copyClip(item) }
            Button("Hapus dari riwayat") { model.removeClip(item.id) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 14)
                Text(ClipRow.oneLine(text))
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .image(let image):
            HStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("Gambar \(Int(image.size.width))×\(Int(image.size.height))")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
    }

    /// First 160 characters with line breaks and runs of spaces collapsed.
    static func oneLine(_ text: String) -> String {
        let words = text.prefix(400).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(160))
    }

    static func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "baru saja" }
        if seconds < 3600 { return "\(seconds / 60) mnt" }
        return "\(seconds / 3600) j"
    }
}
