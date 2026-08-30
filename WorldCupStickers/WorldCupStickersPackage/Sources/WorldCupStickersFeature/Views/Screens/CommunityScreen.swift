import SwiftData
import SwiftUI

@MainActor
struct CommunityScreen: View {
    @Environment(CommunityStore.self) private var communityStore
    @Environment(SupabaseAccountStore.self) private var accountStore
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @Query(sort: \CollectionMutation.createdAt, order: .forward) private var mutations: [CollectionMutation]

    @State private var section: CommunitySection = .people
    @State private var searchText = ""
    @State private var isAccountSheetPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if isSignedIn {
                    signedInContent
                } else {
                    signedOutContent
                }
            }
            .background(StickerBackdrop())
            .navigationTitle("Trade")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await communityStore.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh trade activity")
                        .disabled(communityStore.isRefreshing || communityStore.isPerformingAction)
                    }
                }
            }
            .task(id: accountStore.currentUserID) {
                guard isSignedIn else { return }
                await communityStore.refresh()
            }
            .sheet(isPresented: $isAccountSheetPresented) {
                AccountSheet()
            }
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = accountStore.state { return true }
        return false
    }

    private var signedInContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                profileReadiness

                Picker("Trade section", selection: $section) {
                    ForEach(CommunitySection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .people:
                    peopleContent
                case .friends:
                    friendsContent
                case .trades:
                    tradesContent
                }

                if let error = communityStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .refreshable {
            await communityStore.refresh()
        }
    }

    private var signedOutContent: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: "person.2.badge.gearshape.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.stickerTeal)

            Text("Trade with collectors")
                .font(.title2.weight(.bold))

            Text("Create a profile, find collectors by username, compare duplicates, and send a trade request. Your album stays private until you choose what to share.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isAccountSheetPresented = true
            } label: {
                Label("Set up your profile", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
            Spacer()
        }
        .padding(28)
    }

    @ViewBuilder
    private var profileReadiness: some View {
        if accountStore.profile?.handle == nil {
            CommunityCallout(
                title: "Pick a username to trade",
                message: "Your handle lets friends find you. You can keep it hidden from search until you are ready.",
                systemImage: "at"
            ) {
                Button("Set up profile") { isAccountSheetPresented = true }
                    .buttonStyle(.bordered)
                    .tint(.stickerTeal)
            }
        } else if accountStore.lastSyncedAt == nil {
            CommunityCallout(
                title: "Sync your collection before trading",
                message: "Trade offers are checked against your cloud duplicates so nobody promises a sticker they no longer have.",
                systemImage: "arrow.triangle.2.circlepath.icloud"
            ) {
                Button {
                    Task {
                        await accountStore.syncNow(
                            ownedStickers: ownedStickers,
                            mutations: mutations,
                            visibility: syncStatus.selectedVisibility,
                            catalog: catalog,
                            context: modelContext
                        )
                        await communityStore.refresh()
                    }
                } label: {
                    Label(accountStore.isBusy ? "Syncing…" : "Sync collection", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .tint(.stickerTeal)
                .disabled(accountStore.isBusy)
            }
        }
    }

    private var peopleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find collectors")
                .font(.title3.weight(.bold))

            Text("Search a username such as @username. Only collectors who opt in to discovery appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("@username", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { searchPeople() }
                    .padding(13)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                Button {
                    searchPeople()
                } label: {
                    if communityStore.isSearching {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || communityStore.isSearching)
            }

            if communityStore.searchResults.isEmpty, !searchText.isEmpty, !communityStore.isSearching {
                CommunityEmptyState(
                    title: "No matching collectors",
                    message: "Try more of their username, or ask them to enable discovery in their profile.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            } else {
                ForEach(communityStore.searchResults) { profile in
                    NavigationLink {
                        CommunityProfileScreen(profileID: profile.id, initialProfile: profile)
                    } label: {
                        CommunityProfileRow(profile: profile)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var friendsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let incoming = communityStore.friendships.filter { $0.status == .pending && !$0.requestedByMe }
            let outgoing = communityStore.friendships.filter { $0.status == .pending && $0.requestedByMe }
            let accepted = communityStore.friendships.filter { $0.status == .accepted }
            let blocked = communityStore.friendships.filter { $0.status == .blocked }

            if communityStore.isRefreshing && communityStore.friendships.isEmpty {
                ProgressView("Loading friends…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if incoming.isEmpty && outgoing.isEmpty && accepted.isEmpty && blocked.isEmpty {
                CommunityEmptyState(
                    title: "No friends yet",
                    message: "Find a collector by username and send a request. Friends can share their duplicate lists for trades.",
                    systemImage: "person.2"
                )
            } else {
                if !incoming.isEmpty {
                    CommunitySectionHeader("Requests for you")
                    ForEach(incoming) { friendship in
                        CommunityFriendshipRow(friendship: friendship) {
                            Task { await communityStore.transitionFriendship(friendship.id, action: .accept) }
                        } secondaryAction: {
                            Task { await communityStore.transitionFriendship(friendship.id, action: .decline) }
                        }
                    }
                }

                if !accepted.isEmpty {
                    CommunitySectionHeader("Friends")
                    ForEach(accepted) { friendship in
                        NavigationLink {
                            CommunityProfileScreen(profileID: friendship.profileID, initialProfile: nil)
                        } label: {
                            CommunityFriendshipRow(friendship: friendship)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !outgoing.isEmpty {
                    CommunitySectionHeader("Sent requests")
                    ForEach(outgoing) { friendship in
                        CommunityFriendshipRow(friendship: friendship) {
                            Task { await communityStore.transitionFriendship(friendship.id, action: .cancel) }
                        }
                    }
                }

                if !blocked.isEmpty {
                    CommunitySectionHeader("Blocked")
                    ForEach(blocked) { friendship in
                        CommunityFriendshipRow(friendship: friendship) {
                            Task { await communityStore.transitionFriendship(friendship.id, action: .unblock) }
                        }
                    }
                }
            }
        }
    }

    private var tradesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if communityStore.isRefreshing && communityStore.exchanges.isEmpty {
                ProgressView("Loading trades…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if communityStore.exchanges.isEmpty {
                CommunityEmptyState(
                    title: "No trade requests",
                    message: "Open a friend's profile, compare duplicates, and send a proposal when you find a match.",
                    systemImage: "arrow.left.arrow.right"
                )
            } else {
                ForEach(communityStore.exchanges) { exchange in
                    CommunityExchangeCard(exchange: exchange) { action in
                        Task { await communityStore.transitionExchange(exchange.id, action: action) }
                    }
                }
            }
        }
    }

    private func searchPeople() {
        Task { await communityStore.searchProfiles(matching: searchText) }
    }
}

@MainActor
private struct CommunityProfileScreen: View {
    @Environment(CommunityStore.self) private var communityStore

    let profileID: UUID
    let initialProfile: CommunityProfile?

    @State private var profile: CommunityProfile?
    @State private var visibleDuplicates: [CommunityCollectionSticker] = []
    @State private var isLoading = false
    @State private var isTradeComposerPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let profile {
                    profileHeader(profile)
                    friendshipActions(profile)
                    duplicateSection(profile)
                } else if isLoading {
                    ProgressView("Loading profile…")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    CommunityEmptyState(
                        title: "Profile unavailable",
                        message: "This profile may no longer be discoverable, or you may not have access to it.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                }
            }
            .padding(16)
        }
        .background(StickerBackdrop())
        .navigationTitle(profile?.displayHandle ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profileID) {
            await loadProfile()
        }
        .sheet(isPresented: $isTradeComposerPresented) {
            if let profile {
                CommunityTradeComposer(recipient: profile, requestedCandidates: visibleDuplicates)
            }
        }
    }

    private func profileHeader(_ profile: CommunityProfile) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CommunityAvatar(url: profile.avatarURL, name: profile.displayName, size: 66)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.stickerInk)
                Text(profile.displayHandle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.stickerTeal)
                Label(profile.duplicateVisibility.title + " duplicates", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .stickerCard()
    }

    @ViewBuilder
    private func friendshipActions(_ profile: CommunityProfile) -> some View {
        switch profile.friendshipStatus {
        case nil:
            Button {
                Task {
                    await communityStore.createFriendship(with: profile.id)
                    await loadProfile()
                }
            } label: {
                Label("Add friend", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
            .disabled(communityStore.isPerformingAction)

        case .pending where profile.requestedByMe:
            Button {
                guard let friendshipID = profile.friendshipID else { return }
                Task {
                    await communityStore.transitionFriendship(friendshipID, action: .cancel)
                    await loadProfile()
                }
            } label: {
                Label("Request sent — Cancel", systemImage: "clock.badge.xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.stickerTeal)

        case .pending:
            HStack {
                Button {
                    guard let friendshipID = profile.friendshipID else { return }
                    Task {
                        await communityStore.transitionFriendship(friendshipID, action: .accept)
                        await loadProfile()
                    }
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)

                Button("Decline", role: .destructive) {
                    guard let friendshipID = profile.friendshipID else { return }
                    Task {
                        await communityStore.transitionFriendship(friendshipID, action: .decline)
                        await loadProfile()
                    }
                }
                .buttonStyle(.bordered)
            }

        case .accepted:
            if profile.canViewDuplicates {
                Button {
                    isTradeComposerPresented = true
                } label: {
                    Label("Propose a trade", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
            } else {
                Label("You are friends, but this collector is not sharing duplicates with you.", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

        case .blocked:
            Button {
                guard let friendshipID = profile.friendshipID else { return }
                Task {
                    await communityStore.transitionFriendship(friendshipID, action: .unblock)
                    await loadProfile()
                }
            } label: {
                Label("Unblock", systemImage: "person.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func duplicateSection(_ profile: CommunityProfile) -> some View {
        if profile.canViewDuplicates {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Available duplicates")
                        .font(.headline)
                    Spacer()
                    Text("\(visibleDuplicates.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.stickerTeal)
                }

                if visibleDuplicates.isEmpty {
                    Text("No duplicate stickers are available right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                } else {
                    ForEach(visibleDuplicates) { sticker in
                        CommunityStickerRow(sticker: sticker)
                    }
                }
            }
        }
    }

    private func loadProfile() async {
        isLoading = true
        defer { isLoading = false }

        let loaded = await communityStore.profile(for: profileID) ?? initialProfile
        profile = loaded
        if let loaded, loaded.canViewDuplicates {
            visibleDuplicates = await communityStore.visibleCollection(for: loaded.id)
        } else {
            visibleDuplicates = []
        }
    }
}

@MainActor
private struct CommunityTradeComposer: View {
    @Environment(CommunityStore.self) private var communityStore
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]

    let recipient: CommunityProfile
    let requestedCandidates: [CommunityCollectionSticker]

    @State private var offeredIDs: Set<String> = []
    @State private var requestedIDs: Set<String> = []
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        CommunityAvatar(url: recipient.avatarURL, name: recipient.displayName, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Trade with \(recipient.displayName)")
                                .font(.headline)
                            Text(recipient.displayHandle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("You offer") {
                    if offerCandidates.isEmpty {
                        Text("You need at least one duplicate before you can offer a trade.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(offerCandidates) { candidate in
                            Toggle(isOn: selectionBinding(for: candidate.id, selection: $offeredIDs)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.displayCode).font(.caption.weight(.bold)).foregroundStyle(Color.stickerTeal)
                                    Text(candidate.name)
                                    Text("\(candidate.availableCopies) duplicate\(candidate.availableCopies == 1 ? "" : "s") available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("You request") {
                    ForEach(requestedCandidates) { candidate in
                        Toggle(isOn: selectionBinding(for: candidate.id, selection: $requestedIDs)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayCode).font(.caption.weight(.bold)).foregroundStyle(Color.stickerTeal)
                                Text(candidate.name)
                                Text("\(candidate.duplicateCount) duplicate\(candidate.duplicateCount == 1 ? "" : "s") available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Message (optional)") {
                    TextField("e.g. Want to swap at the match?", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Text("Sending a request does not change either collection. Both collectors confirm after the physical swap is complete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            await communityStore.createExchange(
                                recipientID: recipient.id,
                                message: message,
                                offeredItems: offeredIDs.map { CommunityTradeDraftItem(stickerID: $0) },
                                requestedItems: requestedIDs.map { CommunityTradeDraftItem(stickerID: $0) }
                            )
                            if communityStore.lastError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(offeredIDs.isEmpty || requestedIDs.isEmpty || communityStore.isPerformingAction)
                }
            }
        }
    }

    private var offerCandidates: [CommunityLocalTradeCandidate] {
        ownedStickers.compactMap { owned in
            guard owned.quantity > 1, let definition = catalog.sticker(id: owned.stickerID) else { return nil }
            return CommunityLocalTradeCandidate(
                id: owned.stickerID,
                displayCode: definition.displayCode,
                name: definition.name,
                availableCopies: owned.quantity - 1
            )
        }
        .sorted { $0.displayCode < $1.displayCode }
    }

    private func selectionBinding(for stickerID: String, selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(stickerID) },
            set: { isSelected in
                if isSelected {
                    selection.wrappedValue.insert(stickerID)
                } else {
                    selection.wrappedValue.remove(stickerID)
                }
            }
        )
    }
}

private struct CommunityLocalTradeCandidate: Identifiable {
    let id: String
    let displayCode: String
    let name: String
    let availableCopies: Int
}

private enum CommunitySection: String, CaseIterable, Identifiable {
    case people
    case friends
    case trades

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: "People"
        case .friends: "Friends"
        case .trades: "Trades"
        }
    }
}

@MainActor
private struct CommunityProfileRow: View {
    let profile: CommunityProfile

    var body: some View {
        HStack(spacing: 12) {
            CommunityAvatar(url: profile.avatarURL, name: profile.displayName, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.stickerInk)
                Text(profile.displayHandle)
                    .font(.subheadline)
                    .foregroundStyle(Color.stickerTeal)
                if let label = profile.friendshipLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .stickerCard()
    }
}

@MainActor
private struct CommunityFriendshipRow: View {
    let friendship: CommunityFriendship
    var primaryAction: (() -> Void)? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            CommunityAvatar(url: friendship.avatarURL, name: friendship.displayName, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(friendship.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.stickerInk)
                Text(friendship.displayHandle)
                    .font(.subheadline)
                    .foregroundStyle(Color.stickerTeal)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.bordered)
                    .tint(.stickerTeal)
            }
            if let secondaryAction {
                Button(secondaryTitle, role: .destructive, action: secondaryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .stickerCard()
    }

    private var statusLabel: String {
        switch friendship.status {
        case .accepted: "Friends"
        case .blocked: "Blocked"
        case .pending: friendship.requestedByMe ? "Request sent" : "Wants to connect"
        }
    }

    private var primaryTitle: String {
        switch friendship.status {
        case .accepted: "View"
        case .blocked: "Unblock"
        case .pending: friendship.requestedByMe ? "Cancel" : "Accept"
        }
    }

    private var secondaryTitle: String {
        friendship.status == .pending ? "Decline" : ""
    }
}

@MainActor
private struct CommunityExchangeCard: View {
    let exchange: CommunityExchange
    let onAction: (CommunityExchangeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                CommunityAvatar(url: exchange.counterpartAvatarURL, name: exchange.counterpartDisplayName, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.direction == .incoming ? "Trade request from \(exchange.counterpartDisplayName)" : "Trade request to \(exchange.counterpartDisplayName)")
                        .font(.headline)
                        .foregroundStyle(Color.stickerInk)
                    Text(exchange.counterpartDisplayHandle)
                        .font(.caption)
                        .foregroundStyle(Color.stickerTeal)
                }
                Spacer()
                Text(exchange.status.rawValue.capitalized)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            TradeLineSummary(title: "They offer", items: exchange.direction == .incoming ? exchange.offeredItems : exchange.requestedItems)
            TradeLineSummary(title: "You offer", items: exchange.direction == .incoming ? exchange.requestedItems : exchange.offeredItems)

            if let message = exchange.message, !message.isEmpty {
                Text("“\(message)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            actionControls
        }
        .padding(15)
        .stickerCard()
    }

    @ViewBuilder
    private var actionControls: some View {
        switch exchange.status {
        case .pending where exchange.direction == .incoming:
            HStack {
                Button("Accept") { onAction(.accept) }
                    .buttonStyle(.borderedProminent)
                    .tint(.stickerTeal)
                Button("Decline", role: .destructive) { onAction(.decline) }
                    .buttonStyle(.bordered)
            }
        case .pending:
            Button("Cancel request", role: .destructive) { onAction(.cancel) }
                .buttonStyle(.bordered)
        case .accepted:
            VStack(alignment: .leading, spacing: 8) {
                Text(exchange.currentUserConfirmed ? "You confirmed the handoff. Waiting for the other collector." : "After the physical swap, both collectors confirm the handoff here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if !exchange.currentUserConfirmed {
                        Button("Confirm handoff") { onAction(.confirmCompletion) }
                            .buttonStyle(.borderedProminent)
                            .tint(.stickerTeal)
                    }
                    Button("Cancel", role: .destructive) { onAction(.cancel) }
                        .buttonStyle(.bordered)
                }
            }
        case .declined, .cancelled, .completed:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch exchange.status {
        case .pending: .stickerOrange
        case .accepted: .stickerTeal
        case .completed: .green
        case .declined, .cancelled: .secondary
        }
    }
}

private struct TradeLineSummary: View {
    let title: String
    let items: [CommunityTradeLineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(items.map { "\($0.displayCode) ×\($0.quantity)" }.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(Color.stickerInk)
                .lineLimit(2)
        }
    }
}

@MainActor
private struct CommunityStickerRow: View {
    let sticker: CommunityCollectionSticker

    var body: some View {
        HStack(spacing: 11) {
            if let imageURL = sticker.imageURL {
                CachedAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        stickerPlaceholder
                    }
                }
                .frame(width: 42, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                stickerPlaceholder
                    .frame(width: 42, height: 56)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(sticker.displayCode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.stickerTeal)
                Text(sticker.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.stickerInk)
                Text("\(sticker.duplicateCount) duplicate\(sticker.duplicateCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stickerPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.stickerTeal.opacity(0.14))
            Text(sticker.displayCode)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.stickerTeal)
        }
    }
}

@MainActor
private struct CommunityAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.stickerTeal.opacity(0.13))
            if let url {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
    }

    private var fallback: some View {
        Text(name.first.map(String.init)?.uppercased() ?? "?")
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(Color.stickerTeal)
    }
}

private struct CommunityCallout<Accessory: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.stickerTeal)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            accessory
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stickerTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct CommunityEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.stickerTeal)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct CommunitySectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}
