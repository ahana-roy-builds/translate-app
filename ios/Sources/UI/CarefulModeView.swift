import SwiftUI

struct CarefulModeView: View {
    @ObservedObject var orchestrator: ConversationOrchestrator
    @State private var editing = false

    var body: some View {
        ScrollView {
            content
        }
        .frame(maxHeight: 560)
        .background(.ultraThickMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: TranslatorTheme.cornerRadius,
                topTrailingRadius: TranslatorTheme.cornerRadius
            )
        )
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom))
        .tint(TranslatorTheme.accent)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(.secondary).frame(width: 36, height: 4).frame(maxWidth: .infinity)
            Label("Check important details", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange)
            if let result = orchestrator.pendingResult {
                if editing {
                    TextField("What was said", text: editableSourceBinding, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                } else {
                    Text(result.sourceText).font(.body)
                }
                Text(result.translatedText).font(.title3.weight(.semibold))
            }
            if let integrity = orchestrator.pendingIntegrity {
                let presentation = CarefulModePresentation(report: integrity)
                if presentation.showsEntitySections {
                    entitySection(
                        title: CarefulModePresentation.sourceLabel,
                        entities: presentation.sourceEntities,
                        omittedCount: presentation.sourceOmittedCount
                    )
                    entitySection(
                        title: CarefulModePresentation.translationLabel,
                        entities: presentation.translationEntities,
                        omittedCount: presentation.translationOmittedCount
                    )
                }
                if integrity.extractionLimitExceeded {
                    Text("This turn contains too many safety-critical details to approve safely. Edit and split it into shorter turns, or repeat it.")
                        .font(.caption).foregroundStyle(.red)
                }
                if presentation.requiresMedicalOrEmergencyWarning {
                    Text("Medical and emergency translations can be wrong. Do not rely on this app instead of local emergency services or a qualified interpreter.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if orchestrator.pendingIntegrity?.hasMismatch == true { Text("A number or safety detail may have changed, disappeared, or been added. Edit, repeat, or approve only after checking.").font(.caption).foregroundStyle(.red) }
            if orchestrator.pendingResult?.warnings.contains(.uncertainRecognition) == true { Text("Speech recognition may be uncertain or in the wrong language. Check what was heard before speaking it.").font(.caption).foregroundStyle(.orange) }
            if orchestrator.pendingResult?.warnings.contains(.serviceDegraded) == true { Text("The service returned an unfamiliar warning. Review this turn carefully.").font(.caption).foregroundStyle(.orange) }
            if let error = orchestrator.pendingErrorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            ViewThatFits(in: .horizontal) {
                horizontalButtons
                verticalButtons
            }
        }
        .padding()
    }

    private var horizontalButtons: some View {
        HStack {
            Button("Repeat") { orchestrator.discardPending() }
                .buttonStyle(.bordered)
                .disabled(orchestrator.isCommitting)
            Button(editing ? "Retranslate" : "Edit") {
                if editing { orchestrator.editAndRetranslate() }
                editing.toggle()
            }
            .buttonStyle(.bordered)
            .disabled(orchestrator.isCommitting)
            Spacer(minLength: 8)
            Button(orchestrator.isCommitting ? "Saving…" : orchestrator.autoSpeakEnabled ? "Approve & speak" : "Approve") { orchestrator.approvePending() }
                .buttonStyle(.borderedProminent)
                .disabled(orchestrator.isCommitting || orchestrator.pendingIntegrity?.extractionLimitExceeded == true)
        }
    }

    private var verticalButtons: some View {
        VStack(spacing: 8) {
            Button("Repeat") { orchestrator.discardPending() }
                .disabled(orchestrator.isCommitting)
                .buttonStyle(.bordered)
            Button(editing ? "Retranslate" : "Edit") {
                if editing { orchestrator.editAndRetranslate() }
                editing.toggle()
            }
            .disabled(orchestrator.isCommitting)
            .buttonStyle(.bordered)
            Button(orchestrator.isCommitting ? "Saving…" : orchestrator.autoSpeakEnabled ? "Approve & speak" : "Approve") { orchestrator.approvePending() }
                .disabled(orchestrator.isCommitting || orchestrator.pendingIntegrity?.extractionLimitExceeded == true)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private var editableSourceBinding: Binding<String> {
        Binding(
            get: { orchestrator.editableSource },
            set: { orchestrator.editableSource = TurnTextPolicy.clamped($0) }
        )
    }

    private func entitySection(title: String, entities: [CriticalEntity], omittedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).accessibilityAddTraits(.isHeader)
            if entities.isEmpty {
                Text("None detected").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(entities) { EntityChip(entity: $0) }
                }
            }
            if omittedCount > 0 {
                Text("\(omittedCount) more details not shown").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CarefulModePresentation: Equatable {
    static let sourceLabel = "Source critical details"
    static let translationLabel = "Translation critical details"

    let sourceEntities: [CriticalEntity]
    let translationEntities: [CriticalEntity]
    let sourceOmittedCount: Int
    let translationOmittedCount: Int
    let requiresMedicalOrEmergencyWarning: Bool

    var showsEntitySections: Bool { !sourceEntities.isEmpty || !translationEntities.isEmpty }

    init(report: EntityIntegrityReport) {
        let limit = ConversationContentPolicy.maximumRenderedSafetyEntities
        sourceEntities = Array(report.source.prefix(limit))
        translationEntities = Array(report.translation.prefix(limit))
        sourceOmittedCount = max(0, report.source.count - sourceEntities.count)
        translationOmittedCount = max(0, report.translation.count - translationEntities.count)
        requiresMedicalOrEmergencyWarning = (report.source + report.translation).contains {
            $0.kind == .medication || $0.kind == .emergency
        }
    }
}
