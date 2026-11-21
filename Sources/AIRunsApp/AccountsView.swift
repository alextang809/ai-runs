import AIRunsCore
import AppKit
import SwiftUI

@MainActor
final class AccountWindowNavigation: ObservableObject {
    enum Route: Equatable {
        case accounts, providers, apiKey(AccountProvider)
    }

    @Published var route: Route = .accounts

    func choose(_ provider: AccountProvider, signIn: (AccountProvider) -> Void) {
        guard route == .providers else { return }
        if provider.usesAPIKey {
            route = .apiKey(provider)
        } else {
            route = .accounts
            signIn(provider)
        }
    }
}

struct ManagedAccountsView: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var navigation: AccountWindowNavigation
    @State private var code = ""
    @State private var enteringCode = false
    @State private var renameAccount: ManagedAccount?
    @State private var renameLabel = ""
    @State private var hoveredProvider: AccountProvider?

    private var canConnect: Bool {
        manager.isLoaded && !manager.isBusy && manager.connectingID == nil
    }

    private var contentHeight: CGFloat {
        let maximum = max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
        switch navigation.route {
        case .accounts:
            let expanded = !manager.accounts.isEmpty || manager.connectingID != nil || manager.loadError != nil
            return min(expanded ? 435 : 270, maximum)
        case .providers: return min(manager.loadError == nil ? 425 : 485, maximum)
        case .apiKey: return 225
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch navigation.route {
            case .accounts:
                accountsPage
            case .providers:
                providerPage
            case .apiKey(let provider):
                apiKeyPage(provider)
            }
        }
        .frame(width: 480, height: contentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .popover(item: $renameAccount) { account in renameForm(account) }
        .onChange(of: manager.connectingID) { _, _ in
            code = ""
            enteringCode = false
        }
    }

    private var accountsPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Accounts").font(AppTypography.rowTitle)
                Spacer()
                if !manager.accounts.isEmpty {
                    Button {
                        manager.refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh all saved accounts")
                    .accessibilityLabel("Refresh all saved accounts")
                    .disabled(!manager.isLoaded || manager.isBusy)
                }
                Button {
                    navigation.route = .providers
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = manager.loadError { loadingError(error) }
                    if let message = manager.message, message != manager.loadError {
                        Text(message).font(AppTypography.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if manager.connectingID != nil { activeSignIn }
                    accountList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var providerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    navigation.route = .accounts
                } label: {
                    Label("Accounts", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Choose a provider").font(AppTypography.appTitle)
                if let error = manager.loadError { loadingError(error) }
                VStack(spacing: 0) {
                    ForEach(AccountProvider.allCases, id: \.self) { provider in
                        if provider != AccountProvider.allCases.first {
                            Divider().padding(.leading, 52)
                        }
                        providerButton(provider)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .disabled(!canConnect)
                if !manager.isLoaded && manager.loadError == nil {
                    ProgressView("Loading accounts…").controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func providerButton(_ provider: AccountProvider) -> some View {
        Button {
            navigation.choose(provider) { beginSignIn($0) }
        } label: {
            HStack(spacing: 12) {
                AccountProviderIcon(provider: provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider == .qwen ? "Qwen API" : provider.displayName).font(AppTypography.rowTitle)
                    Text(provider == .qwenSubscription ? "Browser sign-in · Plus or Pro" :
                            (provider.usesAPIKey ? "API key" : "Sign in with browser"))
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: provider.usesAPIKey ? "chevron.right" : "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .background(hoveredProvider == provider && canConnect ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredProvider = $0 ? provider : nil }
        .accessibilityElement(children: .combine)
    }

    private func apiKeyPage(_ provider: AccountProvider) -> some View {
        ScrollView {
            APIAccountKeyForm(provider: provider, canConnect: canConnect) { credentials in
                guard canConnect else { return }
                navigation.route = .accounts
                beginSignIn(provider, credentials: credentials)
            } onCancel: {
                navigation.route = .providers
            }
            .padding(20)
        }
    }

    private func beginSignIn(_ provider: AccountProvider, credentials: APIAccountCredentials? = nil) {
        guard canConnect else { return }
        Task { await manager.add(provider: provider, label: "", credentials: credentials) }
    }

    private func loadingError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(error).font(AppTypography.body).fixedSize(horizontal: false, vertical: true)
            Button("Retry Loading") { manager.retryLoading() }
                .controlSize(.small)
                .disabled(manager.isBusy)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var accountList: some View {
        if !manager.isLoaded && manager.loadError == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading accounts…").font(AppTypography.body).foregroundStyle(.secondary)
            }
        } else if manager.accounts.isEmpty && manager.loadError == nil {
            if manager.connectingID == nil {
                VStack(spacing: 9) {
                    Image(systemName: "person.crop.circle").font(.system(size: 26)).accessibilityHidden(true)
                    Text("No accounts yet").font(AppTypography.body)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 55)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(manager.accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        let state = manager.states[account.id]
        return VStack(alignment: .leading, spacing: 8) {
            accountIdentity(account, state: state)
            if let state {
                accountUsage(state, provider: account.provider)
            } else {
                Text("Not refreshed yet").font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Refresh") { Task { await manager.refresh(id: account.id) } }
                    .accessibilityLabel("Refresh \(account.label)")
                    .disabled(manager.isBusy || !manager.isLoaded || manager.connectingID == account.id
                              || state?.status == .refreshing)
                reconnectButton(account)
                    .accessibilityLabel("Reconnect \(account.label)")
                    .disabled(manager.connectingID != nil || manager.isBusy || !manager.isLoaded
                              || state?.status == .refreshing)
                Button("Disconnect") { Task { await manager.disconnect(id: account.id) } }
                    .accessibilityLabel("Disconnect \(account.label), keeping its history")
                    .disabled(manager.isBusy || state?.status == .disconnected || state?.status == .refreshing
                              || manager.connectingID == account.id)
                Spacer(minLength: 0)
                if account.provider != .codex, let updated = state?.updatedAt {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(AppTypography.section).foregroundStyle(.secondary)
                }
            }
            .font(AppTypography.metadata)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder private func reconnectButton(_ account: ManagedAccount) -> some View {
        if account.provider.usesAPIKey {
            APIAccountKeyButton(title: "Reconnect…", provider: account.provider) { credentials in
                Task { await manager.reconnect(id: account.id, credentials: credentials) }
            }
        } else {
            Button("Reconnect") { Task { await manager.reconnect(id: account.id) } }
        }
    }

    private func accountIdentity(_ account: ManagedAccount, state: AccountRowState?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            AccountProviderIcon(provider: account.provider)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(account.label).font(AppTypography.rowTitle).lineLimit(1)
                    if let plan = account.plan, !plan.isEmpty {
                        Text(plan).font(AppTypography.section).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(account.email.map { "\(account.provider.displayName) · \($0)" } ?? account.provider.displayName)
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .help(account.email ?? account.provider.displayName)
            }
            Spacer(minLength: 4)
            Text(statusTitle(state)).font(AppTypography.section).foregroundStyle(.secondary)
            Button {
                renameLabel = account.label
                renameAccount = account
            } label: {
                Image(systemName: "pencil").frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(manager.isBusy || !manager.isLoaded)
            .help("Rename account")
            .accessibilityLabel("Rename \(account.label)")
        }
    }

    private func statusTitle(_ state: AccountRowState?) -> String {
        guard let state else { return "Not refreshed" }
        switch state.status {
        case .connected: return "Connected"
        case .connecting: return "Signing in…"
        case .refreshing: return "Refreshing…"
        case .stale: return state.windows.isEmpty ? "Refresh failed" : "Last known usage"
        case .disconnected: return "Disconnected"
        case .failed: return "Unavailable"
        }
    }

    private func accountUsage(_ state: AccountRowState, provider: AccountProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider == .codex {
                PlanUsageView(windows: state.windows, updatedAt: state.updatedAt)
            }
            if let note = state.note, !note.isEmpty {
                Text(note).font(AppTypography.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.windows.isEmpty && state.status == .connected {
                Text("Plan limits unavailable").font(AppTypography.body).foregroundStyle(.secondary)
            }
        }
    }

    private var activeSignIn: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(signInProgressTitle).font(AppTypography.body)
                Spacer(minLength: 0)
                Button("Cancel") { manager.cancelLogin() }.controlSize(.small)
                    .disabled(manager.committingAPIKey)
            }
            if manager.authorizationURL != nil {
                Button("Open Sign-In Page") { manager.openSignInPage() }.controlSize(.small)
            }
            if manager.connectingProvider == .claude {
                DisclosureGroup("Enter a sign-in code…", isExpanded: $enteringCode) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Only if Claude asks you to paste a code after signing in.")
                            .font(AppTypography.section).foregroundStyle(.secondary)
                        HStack {
                            SecureField("One-time sign-in code", text: $code)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(sendCode)
                            Button("Submit Code", action: sendCode)
                                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.submittingCode)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 5)
                }
                .font(AppTypography.body)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var signInProgressTitle: String {
        guard let provider = manager.connectingProvider else { return "Connecting…" }
        if provider.usesAPIKey { return "Verifying \(provider.displayName) API key…" }
        return "Sign in to \(provider.displayName) in your browser"
    }

    private func sendCode() {
        guard manager.connectingID != nil, !manager.submittingCode,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submitted = code
        code = ""
        Task { await manager.submitCode(submitted) }
    }

    private func renameForm(_ account: ManagedAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Account").font(AppTypography.rowTitle)
            TextField("Label", text: $renameLabel).textFieldStyle(.roundedBorder)
                .onSubmit { saveRename(account) }
            HStack {
                Button("Cancel") { renameAccount = nil }
                Spacer()
                Button("Save") { saveRename(account) }
                    .disabled(manager.isBusy || !manager.isLoaded)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 250)
    }

    private func saveRename(_ account: ManagedAccount) {
        let submitted = renameLabel
        renameAccount = nil
        Task { await manager.rename(id: account.id, label: submitted) }
    }
}

private struct AccountProviderIcon: View {
    let provider: AccountProvider

    var body: some View {
        Group {
            switch provider {
            case .codex:
                AppIcon(bundleId: "com.openai.codex")
            case .claude:
                AppIcon(bundleId: "com.anthropic.claudefordesktop")
            case .deepseek, .qwen, .qwenSubscription:
                Image(systemName: provider == .qwenSubscription ? "person.crop.circle" : "key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .accessibilityHidden(true)
    }
}
