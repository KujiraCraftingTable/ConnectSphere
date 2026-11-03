import Foundation
import Observation

/// The first visit to Dating, like Facebook's: a welcome, what Dating keeps
/// private, then the profile one question at a time. The answers live in
/// `form` (the editor's model), which also saves them.
@MainActor
@Observable
final class DatingSetupViewModel {
    enum Step: Int, CaseIterable {
        case welcome, privacy, basics, interestedIn, height, kids, location, photos, about
    }

    private(set) var step: Step = .welcome
    let form: DatingProfileEditorViewModel
    let basics: DatingBasics?
    /// "Who do you want to date?" starts unanswered, as on Facebook.
    private(set) var hasChosenInterest = false
    /// The wheel needs a value; it only becomes the height on Next (Skip leaves none).
    var heightDraft = 170

    init(basics: DatingBasics?, isTeen: Bool) {
        self.basics = basics
        form = DatingProfileEditorViewModel(profile: nil, isTeen: isTeen)
        form.maxDistanceKm = 50
    }

    var progress: Double { Double(step.rawValue) / Double(Step.allCases.count - 1) }

    var isFirstStep: Bool { step == .welcome }
    var isLastStep: Bool { step == .about }
    var isSkippable: Bool { step == .height || step == .kids }

    /// Something has been answered — leaving now should ask first.
    var hasAnswers: Bool {
        hasChosenInterest || form.heightCm != nil || form.hasKids != nil || form.place != nil
            || !form.photos.isEmpty || !form.bio.isEmpty
    }

    var canGoNext: Bool {
        switch step {
        case .interestedIn: return hasChosenInterest && form.minAge <= form.maxAge
        case .kids: return form.hasKids != nil
        case .location: return form.place != nil && !form.locationBlocked
        case .photos: return !form.photos.isEmpty && form.pendingPhotoCount == 0
        case .about: return form.canSave
        default: return true
        }
    }

    func chooseInterest(_ interest: DatingInterest) {
        form.interestedIn = interest
        hasChosenInterest = true
    }

    func next() {
        if step == .height { form.heightCm = heightDraft }
        go(by: 1)
    }

    func skip() {
        if step == .height { form.heightCm = nil }
        if step == .kids { form.hasKids = nil }
        go(by: 1)
    }

    func back() { go(by: -1) }

    private func go(by offset: Int) {
        guard let target = Step(rawValue: step.rawValue + offset) else { return }
        step = target
    }
}
