import Foundation
import Testing
@testable import Trio

@Suite("Preset Quick Buttons") struct PresetQuickButtonsTests {
    // MARK: - Icon and label

    @Test("Emoji prefix becomes the icon, the rest the label") func emojiPrefix() {
        let shown = MealPresetQuickAdd.display(for: "🥤 keto fuel")
        #expect(shown == .init(icon: "🥤", label: "keto fuel", iconIsEmoji: true))
        // No space between emoji and name
        #expect(MealPresetQuickAdd.display(for: "🥤keto fuel").label == "keto fuel")
    }

    @Test("Multi-scalar emoji stay whole", arguments: [
        "🇺🇸", // flag (two regional indicators)
        "👍🏽", // skin tone modifier
        "👨‍👩‍👧", // ZWJ sequence
        "❤️", // text symbol with emoji variation selector
        "1️⃣", // keycap
        "🏳️‍🌈" // flag ZWJ sequence
    ]) func multiScalarEmoji(emoji: String) {
        let shown = MealPresetQuickAdd.display(for: "\(emoji) bar")
        #expect(shown.icon == emoji)
        #expect(shown.label == "bar")
        #expect(shown.iconIsEmoji)
    }

    @Test("No emoji: first letter uppercased, full name as label") func noEmoji() {
        #expect(MealPresetQuickAdd.display(for: "bp bar") == .init(icon: "B", label: "bp bar", iconIsEmoji: false))
        #expect(MealPresetQuickAdd.display(for: "  perfect bar ") == .init(icon: "P", label: "perfect bar", iconIsEmoji: false))
    }

    @Test("Digits and symbols are text, not emoji") func digitsAreNotEmoji() {
        #expect(MealPresetQuickAdd.display(for: "2 eggs") == .init(icon: "2", label: "2 eggs", iconIsEmoji: false))
        #expect(MealPresetQuickAdd.display(for: "#1 combo").iconIsEmoji == false)
        #expect(MealPresetQuickAdd.display(for: "éclair") == .init(icon: "É", label: "éclair", iconIsEmoji: false))
    }

    @Test("Emoji later in the name is left alone") func emojiNotAtStart() {
        #expect(MealPresetQuickAdd.display(for: "keto 🥤") == .init(icon: "K", label: "keto 🥤", iconIsEmoji: false))
    }

    @Test("Empty or missing name") func emptyName() {
        let empty = MealPresetQuickAdd.Display(icon: "?", label: "", iconIsEmoji: false)
        #expect(MealPresetQuickAdd.display(for: "") == empty)
        #expect(MealPresetQuickAdd.display(for: "   ") == empty)
        #expect(MealPresetQuickAdd.display(for: nil) == empty)
    }

    @Test("Name that is only an emoji") func onlyEmoji() {
        #expect(MealPresetQuickAdd.display(for: "🥤") == .init(icon: "🥤", label: "", iconIsEmoji: true))
        #expect(MealPresetQuickAdd.display(for: "👨‍👩‍👧 ") == .init(icon: "👨‍👩‍👧", label: "", iconIsEmoji: true))
    }

    // MARK: - Note tag

    @Test("Note tag strips the emoji and respects the Note field length") func noteTag() {
        #expect(MealPresetQuickAdd.noteTag(for: "🥤 keto fuel") == "keto fuel")
        #expect(MealPresetQuickAdd.noteTag(for: "bp bar") == "bp bar")
        #expect(MealPresetQuickAdd.noteTag(for: "🥤") == "🥤")
        #expect(MealPresetQuickAdd.noteTag(for: nil) == "")
        let long = String(repeating: "a", count: 40)
        #expect(MealPresetQuickAdd.noteTag(for: long).count == MealPresetQuickAdd.noteMaxLength)
    }

    // MARK: - Ordering

    @Test("Same sort as the preset sheet: dish ascending") func ordering() {
        let descriptors = MealPresetQuickAdd.sortDescriptors
        #expect(descriptors.count == 1)
        #expect(descriptors.first?.key == "dish")
        #expect(descriptors.first?.ascending == true)

        let names = ["perfect bar", "keto fuel", "bp bar"].map { ["dish": $0] as NSDictionary }
        let sorted = (names as NSArray).sortedArray(using: descriptors).compactMap { ($0 as? NSDictionary)?["dish"] as? String }
        #expect(sorted == ["bp bar", "keto fuel", "perfect bar"])
    }

    // MARK: - Same result as the sheet

