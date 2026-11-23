import SwiftUI

/// Settings → Developer → Activity log: the lines ReGlass writes to `Storage.eventsFile`, oldest first and newest at
/// the bottom, with a filter and an Export button that shares the file. Shown only once Version has been tapped five
/// times on the Developer screen.
///
/// The file is read off the main thread by `LogReader`, which keeps its place and reads only what was added, so the
/// live reload every two seconds costs a file-size check while nothing new is written. New lines scroll into view while
/// the end is in view; after scrolling up, they wait, and a Newest button brings the end back.
struct LogsView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reader = LogReader()
    @State private var log = LogReader.Snapshot()
    @State private var loaded = false
    @State private var files: [URL] = []
    @State private var query = ""
    /// True while the end of the log is in view, so new lines scroll in. Scrolling up turns it off until the end is back.
    @State private var following = true
    /// Counts the snapshots shown, so each new one can bring the end into view.
    @State private var revision = 0

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            ScrollViewReader { proxy in
                List {
                    if !log.rows.isEmpty {
                        Section {
                            ForEach(log.rows) { row in
                                LogRowView(row: row)
                                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text(summary)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .onScrollPhaseChange { _, phase, context in
                    // Only once a scroll has settled, so the list growing at the bottom never counts as scrolling up.
                    guard phase == .idle else { return }
                    following = Self.atEnd(context.geometry)
                }
                .onChange(of: revision) { old, _ in
                    guard following, let last = log.rows.last?.id else { return }
                    if old == 0 || reduceMotion {
                        proxy.scrollTo(last, anchor: .bottom)
                    } else {
                        withAnimation(.smooth) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .overlay { emptyState }
                .overlay(alignment: .bottom) { newestButton(proxy) }
                .animation(.smooth, value: following)
            }
        }
        .navigationTitle("Activity Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: files, subject: Text("ReGlass log")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(files.isEmpty)
                .accessibilityLabel("Export log")
            }
        }
        // Live while the screen is open and ReGlass is in front; the loop ends when either stops.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        // A short pause while typing, then the filter runs (off the main thread, in the reader).
        .task(id: query) {
            guard loaded else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            following = true
            await load()
        }
    }

    private func load() async {
        guard let snapshot = await reader.read(filter: query) else { return }
        log = snapshot
        files = glasses.log.shareableFiles()
        loaded = true
        revision += 1
    }

    /// The end is in view: the bottom of what shows is within a little of the bottom of the content.
    private static func atEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
            >= geometry.contentSize.height - 72
    }

    private var summary: String {
        let total = Self.lines(log.lineCount)
        if log.filter.isEmpty {
            return total + " · " + Int64(log.byteCount).formatted(.byteCount(style: .file))
        }
        return "\(log.matchCount.formatted()) of " + total
    }

    private static func lines(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count.formatted()) lines"
    }

    @ViewBuilder private var emptyState: some View {
        if !loaded {
            ArcSpinner(size: 24)
        } else if log.rows.isEmpty {
            if log.filter.isEmpty {
                ContentUnavailableView("No Log Yet", systemImage: "doc.text",
                                       description: Text("ReGlass writes here as it works."))
            } else {
                ContentUnavailableView.search(text: log.filter)
            }
        }
    }

    @ViewBuilder private func newestButton(_ proxy: ScrollViewProxy) -> some View {
        if !following, let last = log.rows.last?.id {
            Button {
                following = true
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(last, anchor: .bottom) }
            } label: {
                Label("Newest", systemImage: "arrow.down")
            }
            .buttonStyle(CompactPillStyle())
            .padding(.bottom, 8)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One row: a day heading, or a line with its time in a narrow column and the words wrapping beside it. At
/// accessibility text sizes the time sits above the words instead.
private struct LogRowView: View {
    let row: LogRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch row.kind {
        case .day(let label):
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        case .line(let time, let text):
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                                      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                if !time.isEmpty {
                    Text(time)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(text)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
        }
    }
}

/// What the log screen shows: a day heading, or one line.
struct LogRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case day(String)
        case line(time: String, text: String)
    }

    let id: Int
    let kind: Kind
}

