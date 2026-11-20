import SwiftUI

/// The API key field of a service form: the saved key (masked), a new one being
/// typed, or the saved one being cleared.
struct KeyDraft: Equatable {
    var saved: String?
    var cleared = false
    var typed = ""

    var hasSaved: Bool { saved != nil && !cleared }

    /// The key the form would use if saved now.
    var effective: String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return cleared ? nil : saved
    }

    var change: KeyChange {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .set(trimmed) }
        return cleared ? .clear : .unchanged
    }
}

struct APIKeySection<Footer: View>: View {
    @Binding var draft: KeyDraft
    var placeholder: LocalizedStringKey
    @ViewBuilder var footer: Footer

    var body: some View {
        Section {
            if draft.hasSaved, let saved = draft.saved {
                LabeledContent("已保存", value: "••••\(saved.suffix(4))")
                    .accessibilityIdentifier("saved-key")
            }
            SecureField(draft.hasSaved ? "输入新 Key 以替换（不改可留空）" : placeholder, text: $draft.typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draft.hasSaved {
                Button("清除已保存的 Key", role: .destructive) { draft.cleared = true }
            }
        } header: { Text("API Key") } footer: { footer }
    }
}

/// Sends one short request with what the form holds now and shows the answer or the error.
/// The result is dropped whenever `draft` changes.
struct ServiceTestSection<Draft: Equatable>: View {
    var draft: Draft
    /// Nil while the form isn't complete enough to try.
    var request: (() -> AsyncThrowingStream<String, Error>)?
    var footer: LocalizedStringKey

    private enum Outcome { case running, passed(String), failed(String) }
    @State private var outcome: Outcome?

    private var isRunning: Bool { if case .running = outcome { true } else { false } }

    var body: some View {
        Section {
            Button("测试", action: run).disabled(request == nil || isRunning)
            switch outcome {
            case nil: EmptyView()
            case .running: ProgressView()
            case .passed(let text): Text(text).textSelection(.enabled)
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
        } footer: { Text(footer) }
        .onChange(of: draft) { outcome = nil }
    }

    private func run() {
        guard let request else { return }
        outcome = .running
        let stream = request()
        Task {
            var latest = ""
            do {
                for try await text in stream { latest = text }
                outcome = latest.isEmpty ? .failed(String(localized: "没有得到回答。")) : .passed(latest)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}
