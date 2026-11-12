import SwiftUI
import UniFiCore

// MARK: - Page layout

struct PageContainer<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Actions sit beside the title when there's room and move under it when an inspector narrows the page.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heading
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { actions() }
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    HStack(spacing: 8) { actions() }
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Renders a section's load state. Failures are shown as failures, never as empty lists.
struct SectionStateView<Value, Content: View>: View {
    @EnvironmentObject private var model: NetworkModel
    let state: LoadState<Value>
    let noun: String
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle:
            ContentUnavailableView("Not loaded", systemImage: "circle.dashed",
                                   description: Text("Select a site to load \(noun)."))
        case .loading:
            ProgressView("Loading \(noun)...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load \(noun)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .disabled(model.isBusy || model.isLoading)
            }
            .foregroundStyle(Theme.secondary)
        case .loaded(let value):
            content(value)
        }
    }
}

struct EmptyState: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageBanner: View {
    let text: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.red : Theme.green)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background((isError ? Theme.red : Theme.green).opacity(0.12))
        .overlay(alignment: .leading) { Rectangle().fill(isError ? Theme.red : Theme.green).frame(width: 3) }
        .accessibilityLabel(isError ? "Error: \(text)" : text)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).foregroundStyle(.primary)
        }
    }
}

/// An inline enable switch that sends a change only when the user flips it.
struct EnabledToggle: View {
    @EnvironmentObject private var model: NetworkModel
    let isOn: Bool
    var editable = true
    let label: String
    let change: (Bool) async -> Void

    var body: some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { value in Task { await change(value) } }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!editable || !model.canMutate)
            .help(editable ? label : "Managed by the controller")
    }
}

// MARK: - Confirmation

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    var destructive = true
    let action: () async -> Void
}

@MainActor
final class ConfirmCenter: ObservableObject {
    @Published var request: ConfirmRequest?

    func ask(_ title: String, _ message: String, action actionTitle: String, destructive: Bool = true,
             perform: @escaping () async -> Void) {
        request = ConfirmRequest(title: title, message: message, actionTitle: actionTitle,
                                 destructive: destructive, action: perform)
    }
}

struct ConfirmationHost: ViewModifier {
    @ObservedObject var center: ConfirmCenter

    func body(content: Content) -> some View {
        content.alert(
            center.request?.title ?? "",
            isPresented: Binding(get: { center.request != nil }, set: { if !$0 { center.request = nil } }),
            presenting: center.request
        ) { request in
            Button(request.actionTitle, role: request.destructive ? .destructive : nil) {
                Task { await request.action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

// MARK: - Editors

protocol ResourceDraft: Equatable {
    init()
    init(detail: JSONValue)
    var validationErrors: [String] { get }
    var title: String { get }
    func apply(to detail: JSONValue) -> JSONValue
    func body(forCreateOn version: NetworkVersion?) -> JSONValue
}

extension NetworkDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody() }
}

extension WiFiDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody(version: version) }
}

extension FirewallZoneDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody() }
}

extension FirewallPolicyDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody(version: version) }
}

extension DNSPolicyDraft: ResourceDraft {
    var title: String { domain }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody() }
}

extension ACLRuleDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody() }
}

extension TrafficMatchingListDraft: ResourceDraft {
    var title: String { name }
    func body(forCreateOn version: NetworkVersion?) -> JSONValue { createBody() }
}

enum EditorTarget: Hashable, Identifiable {
    case create
    case edit(UUID)

    var id: Self { self }
    var isCreate: Bool { self == .create }
}

/// Side panel editor. Edits start from the controller's current detail document and only the
/// fields shown are changed; everything else round-trips untouched.
struct ResourceEditor<Draft: ResourceDraft, Fields: View>: View {
    @EnvironmentObject private var model: NetworkModel
    let kind: EditableResource
    let target: EditorTarget
    var readOnlyReason: String?
    var prepare: (inout Draft) -> Void = { _ in }
    var onDelete: (() -> Void)?
    let onClose: () -> Void
    @ViewBuilder let fields: (Binding<Draft>) -> Fields

