import SwiftUI

/// A clip or card's enter/exit treatment. Fades only for now, but modelled as
/// its own value so more types (crossfade, slide, …) can be added later without
/// changing call sites. 0 seconds means "no fade". Travels with whatever owns
/// it (currently a `CardDocument`; clips and a project first/last override are
/// the planned next adopters).
struct SegmentTransition: Codable, Equatable, Hashable {
    var fadeInSeconds: Double = 0
    var fadeOutSeconds: Double = 0

    var hasFadeIn: Bool { fadeInSeconds > 0 }
    var hasFadeOut: Bool { fadeOutSeconds > 0 }
    var isEmpty: Bool { !hasFadeIn && !hasFadeOut }

    /// A free default fade length when a fade is first switched on.
    static let defaultFadeSeconds = 0.5

    /// Short description for a button label, e.g. "Fade in 0.5s", "Fade in & out".
    var summary: String {
        switch (hasFadeIn, hasFadeOut) {
        case (false, false): return "No fade"
        case (true, false): return String(format: "Fade in %.1fs", fadeInSeconds)
        case (false, true): return String(format: "Fade out %.1fs", fadeOutSeconds)
        case (true, true): return "Fade in & out"
        }
    }
}

/// Compact row showing a target's current transition with a button to edit it.
/// Used by the clip editors (and the cover/ending pickers reuse the same idea).
struct TransitionRow: View {
    let transition: SegmentTransition
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("Transition")
            Spacer()
            Button(transition.summary) { onEdit() }
                .help("Fade this clip in and/or out in the rendered video")
        }
    }
}

/// Shared sheet for editing a `Transition` — opened from a "Transition…" button
/// wherever a target (a card today) owns one. `maxSeconds` is the target's
/// duration; each fade is capped to it so a fade can't exceed the segment.
struct TransitionEditorSheet: View {
    @Binding var transition: SegmentTransition
    var maxSeconds: Double

    @Environment(\.dismiss) private var dismiss

    private var range: ClosedRange<Double> { 0.1...max(0.1, maxSeconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transition")
                .font(.title3.bold())
            Text("Fade this card in from black and/or out to black. Each fade is capped at the card's length (\(String(format: "%.1f", maxSeconds))s).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            fadeRow("Fade in", isOn: onBinding(\.fadeInSeconds), seconds: secondsBinding(\.fadeInSeconds))
            fadeRow("Fade out", isOn: onBinding(\.fadeOutSeconds), seconds: secondsBinding(\.fadeOutSeconds))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func fadeRow(_ label: String, isOn: Binding<Bool>, seconds: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
            Spacer()
            // Only the duration controls dim/disable when the fade is off — the
            // toggle stays live.
            Group {
                TextField("", value: seconds, format: .number.precision(.fractionLength(1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                Text("s")
                Stepper("", value: seconds, in: range, step: 0.1)
                    .labelsHidden()
            }
            .disabled(!isOn.wrappedValue)
            .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
        }
    }

    /// On/off for a fade: flipping on seeds a default length (capped), off zeroes it.
    private func onBinding(_ keyPath: WritableKeyPath<SegmentTransition, Double>) -> Binding<Bool> {
        Binding(
            get: { transition[keyPath: keyPath] > 0 },
            set: { transition[keyPath: keyPath] = $0 ? min(SegmentTransition.defaultFadeSeconds, range.upperBound) : 0 }
        )
    }

    /// Seconds for a fade, clamped to the valid range on every write (the text
    /// field accepts any number, so the bounds can't live on the stepper alone).
    private func secondsBinding(_ keyPath: WritableKeyPath<SegmentTransition, Double>) -> Binding<Double> {
        Binding(
            get: { transition[keyPath: keyPath] },
            set: { transition[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

/// Sheet for a single clip-level fade duration — the first-clip fade-in or
/// last-clip fade-out offered in the Create Video window when there's no
/// Cover/Ending card. The simpler sibling of `TransitionEditorSheet` (one fade,
/// a plain `Double`), capped to the target clip's length.
struct ClipFadeSheet: View {
    @Binding var seconds: Double
    /// Sheet heading, e.g. "Fade In First Clip".
    var title: String
    /// The toggle's label, e.g. "Fade in" / "Fade out".
    var fadeLabel: String
    /// One-line explanation shown under the title.
    var message: String
    /// The target clip's length; the fade is capped to it.
    var maxSeconds: Double

    @Environment(\.dismiss) private var dismiss

    private var upperBound: Double { max(0.1, maxSeconds) }
    private var range: ClosedRange<Double> { 0.1...upperBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.bold())
            Text(maxSeconds > 0
                 ? "\(message) Capped at the clip's length (\(String(format: "%.1f", maxSeconds))s)."
                 : message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Toggle(fadeLabel, isOn: isOn)
                    .toggleStyle(.checkbox)
                Spacer()
                // Only the duration controls dim when the fade is off — the
                // toggle stays live (mirrors `TransitionEditorSheet`).
                Group {
                    TextField("", value: secondsBinding, format: .number.precision(.fractionLength(1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 44)
                    Text("s")
                    Stepper("", value: secondsBinding, in: range, step: 0.1)
                        .labelsHidden()
                }
                .disabled(!isOn.wrappedValue)
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    /// On/off for the fade: flipping on seeds a default length (capped), off zeroes it.
    private var isOn: Binding<Bool> {
        Binding(
            get: { seconds > 0 },
            set: { seconds = $0 ? min(SegmentTransition.defaultFadeSeconds, upperBound) : 0 }
        )
    }

    /// Seconds, clamped to the valid range on every write.
    private var secondsBinding: Binding<Double> {
        Binding(
            get: { seconds },
            set: { seconds = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
