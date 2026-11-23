import Foundation

// The glasses keep their own timers, alarms, reminders and calendar events (their "tar" scheduler) and chime timers
// and alarms without the phone. The phone hands them the whole list in one message, 1100 (TARSyncRequest). The
// glasses queue "clear every slot", then decode the list into at most eight volatile slots (gone when they restart).
// ReGlass sends running timers only.
//
// Send 1100 on the svc15 assistant message channel. It has no reply. To clear all timers, still include the
// session field because the glasses reject an empty payload before clearing the slots.
// When a slot rings, the glasses chime and send a timer alert in assistant turn message 6, even without
// an open turn. The glasses open svc53210 separately and read message 11 there.
//
// The batch holds repeated records in field 1 and a session string of up to 63 bytes in field 2.
// Record fields are id (1, up to 127 bytes), type (2), two uint64s (3 and 4), a submessage (5), title
// (6, up to 255 bytes), disabled (7), completed (8), dismissed time (9), and a trigger. The trigger is a
// oneof with absolute (100, epoch ms in field 1), relative (101, duration ms in field 1, start epoch ms
// in field 2, unknown fields 3 and 4, state in field 5) and weekly (102) variants.
//
// A relative timer whose start + duration is still ahead runs for the time left. If it's 0–5 s late it fires at
// once, 5–120 s late it's dropped, and more than 120 s late (or with no valid clock) it runs its full duration.
// This is why every list leaves out timers already due. GlassesConnection sets the glasses'
// clock to the phone's at every connect, so the start time stays the moment the timer was set, however late the list
// goes out. TIMER (type 1) accepts relative state 1 (running) only.
enum TimerListMessages {
    /// TARSyncRequest, on svc15's message channel.
    static let syncType = 1100
    /// The glasses hold at most this many records.
    static let maxRecords = 8

    static let typeTimer: Int64 = 1
    static let relativeRunning: Int64 = 1

    /// One running timer: `{1 id, 2 type 1, 6 title, 101 {1 duration ms, 2 start epoch ms, 5 state 1}}`.
    static func runningTimer(id: String, title: String, durationMs: Int64, startEpochMs: Int64) -> [UInt8] {
        let trigger = Wire.fieldVarintUnsigned(1, durationMs)
            + Wire.fieldVarintUnsigned(2, startEpochMs)
            + Wire.fieldVarintUnsigned(5, relativeRunning)
        return Wire.fieldBytes(1, Array(fitting(id, bytes: 127).utf8))
            + Wire.fieldVarintUnsigned(2, typeTimer)
            + Wire.fieldBytes(6, Array(fitting(title, bytes: 255).utf8))
            + Wire.fieldBytes(101, trigger)
    }

    /// The whole list: every record as field 1, then the session string (a lowercase UUID, 36 characters).
    /// With no records it clears every slot; the session field keeps the payload non-empty, which the decoder needs.
    static func list(_ records: [[UInt8]], session: String = UUID().uuidString.lowercased()) -> [UInt8] {
        records.flatMap { Wire.fieldBytes(1, $0) } + Wire.fieldBytes(2, Array(fitting(session, bytes: 63).utf8))
    }

    static func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// `text` cut to whole characters fitting `bytes` UTF-8 bytes (the firmware's buffers keep one byte for NUL).
    static func fitting(_ text: String, bytes: Int) -> String {
        var out = ""
        for character in text {
            if out.utf8.count + String(character).utf8.count > bytes { break }
            out.append(character)
        }
        return out
    }
}