    /// The statements `MealPresetView` runs for one serving: the picker's `onChange` adds to the sheet's local
    /// totals, "Add to Treatments" adds those to the state, and `onDisappear` clears selection and summation.
    /// Copied here because they live inside the view and cannot be called from a test.
    private func addThroughSheet(
        _ state: Treatments.StateModel,
        name: String,
        carbs presetCarbs: Decimal,
        fat presetFat: Decimal,
        protein presetProtein: Decimal,
        servings: Int = 1
    ) {
        var carbs: Decimal = 0
        var fat: Decimal = 0
        var protein: Decimal = 0
        for _ in 0 ..< servings {
            carbs += presetCarbs
            if state.useFPUconversion {
                fat += presetFat
                protein += presetProtein
            }
            state.addNewPresetToWaitersNotepad(name)
        }
        state.carbs += carbs
        state.fat += fat
        state.protein += protein
        state.selection = nil
        state.summation.removeAll()
    }

    @Test("One tap equals one serving through the sheet", arguments: [true, false]) func sameAsSheet(useFPU: Bool) {
        let viaSheet = Treatments.StateModel()
        let viaButton = Treatments.StateModel()
        for state in [viaSheet, viaButton] {
            state.useFPUconversion = useFPU
            state.carbs = 5
            state.fat = 2
            state.protein = 1
        }

        addThroughSheet(viaSheet, name: "keto fuel", carbs: 7, fat: 40, protein: 30)
        viaButton.quickAddPreset(name: "keto fuel", carbs: 7, fat: 40, protein: 30)

        #expect(viaButton.carbs == viaSheet.carbs)
        #expect(viaButton.fat == viaSheet.fat)
        #expect(viaButton.protein == viaSheet.protein)
        #expect(viaButton.summation == viaSheet.summation)
        #expect(viaButton.selection == nil)
        #expect(viaButton.carbs == 12)
        #expect(viaButton.fat == (useFPU ? 42 : 2))
        #expect(viaButton.protein == (useFPU ? 31 : 1))
    }

    @Test("Tapping twice equals two servings through the sheet") func repeatedAdd() {
        let viaSheet = Treatments.StateModel()
        let viaButton = Treatments.StateModel()
        viaSheet.useFPUconversion = true
        viaButton.useFPUconversion = true

        addThroughSheet(viaSheet, name: "bp bar", carbs: 3.5, fat: 12, protein: 9, servings: 2)
        viaButton.quickAddPreset(name: "bp bar", carbs: 3.5, fat: 12, protein: 9)
        viaButton.quickAddPreset(name: "bp bar", carbs: 3.5, fat: 12, protein: 9)

        #expect(viaButton.carbs == viaSheet.carbs)
        #expect(viaButton.fat == viaSheet.fat)
        #expect(viaButton.protein == viaSheet.protein)
        #expect(viaButton.carbs == 7)
    }

    @Test("A tap changes nothing but the three fields and an empty note") func touchesNothingElse() {
        let state = Treatments.StateModel()
        state.useFPUconversion = true
        state.amount = 1.5
        state.insulinCalculated = 2
        state.externalInsulin = false

        state.quickAddPreset(name: "🥤 keto fuel", carbs: 7, fat: 40, protein: 30)

        #expect(state.amount == 1.5)
        #expect(state.insulinCalculated == 2)
        #expect(state.externalInsulin == false)
        #expect(state.addButtonPressed == false)
        #expect(state.summation.isEmpty)
        #expect(state.selection == nil)
    }

    // MARK: - Note behaviour

    @Test("Empty note gets the preset name without emoji") func noteSetWhenEmpty() {
        let state = Treatments.StateModel()
        state.quickAddPreset(name: "🥤 keto fuel", carbs: 7, fat: 40, protein: 30)
        #expect(state.note == "keto fuel")
    }

    @Test("A typed note is left alone; the tag from an earlier tap is extended") func noteKept() {
        let state = Treatments.StateModel()
        state.note = "late lunch"
        state.quickAddPreset(name: "bp bar", carbs: 3, fat: 12, protein: 9)
        #expect(state.note == "late lunch")

        let second = Treatments.StateModel()
        second.quickAddPreset(name: "bp bar", carbs: 3, fat: 12, protein: 9)
        second.quickAddPreset(name: "perfect bar", carbs: 20, fat: 18, protein: 17)
        #expect(second.note == "bp bar + perfect bar")
    }

    // MARK: - Repeat counts and badge

