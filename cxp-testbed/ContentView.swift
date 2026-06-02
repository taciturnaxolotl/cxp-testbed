import SwiftUI
import AuthenticationServices

private enum ListFilter { case all, passkeys, done }

struct ContentView: View {
    @Environment(CredentialStore.self) private var store

    @State private var selectedIDs: Set<Data> = []
    @State private var exportedIDs: Set<Data> = []
    @State private var filterText = ""
    @State private var listFilter: ListFilter = .all
    @State private var chunkSize = 10
    @State private var isExporting = false

    // MARK: - Derived

    private var flatItems: [FlatItem] {
        guard let data = store.exportedData else { return [] }
        return data.accounts.enumerated().flatMap { idx, account in
            account.items.map { FlatItem(accountIndex: idx, item: $0) }
        }
    }

    private var filteredItems: [FlatItem] {
        flatItems.filter { flat in
            let done = exportedIDs.contains(flat.item.id)
            switch listFilter {
            case .done:
                return done
            case .all:
                guard !done else { return false }
                return matchesSearch(flat)
            case .passkeys:
                guard !done else { return false }
                guard flat.item.credentials.contains(where: { if case .passkey = $0 { true } else { false } }) else { return false }
                return matchesSearch(flat)
            }
        }
    }

    private func matchesSearch(_ flat: FlatItem) -> Bool {
        guard !filterText.isEmpty else { return true }
        let q = filterText.lowercased()
        if flat.item.title.lowercased().contains(q) { return true }
        return flat.item.credentials.contains { cred in
            if case .passkey(let pk) = cred {
                return pk.relyingPartyIdentifier.lowercased().contains(q)
                    || pk.userName.lowercased().contains(q)
            }
            return false
        }
    }

    private var pendingCount: Int { flatItems.filter { !exportedIDs.contains($0.item.id) }.count }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if store.exportedData == nil {
                    emptyView
                } else {
                    listView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("CXP Relay").font(.headline)
                }