/// Reads `Storage.eventsFile` off the main thread and keeps its place: each read takes only the whole lines added
/// since the last one. When `ActivityLog` starts the file over (past 2 MB), it starts over too. Reads only; writing
/// stays with `ActivityLog`.
actor LogReader {
    /// The lines to show for a filter, with the counts for the header.
    struct Snapshot: Sendable {
        var rows: [LogRow] = []
        var lineCount = 0
        var matchCount = 0
        var byteCount: UInt64 = 0
        /// The filter these rows match, trimmed; empty for every line.
        var filter = ""
    }

    /// One line of the file, split into its time stamp and its words.
    private struct Line: Sendable {
        let id: Int
        /// yyyy-MM-dd, or nil for a line without a stamp.
        let day: String?
        /// HH:mm:ss.SSS, or empty.
        let time: String
        let text: String
    }

    private let file: URL
    private var lines: [Line] = []
    /// Bytes read so far: always the end of a whole line.
    private var offset: UInt64 = 0
    /// Which file the lines came from, so a new file (the log starting over) is noticed.
    private var fileNumber: UInt64?
    /// Never reused, also across a new file, so the list never mistakes a new line for an old one.
    private var nextID = 0
    /// The filter of the last snapshot handed out; nil before the first.
    private var delivered: String?
    private var dayLabels: [String: String] = [:]

    init(file: URL = Storage.eventsFile) {
        self.file = file
    }

    /// The rows for `filter`, or nil when neither the file nor the filter changed since the last snapshot.
    func read(filter: String) -> Snapshot? {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = readNewLines()
        if !changed, delivered == needle { return nil }
        delivered = needle
        return snapshot(needle)
    }

    private func readNewLines() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            // No file yet, or it was just removed to start over.
            return clear()
        }
        var changed = false
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if number != fileNumber || size < offset {
            changed = clear()
            fileNumber = number
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return changed }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return changed }
        // Whole lines only: a line still being written waits for the next read.
        let whole = data[data.startIndex...end]
        offset += UInt64(whole.count)
        for bytes in whole.split(separator: UInt8(ascii: "\n")) {
            lines.append(parse(bytes))
        }
        return true
    }

    /// Forgets the lines read; true if there were any.
    private func clear() -> Bool {
        let had = !lines.isEmpty || offset > 0
        lines.removeAll()
        offset = 0
        fileNumber = nil
        return had
    }

    /// "yyyy-MM-dd HH:mm:ss.SSS  words", as `ActivityLog` writes each line. Anything else is kept whole, without a time.
    private func parse(_ bytes: Data) -> Line {
        defer { nextID += 1 }
        let s = bytes.startIndex
        if bytes.count >= 25, bytes[s + 4] == UInt8(ascii: "-"), bytes[s + 10] == UInt8(ascii: " "),
           bytes[s + 23] == UInt8(ascii: " "), bytes[s + 24] == UInt8(ascii: " ") {
            return Line(id: nextID,
                        day: String(decoding: bytes[s..<s + 10], as: UTF8.self),
                        time: String(decoding: bytes[(s + 11)..<(s + 23)], as: UTF8.self),
                        text: String(decoding: bytes[(s + 25)...], as: UTF8.self))
        }
        return Line(id: nextID, day: nil, time: "", text: String(decoding: bytes, as: UTF8.self))
    }

    private func snapshot(_ needle: String) -> Snapshot {
        var rows: [LogRow] = []
        rows.reserveCapacity(needle.isEmpty ? lines.count + 8 : 64)
        var matches = 0
        var day: String?
        for line in lines {
            if !needle.isEmpty, !line.time.hasPrefix(needle),
               line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                continue
            }
            // A heading wherever the day changes among the lines shown.
            if let lineDay = line.day, lineDay != day {
                day = lineDay
                rows.append(LogRow(id: -1 - line.id, kind: .day(dayLabel(lineDay))))
            }
            rows.append(LogRow(id: line.id, kind: .line(time: line.time, text: line.text)))
            matches += 1
        }
        return Snapshot(rows: rows, lineCount: lines.count, matchCount: matches, byteCount: offset, filter: needle)
    }

    /// "Saturday, 14 November 2026" for "2026-11-14", in this iPhone's language. The stamps are local time.
    private func dayLabel(_ day: String) -> String {
        if let label = dayLabels[day] { return label }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var label = day
        if parts.count == 3,
           let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
            label = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
        dayLabels[day] = label
        return label
    }
}
