import CoreData
import Foundation

/// Pure helpers for the one-tap meal preset buttons on the Treatments screen.
/// No state, no I/O, no Core Data writes: unit tests call these directly.
enum MealPresetQuickAdd {
    /// Same limit the Note text field enforces on typed input (`maxLength: 25` in `TreatmentsRootView`).
    static let noteMaxLength = 25

    /// Same order as the "Saved Food" picker in `MealPresetView`: Core Data sort on `dish`, ascending.
    static var sortDescriptors: [NSSortDescriptor] {
        [NSSortDescriptor(key: "dish", ascending: true)]
    }

    struct Display: Equatable {
        /// The emoji a name starts with, or the first character of the name (uppercased), or "?" for an empty name.
        let icon: String
        /// The text under the icon: the name without its leading emoji.
        let label: String
        /// True when `icon` is a leading emoji taken from the name (drawn as is, not as a letter in a circle).
        let iconIsEmoji: Bool
    }

    /// Splits a preset name into an icon and a label, without any data model change:
    /// "🥤 keto fuel" -> ("🥤", "keto fuel"); "bp bar" -> ("B", "bp bar").
    static func display(for name: String?) -> Display {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return Display(icon: "?", label: "", iconIsEmoji: false)
        }
        if isEmoji(first) {
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return Display(icon: String(first), label: rest, iconIsEmoji: true)
        }
        return Display(icon: String(first).uppercased(), label: trimmed, iconIsEmoji: false)
    }

    /// A preset's name as it appears in the note: without its leading emoji. A name that is only an emoji is used as is.
    static func noteName(for name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = display(for: trimmed)
        return (shown.iconIsEmoji && !shown.label.isEmpty) ? shown.label : trimmed
    }

    /// The note for a single preset, cut to the Note field's length.
    static func noteTag(for name: String?) -> String {
        String(noteName(for: name).prefix(noteMaxLength))
    }

    /// One tap on a preset button: `key` identifies the preset (for the badge), `name` is its dish name (for the note).
    struct Tap: Equatable {
        let key: String
        let name: String
    }

    /// How many times the preset with this key was tapped.
    static func count(of key: String, in taps: [Tap]) -> Int {
        taps.filter { $0.key == key }.count
    }

    /// The badge on a button: nothing for zero or one tap, then "×2", "×3", ...
    static func badgeLabel(count: Int) -> String? {
        count > 1 ? "×\(count)" : nil
    }

    /// The note for a list of taps: names (leading emoji stripped) in first-tap order, joined with " + ",
    /// repeats as "keto fuel x2", cut to the Note field's length.
    static func composeNote(names: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in names {
            let tag = noteName(for: name)
            guard !tag.isEmpty else { continue }
            if counts[tag] == nil { order.append(tag) }
            counts[tag, default: 0] += 1
        }
        let parts = order.map { tag -> String in
            let count = counts[tag] ?? 1
            return count > 1 ? "\(tag) x\(count)" : tag
        }
        return String(parts.joined(separator: " + ").prefix(noteMaxLength))
    }

    /// The quick buttons may write the note only when it is empty or still exactly what they wrote last.
    static func mayWriteNote(current: String, lastWritten: String?) -> Bool {
        current.isEmpty || current == lastWritten
    }

    /// The Carbs / Fat / Protein field values after one serving of a preset is added. This is the net effect
    /// of `MealPresetView` for one serving: its picker adds the preset's carbs (and fat and protein only when
    /// fat/protein entry is on) to a running total, and "Add to Treatments" adds that total to the fields.
    static func totals(
        current: (carbs: Decimal, fat: Decimal, protein: Decimal),
        adding preset: (carbs: Decimal, fat: Decimal, protein: Decimal),
        useFPUconversion: Bool
    ) -> (carbs: Decimal, fat: Decimal, protein: Decimal) {
        (
            carbs: current.carbs + preset.carbs,
            fat: current.fat + (useFPUconversion ? preset.fat : 0),
            protein: current.protein + (useFPUconversion ? preset.protein : 0)
        )
    }

    /// True for a character that is drawn as an emoji: single emoji, flags, keycaps, skin tone and ZWJ sequences.
    /// Plain digits, "#" and "*" carry the Unicode Emoji property but are text unless followed by U+FE0F.
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && scalars.contains { $0.value == 0xFE0F }
    }
}

extension Treatments.StateModel {
    /// One-tap add of a saved meal preset. Ends in the same state as choosing the preset once in
    /// `MealPresetView` and pressing "Add to Treatments": the amounts are added to the Carbs / Fat / Protein
    /// fields, and `selection` and `summation` are left as the sheet leaves them when it closes (untouched here).
    /// Does not save, bolus or dismiss. Additions over the sheet: the tap is recorded for the "×2" badge, and
    /// the note is written when it is empty or still holds what an earlier tap wrote.
    func quickAddPreset(
        key: String? = nil,
        name: String?,
        carbs presetCarbs: Decimal,
        fat presetFat: Decimal,
        protein presetProtein: Decimal
    ) {
        let result = MealPresetQuickAdd.totals(
            current: (carbs: carbs, fat: fat, protein: protein),
            adding: (carbs: presetCarbs, fat: presetFat, protein: presetProtein),
            useFPUconversion: useFPUconversion
        )
        carbs = result.carbs
        fat = result.fat
        protein = result.protein

        // Display only from here on: nothing below feeds back into the amounts above.
        quickAddTaps.append(MealPresetQuickAdd.Tap(key: key ?? (name ?? ""), name: name ?? ""))

        if MealPresetQuickAdd.mayWriteNote(current: note, lastWritten: quickAddNoteWritten) {
            let composed = MealPresetQuickAdd.composeNote(names: quickAddTaps.map(\.name))
            note = composed
            quickAddNoteWritten = composed
        }
    }

    /// Called where the model zeroes carbs, fat and protein (`deletePreset`), so the badges never outlive the
    /// amounts they describe. Clears the note only if it is still exactly what the buttons wrote.
    func resetQuickAddTaps() {
        quickAddTaps.removeAll()
        if let written = quickAddNoteWritten, !written.isEmpty, note == written {
            note = ""
        }
        quickAddNoteWritten = nil
    }

    func quickAddPreset(_ preset: MealPresetStored) {
        quickAddPreset(
            key: MealPresetQuickAdd.key(for: preset),
            name: preset.dish,
            carbs: ((preset.carbs ?? 0) as NSDecimalNumber) as Decimal,
            fat: ((preset.fat ?? 0) as NSDecimalNumber) as Decimal,
            protein: ((preset.protein ?? 0) as NSDecimalNumber) as Decimal
        )
    }
}

extension MealPresetQuickAdd {
    static func key(for preset: MealPresetStored) -> String {
        preset.objectID.uriRepresentation().absoluteString
    }
}
