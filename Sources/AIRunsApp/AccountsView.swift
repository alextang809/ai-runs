import AIRunsCore
import AppKit
import SwiftUI

/// Account sign-ins and measured plan limits. Local token history stays in the
/// main menu and is never presented as an individual account's allowance.
struct ManagedAccountsView: View {
    @ObservedObject var manager: AccountManager
    @State private var provider: AccountProvider = .codex
    @State private var label = ""
    @State private var code = ""
    @State private var enteringCode = false
    @State private var renameAccount: ManagedAccount?
    @State private var renameLabel = ""

    private var maximumHeight: CGFloat {
        max(240, min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
    }

    var body: some View {
        GlassSurface(cornerRadius: 20, fallbackMaterial: .windowBackground) {
            FittedVerticalScroll(maximumHeight: maximumHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let error = manager.loadError { loadingError(error) }
                    if let message = manager.message, message != manager.loadError {
                        Text(message).font(AppTypography.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    accountList
                    if manager.connectingID != nil { activeSignIn }
                    Divider()
                    addAccount
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480)
        .popover(item: $renameAccount) { account in renameForm(account) }
        .onChange(of: manager.connectingID) { _, _ in
            code = ""
            enteringCode = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Accounts").font(AppTypography.appTitle)
                Spacer()
                Button("Refresh All") { manager.refreshAll() }
                    .controlSize(.small)
                    .disabled(!manager.isLoaded || manager.isBusy)
                    .accessibilityLabel("Refresh usage for all saved accounts")
            }
            Text("Separate sign-ins; your existing terminal logins stay unchanged.")
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            Text("Add an account to see its plan usage here.")
                .font(AppTypography.body).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(manager.accounts) { account in
                    accountRow(account)
                    if account.id != manager.accounts.last?.id { Divider() }
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
                    .accessibilityLabel("Refresh plan usage for \(account.label)")
                    .disabled(manager.isBusy || !manager.isLoaded || manager.connectingID == account.id
                              || state?.status == .refreshing)
                Button("Reconnect") { Task { await manager.reconnect(id: account.id) } }
                    .accessibilityLabel("Reconnect \(account.label)")
                    .disabled(manager.connectingID != nil || manager.isBusy || !manager.isLoaded
                              || state?.status == .refreshing)
                Button("Disconnect") { Task { await manager.disconnect(id: account.id) } }
                    .accessibilityLabel("Disconnect \(account.label), keeping its history")
                    .disabled(manager.isBusy || state?.status == .disconnected || manager.connectingID == account.id)
                Spacer(minLength: 0)
                if let updated = state?.updatedAt {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(AppTypography.section).foregroundStyle(.secondary)
                }
            }
            .font(AppTypography.metadata)
            .controlSize(.small)
        }
    }

    private func accountIdentity(_ account: ManagedAccount, state: AccountRowState?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            AppIcon(bundleId: account.provider == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop")
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
        case .stale: return "Last known usage"
        case .disconnected: return "Disconnected"
        case .failed: return "Unavailable"
        }
    }

    private func accountUsage(_ state: AccountRowState, provider: AccountProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.title)
                        Spacer()
                        Text("\(window.usedPercent, specifier: "%.0f")% used").monospacedDigit()
                    }
                    .font(AppTypography.body)
                    ProgressView(value: window.usedPercent, total: 100)
                        .tint(Palette.tool(provider == .codex ? .codex : .claudeCode))
                        .accessibilityLabel(window.title)
                        .accessibilityValue("\(Int(window.usedPercent.rounded())) percent used")
                    if let reset = window.resetsAt {
                        Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTypography.section).foregroundStyle(.secondary)
                    }
                }
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
                Text("Complete sign-in in your browser.").font(AppTypography.body)
                Spacer(minLength: 0)
                Button("Cancel") { manager.cancelLogin() }.controlSize(.small)
            }
            if manager.authorizationURL != nil {
                Button("Open Sign-In Page") { manager.openSignInPage() }.controlSize(.small)
            }
            if manager.accounts.first(where: { $0.id == manager.connectingID })?.provider == .claude {
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

    private func sendCode() {
        guard manager.connectingID != nil, !manager.submittingCode,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submitted = code
        code = ""
        Task { await manager.submitCode(submitted) }
    }

    private var addAccount: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Add Account").font(AppTypography.rowTitle)
            HStack(spacing: 8) {
                Picker("Provider", selection: $provider) {
                    ForEach(AccountProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityLabel("Account provider")
                TextField("Label (optional)", text: $label).textFieldStyle(.roundedBorder)
                    .onSubmit(signIn)
                Button("Sign In", action: signIn)
            }
            .controlSize(.small)
            .disabled(!manager.isLoaded || manager.isBusy || manager.connectingID != nil)
        }
    }

    private func signIn() {
        guard manager.isLoaded, !manager.isBusy, manager.connectingID == nil else { return }
        let selected = provider, submittedLabel = label
        label = ""
        Task { await manager.add(provider: selected, label: submittedLabel) }
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
