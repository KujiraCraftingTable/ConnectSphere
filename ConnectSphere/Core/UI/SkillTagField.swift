import SwiftUI

/// Skills typed one at a time: type one, press Return, it becomes a chip
/// and the field is ready for the next. The ✕ on a chip removes it at once.
struct SkillTagField: View {
    @Binding var skills: [String]
    var limit = SkillList.profileLimit
    var placeholder: String?
    /// Onboarding's fixed-light screens pass `.light`, like InterestPickerView.
    var colorScheme: ColorScheme
    /// The bordered look of the onboarding fields (AuthTextField).
    var boxed = false

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !skills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(skills, id: \.self) { chip($0) }
                }
            }
            if boxed { input.modifier(Boxed(colorScheme: colorScheme)) } else { input }
            if let problem {
                // Not a Label — a Form row drops a Label's text (see chip below).
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(problem)
                }
                .font(.footnote)
                .foregroundStyle(.red)
            } else if limit - skills.count <= 5 {
                Text(String(format: bundle.loc("%lld / %lld"), skills.count, limit))
                    .font(.footnote)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
    }

    private var input: some View {
        HStack(spacing: 12) {
            if boxed {
                Image(systemName: "sparkles")
                    .foregroundStyle(themeManager.theme.primaryGradient)
                    .frame(width: 20)
            }
            TextField("", text: $draft)
                .placeholder(when: draft.isEmpty) {
                    Text(placeholder ?? bundle.loc("Add a skill, then press Return"))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .font(.system(size: boxed ? 15 : 17))
                // The placeholder is an overlay, so VoiceOver needs it spelled out.
                .accessibilityLabel(Text(placeholder ?? bundle.loc("Add a skill, then press Return")))
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .disabled(skills.count >= limit)
                .onSubmit {
                    commit()
                    // Return ends editing; bring the keyboard straight back
                    // for the next skill.
                    DispatchQueue.main.async { focused = true }
                }
                .onChange(of: draft) { _, text in if text.contains(",") { commit() } }
                // Text typed but not entered still counts when they move on
                // (tapping Save ends editing first).
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
    }

    private func commit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = ""
            return
        }
        let result = SkillList.adding(draft, to: skills, limit: limit)
        withAnimation(.snappy) { skills = result.skills }
        problem = result.problem
        // A refused skill stays in the field so it can be fixed.
        if result.problem == nil { draft = "" }
    }

    private func chip(_ skill: String) -> some View {
        // Not a Label: a Form row restyles Labels and the chip's text disappears.
        HStack(spacing: 5) {
            Button {
                withAnimation(.snappy) { skills.removeAll { $0 == skill } }
                problem = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            // Borderless: in a Form row every plain Button fires on any tap.
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(String(format: bundle.loc("Remove %@"), skill)))
            Text(skill)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(AppColors.elevated(colorScheme), in: Capsule())
        .fixedSize()
    }

    private struct Boxed: ViewModifier {
        let colorScheme: ColorScheme
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppColors.surface(colorScheme))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                )
        }
    }
}