                if store.exportedData != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Filter", selection: $listFilter) {
                                Text("All").tag(ListFilter.all)
                                Text("Passkeys only").tag(ListFilter.passkeys)
                                Text("Done").tag(ListFilter.done)
                            }

                            if listFilter != .done {
                                Divider()
                                Button("Select All") {
                                    selectedIDs = Set(filteredItems.map(\.item.id))
                                }
                                Button("Deselect All") {
                                    selectedIDs = []
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }

                    ToolbarItemGroup(placement: .bottomBar) {
                        if listFilter != .done {
                            Stepper(value: $chunkSize, in: 1...200, step: 5) {
                                EmptyView()
                            }
                            .labelsHidden()

                            Button("Next \(chunkSize)") {
                                selectNextChunk()
                            }

                            Spacer()

                            Button {
                                exportSelected()
                            } label: {
                                Text("Export \(selectedIDs.count)")
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedIDs.isEmpty || isExporting)
                        } else {
                            Text("\(exportedIDs.count) exported")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                exportedIDs = []
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .onContinueUserActivity(ASCredentialExchangeActivity, perform: handleActivity)
    }

    // MARK: - Empty state

    private var emptyView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.blue.opacity(0.12))
                        .frame(width: 96, height: 96)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.blue)
                }

                VStack(spacing: 8) {
                    Text("CXP Relay")
                        .font(.title2.bold())

                    Text("Open another password manager, go to its export settings, and choose this app as the destination.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - List view

    private var listView: some View {
        List(filteredItems) { flat in
            ItemRow(
                item: flat.item,
                isSelected: selectedIDs.contains(flat.item.id),
                isDone: exportedIDs.contains(flat.item.id)
            ) {
                guard listFilter != .done else { return }
                toggle(flat.item.id)
            }
        }
        .listStyle(.plain)
        .searchable(text: $filterText, prompt: "Search by name or RP ID")
    }

    // MARK: - Actions

    private func toggle(_ id: Data) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func selectNextChunk() {
        // All pending items in display order
        let pending = flatItems.filter { !exportedIDs.contains($0.item.id) }
        // Find the position of the last currently-selected item
        let lastSelectedIndex = pending.lastIndex { selectedIDs.contains($0.item.id) } ?? -1
        // Select the N items that come after it (wraps to start if at end)
        let startIndex = lastSelectedIndex + 1
        let slice = pending.dropFirst(startIndex).prefix(chunkSize)
        let next = slice.isEmpty ? Array(pending.prefix(chunkSize)) : Array(slice)
        selectedIDs = Set(next.map(\.item.id))
    }

    private func handleActivity(_ activity: NSUserActivity) {
        let raw = activity.userInfo?[ASCredentialImportToken]
        let token: UUID?
        if let str = raw as? String {
            token = UUID(uuidString: str)
        } else if let uuid = raw as? UUID {
            token = uuid
        } else {
            let keys = activity.userInfo?.keys.map { "\($0)" }.joined(separator: ", ") ?? "none"
            store.statusMessage = "Bad token (\(type(of: raw))). Keys: \(keys)"
            return
        }

        guard let token else {
            store.statusMessage = "Malformed UUID in import token"
            return
        }

        store.statusMessage = "Importing…"
        Task { @MainActor in
            do {
                let data = try await ASCredentialImportManager().importCredentials(token: token)
                store.load(data)
                selectedIDs = []
                exportedIDs = []
            } catch {
                store.statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportSelected() {
        guard let source = store.exportedData, !selectedIDs.isEmpty else { return }
        isExporting = true

        Task { @MainActor in
            do {
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                      let window = scene.keyWindow else {
                    isExporting = false
                    return
                }

                let manager = ASCredentialExportManager(presentationAnchor: window)
                let options = try await manager.requestExport(for: nil)
                let subset = buildSubset(from: source, formatVersion: options.formatVersion)
                try await manager.exportCredentials(subset)

                exportedIDs.formUnion(selectedIDs)
                selectedIDs = []
            } catch {
                store.statusMessage = "Failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private func buildSubset(
        from data: ASExportedCredentialData,
        formatVersion: ASExportedCredentialData.FormatVersion
    ) -> ASExportedCredentialData {
        let accounts = data.accounts.compactMap { account -> ASImportableAccount? in
            let items = account.items
                .filter { selectedIDs.contains($0.id) }
                .map { item -> ASImportableItem in
                    let hasPasskey = item.credentials.contains { if case .passkey = $0 { true } else { false } }
                    guard hasPasskey else { return item }
                    var stripped = item
                    stripped.credentials = item.credentials.filter { if case .passkey = $0 { true } else { false } }
                    return stripped
                }
            guard !items.isEmpty else { return nil }
            return ASImportableAccount(
                id: account.id,
                userName: account.userName,
                email: account.email,
                fullName: account.fullName,
                collections: account.collections,
                items: items
            )
        }
        return ASExportedCredentialData(
            accounts: accounts,
            formatVersion: formatVersion,
            exporterRelyingPartyIdentifier: data.exporterRelyingPartyIdentifier,
            exporterDisplayName: data.exporterDisplayName,
            timestamp: Date()
        )
    }
}

// MARK: - Supporting types

private struct FlatItem: Identifiable {
    let accountIndex: Int
    let item: ASImportableItem
    var id: Data { item.id }
}

private struct ItemRow: View {
    let item: ASImportableItem
    let isSelected: Bool
    let isDone: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? .green : isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
                    .animation(.easeInOut(duration: 0.12), value: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(isDone ? .secondary : .primary)

                    if let sub = rpID {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    ForEach(typeSymbols, id: \.self) { sym in
                        Image(systemName: sym)
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rpID: String? {
        for cred in item.credentials {
            if case .passkey(let pk) = cred { return pk.relyingPartyIdentifier }
        }
        return nil
    }

    private var typeSymbols: [String] {
        item.credentials.compactMap { cred in
            if case .passkey = cred { return "key.fill" }
            if case .basicAuthentication = cred { return "lock.fill" }
            return nil
        }
    }
}