    @Test("Badge appears from the second tap") func badgeLabel() {
        #expect(MealPresetQuickAdd.badgeLabel(count: 0) == nil)
        #expect(MealPresetQuickAdd.badgeLabel(count: 1) == nil)
        #expect(MealPresetQuickAdd.badgeLabel(count: 2) == "×2")
        #expect(MealPresetQuickAdd.badgeLabel(count: 3) == "×3")
    }

    @Test("Counts are per preset key") func countsPerKey() {
        let taps = [
            MealPresetQuickAdd.Tap(key: "a", name: "bp bar"),
            MealPresetQuickAdd.Tap(key: "b", name: "keto fuel"),
            MealPresetQuickAdd.Tap(key: "a", name: "bp bar")
        ]
        #expect(MealPresetQuickAdd.count(of: "a", in: taps) == 2)
        #expect(MealPresetQuickAdd.count(of: "b", in: taps) == 1)
        #expect(MealPresetQuickAdd.count(of: "c", in: taps) == 0)
        #expect(MealPresetQuickAdd.count(of: "a", in: []) == 0)
    }

    @Test("Taps are recorded per tap and never change the amounts") func tapsAreDisplayOnly() {
        let state = Treatments.StateModel()
        state.useFPUconversion = true
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        #expect(MealPresetQuickAdd.count(of: "a", in: state.quickAddTaps) == 2)
        #expect(state.carbs == 6)

        // Tampering with the counts must not affect the next add.
        state.quickAddTaps.removeAll()
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        #expect(state.carbs == 9)
        #expect(state.fat == 36)
        #expect(state.protein == 27)
    }

    @Test("Reset clears the counts and only a note the buttons wrote") func reset() {
        let state = Treatments.StateModel()
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        state.resetQuickAddTaps()
        #expect(state.quickAddTaps.isEmpty)
        #expect(state.note == "")

        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        state.note = "my own note"
        state.resetQuickAddTaps()
        #expect(state.quickAddTaps.isEmpty)
        #expect(state.note == "my own note")
    }

    // MARK: - Note composition

    @Test("Note joins names in first-tap order with repeat counts") func composeNote() {
        #expect(MealPresetQuickAdd.composeNote(names: []) == "")
        #expect(MealPresetQuickAdd.composeNote(names: ["bp bar"]) == "bp bar")
        #expect(MealPresetQuickAdd.composeNote(names: ["🥤 keto fuel", "🥤 keto fuel"]) == "keto fuel x2")
        #expect(MealPresetQuickAdd.composeNote(names: ["keto fuel", "bp bar"]) == "keto fuel + bp bar")
        #expect(MealPresetQuickAdd.composeNote(names: ["bp bar", "keto fuel", "bp bar"]) == "bp bar x2 + keto fuel")
        #expect(MealPresetQuickAdd.composeNote(names: ["🥤"]) == "🥤")
        #expect(MealPresetQuickAdd.composeNote(names: ["", "bp bar"]) == "bp bar")
    }

    @Test("Composed note is cut to the Note field length") func composeNoteTruncates() {
        let note = MealPresetQuickAdd.composeNote(names: ["keto fuel", "perfect bar", "bp bar"])
        #expect(note == "keto fuel + perfect bar +")
        #expect(note.count == MealPresetQuickAdd.noteMaxLength)
    }

    @Test("May write only an empty note or its own last text") func mayWriteNote() {
        #expect(MealPresetQuickAdd.mayWriteNote(current: "", lastWritten: nil))
        #expect(MealPresetQuickAdd.mayWriteNote(current: "", lastWritten: "bp bar"))
        #expect(MealPresetQuickAdd.mayWriteNote(current: "bp bar", lastWritten: "bp bar"))
        #expect(!MealPresetQuickAdd.mayWriteNote(current: "bp bar!", lastWritten: "bp bar"))
        #expect(!MealPresetQuickAdd.mayWriteNote(current: "lunch", lastWritten: nil))
    }

    @Test("Note follows the taps until the user edits it") func noteFollowsTaps() {
        let state = Treatments.StateModel()
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        #expect(state.note == "bp bar")
        state.quickAddPreset(key: "a", name: "bp bar", carbs: 3, fat: 12, protein: 9)
        #expect(state.note == "bp bar x2")
        state.quickAddPreset(key: "b", name: "🥤 keto fuel", carbs: 7, fat: 40, protein: 30)
        #expect(state.note == "bp bar x2 + keto fuel")

        state.note = "bp bar x2 + keto, late"
        state.quickAddPreset(key: "b", name: "🥤 keto fuel", carbs: 7, fat: 40, protein: 30)
        #expect(state.note == "bp bar x2 + keto, late")
    }
}