    @State private var detail: LoadState<JSONValue> = .loading
    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var attempted = false
    @State private var failure: String?

    private var errors: [String] { draft.validationErrors }
    private var canSave: Bool {
        readOnlyReason == nil && errors.isEmpty && model.canMutate && (target.isCreate || draft != original)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.isCreate ? "Create \(kind.displayName.capitalizedFirst)" : (original.title.isEmpty ? kind.displayName.capitalizedFirst : original.title))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(14)
            Divider()
            content
            Divider()
            footer.padding(12)
        }
        .background(Theme.sidebar)
        .task(id: target) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch detail {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Settings unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxHeight: .infinity)
        case .loaded:
            Form {
                if let readOnlyReason {
                    Section {
                        Label(readOnlyReason, systemImage: "lock.fill").foregroundStyle(Theme.secondary)
                        if let url = model.webURL("settings") {
                            Link("Open in the controller web UI", destination: url)
                        }
                    }
                }
                Group { fields($draft) }.disabled(readOnlyReason != nil)
                if attempted || draft != original, !errors.isEmpty, readOnlyReason == nil {
                    Section {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
                        }
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "xmark.octagon").foregroundStyle(Theme.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            if let onDelete, !target.isCreate, readOnlyReason == nil {
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(!model.canMutate)
            }
            Spacer()
            Button("Cancel", action: onClose)
            Button(target.isCreate ? "Create" : "Apply Changes") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private func load() async {
        failure = nil
        attempted = false
        switch target {
        case .create:
            var fresh = Draft()
            prepare(&fresh)
            draft = fresh
            original = fresh
            detail = .loaded([:])
        case .edit(let id):
            detail = .loading
            switch await model.detail(kind, id: id) {
            case .success(let value):
                let loaded = Draft(detail: value)
                draft = loaded
                original = loaded
                detail = .loaded(value)
            case .failure(let error):
                detail = .failed(error.message)
            }
        }
    }

    private func save() async {
        attempted = true
        guard canSave, let current = detail.value else { return }
        failure = nil
        let saved: Bool
        switch target {
        case .create:
            saved = await model.create(kind, body: draft.body(forCreateOn: model.networkVersion), name: draft.title)
        case .edit(let id):
            saved = await model.update(kind, id: id, edited: draft.apply(to: current), name: draft.title)
        }
        if saved { onClose() } else { failure = model.error }
    }
}

/// Shared inspector wiring for list pages.
struct EditorInspector<Editor: View>: ViewModifier {
    @Binding var target: EditorTarget?
    @ViewBuilder let editor: (EditorTarget) -> Editor

    func body(content: Content) -> some View {
        content.inspector(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Group {
                if let target { editor(target).id(target) }
            }
            .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
        }
    }
}

extension View {
    func editorInspector<Editor: View>(_ target: Binding<EditorTarget?>, @ViewBuilder editor: @escaping (EditorTarget) -> Editor) -> some View {
        modifier(EditorInspector(target: target, editor: editor))
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var suffix: String?

    init(_ title: String, value: Binding<Int>, suffix: String? = nil) {
        self.title = title
        _value = value
        self.suffix = suffix
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                if let suffix { Text(suffix).foregroundStyle(Theme.secondary) }
            }
        }
    }
}

/// Optional numeric limit: off means "use the controller's default / unlimited".
struct OptionalIntField: View {
    let title: String
    @Binding var value: Int?
    let defaultValue: Int
    let suffix: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if value != nil {
                    TextField(title, value: Binding(get: { value ?? defaultValue }, set: { value = $0 }), format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                    Text(suffix).foregroundStyle(Theme.secondary)
                }
                Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? defaultValue : nil }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}
