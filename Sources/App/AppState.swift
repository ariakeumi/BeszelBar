import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    static let shared: AppState = {
        #if DEBUG
        if let state = DevelopmentSession.makeState() { return state }
        #endif
        return AppState()
    }()

    private(set) var instances: [Instance] = []
    private(set) var selectedInstance: Instance?
    private(set) var showsAllHubs: Bool
    private(set) var hubSnapshots: [UUID: HubSnapshot] = [:]
    private(set) var connectionRevision = 0

    private let storage: StorageManager
    private let credentials: any CredentialStore
    private let serviceFactory: (Instance) -> any BeszelServing
    @ObservationIgnored private var apiServices: [UUID: any BeszelServing] = [:]
    private enum RefreshResource: String, CaseIterable {
        case systems = "Systems"
        case details = "System details"
        case containers = "Containers"
        case alerts = "Alerts"
    }

    @ObservationIgnored private var refreshTasks: [UUID: [RefreshResource: Task<Void, Never>]] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var isRealtimeEnabled = false
    @ObservationIgnored private var realtimeSubscriptions: [UUID: RealtimeSubscription] = [:]
    @ObservationIgnored private var realtimeSamples: [UUID: [String: RealtimeSystemUpdate]] = [:]
    @ObservationIgnored private var lastPollStarted: [UUID: [RefreshResource: Date]] = [:]

    private struct RealtimeSubscription {
        let id: UUID
        let systemIDs: Set<String>
        let task: Task<Void, Never>
    }

    init(storage: StorageManager = StorageManager(),
         credentials: any CredentialStore = KeychainService.shared,
         serviceFactory: @escaping (Instance) -> any BeszelServing = { BeszelAPIService(instance: $0) }) {
        self.storage = storage
        self.credentials = credentials
        self.serviceFactory = serviceFactory
        showsAllHubs = storage.loadShowsAllHubs()
        instances = storage.loadInstances()
        selectedInstance = instances.first { $0.id == storage.loadSelectedInstanceID() } ?? instances.first
    }

    var visibleInstances: [Instance] {
        showsAllHubs ? instances : selectedInstance.map { [$0] } ?? []
    }
    var scopeTitle: String {
        showsAllHubs ? String(localized: "All Hubs") : selectedInstance?.displayName ?? String(localized: "No Hub Configured")
    }
    var isLoading: Bool { visibleInstances.contains { hubSnapshots[$0.id]?.isLoading == true } }
    var isConfigured: Bool { !instances.isEmpty }
    var visibleSystems: [HubSystem] {
        visibleInstances.flatMap { instance in
            (hubSnapshots[instance.id]?.systems ?? []).map { HubSystem(instance: instance, system: $0, connectionURL: hubSnapshots[instance.id]?.connectedURL) }
        }
    }
    var visibleAlerts: [HubAlert] {
        visibleInstances.flatMap { instance in
            let snapshot = hubSnapshots[instance.id] ?? HubSnapshot()
            return snapshot.alerts.map { alert in
                HubAlert(instance: instance, alert: alert,
                         systemName: snapshot.systems.first { $0.id == alert.system }?.name ?? alert.system ?? String(localized: "Unknown system"))
            }
        }
    }
    var visibleContainers: [HubContainer] {
        visibleInstances.flatMap { instance in
            let snapshot = hubSnapshots[instance.id] ?? HubSnapshot()
            return snapshot.containers.map { container in
                HubContainer(instance: instance, container: container,
                             systemName: snapshot.systems.first { $0.id == container.system }?.name ?? container.system)
            }
        }
    }
    var activeAlerts: [HubAlert] { visibleAlerts.filter { $0.alert.triggered == true } }

    func system(for id: HubRecordID) -> HubSystem? {
        guard let instance = instances.first(where: { $0.id == id.hubID }),
              let system = hubSnapshots[id.hubID]?.systems.first(where: { $0.id == id.recordID }) else { return nil }
        return HubSystem(instance: instance, system: system, connectionURL: hubSnapshots[instance.id]?.connectedURL)
    }

    func refresh() {
        for instance in visibleInstances { refresh(instance) }
    }

    /// The menu timer checks freshness each second. Healthy streams only need
    /// periodic collection reads for membership, status and other metadata.
    func poll(now: Date = Date()) {
        for instance in visibleInstances { refresh(instance, scheduled: true, now: now) }
    }

    func refresh(_ instance: Instance) {
        refresh(instance, scheduled: false, now: Date())
    }

    private func refresh(_ instance: Instance, scheduled: Bool, now: Date) {
        guard instances.contains(where: { $0.id == instance.id }) else { return }
        // A slow optional collection must not hold up the next systems poll.
        // Coalesce each collection independently, sharing a generation until
        // the hub is edited, removed, hidden, or explicitly stopped.
        let generation = generations[instance.id] ?? UUID()
        generations[instance.id] = generation
        let service = getOrCreateService(for: instance)

        for resource in RefreshResource.allCases where refreshTasks[instance.id]?[resource] == nil {
            if scheduled, isRealtimeEnabled, !shouldPoll(resource, hubID: instance.id, now: now) { continue }
            lastPollStarted[instance.id, default: [:]][resource] = now
            hubSnapshots[instance.id, default: HubSnapshot()].isLoading = true
            refreshTasks[instance.id, default: [:]][resource] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generations[instance.id] == generation {
                        self.refreshTasks[instance.id]?[resource] = nil
                        if self.refreshTasks[instance.id]?.isEmpty == true {
                            self.refreshTasks[instance.id] = nil
                        }
                        self.hubSnapshots[instance.id]?.isLoading = self.refreshTasks[instance.id] != nil
                    }
                }
                do {
                    switch resource {
                    case .systems:
                        let systems = try await service.fetchSystems()
                        let endpoint = await service.currentEndpoint()
                        guard self.accepts(instance.id, generation: generation) else { return }
                        self.hubSnapshots[instance.id]?.systems = systems.map {
                            self.freshRealtimeSample(hubID: instance.id, systemID: $0.id)?.applying(to: $0) ?? $0
                        }.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                        self.hubSnapshots[instance.id]?.connectedURL = endpoint
                        self.hubSnapshots[instance.id]?.errorMessage = nil
                        self.hubSnapshots[instance.id]?.lastUpdated = Date()
                        self.reconcileRealtime()
                    case .details:
                        let details = try await service.fetchSystemDetails()
                        guard self.accepts(instance.id, generation: generation) else { return }
                        self.hubSnapshots[instance.id]?.details = Dictionary(details.map { ($0.system, $0) }, uniquingKeysWith: { _, new in new })
                    case .containers:
                        let containers = try await service.fetchContainers(filter: nil)
                        guard self.accepts(instance.id, generation: generation) else { return }
                        self.hubSnapshots[instance.id]?.containers = containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    case .alerts:
                        let alerts = try await service.fetchAlerts(filter: nil)
                        guard self.accepts(instance.id, generation: generation) else { return }
                        self.hubSnapshots[instance.id]?.alerts = alerts.filter { $0.enabled != false }
                    }
                    self.setResourceError(nil, for: resource, hubID: instance.id)
                } catch {
                    guard self.accepts(instance.id, generation: generation) else { return }
                    if resource == .systems {
                        self.hubSnapshots[instance.id]?.errorMessage = error.localizedDescription
                    } else {
                        self.setResourceError(error, for: resource, hubID: instance.id)
                    }
                }
            }
        }
    }

    private func shouldPoll(_ resource: RefreshResource, hubID: UUID, now: Date) -> Bool {
        guard let last = lastPollStarted[hubID]?[resource] else { return true }
        let online = (hubSnapshots[hubID]?.systems ?? []).filter(\.isOnline)
        let allFresh = !online.isEmpty && online.allSatisfy {
            freshRealtimeSample(hubID: hubID, systemID: $0.id, now: now) != nil
        }
        let interval: TimeInterval
        switch resource {
        case .systems: interval = allFresh ? storage.refreshInterval : 1
        case .containers, .details, .alerts: interval = storage.refreshInterval
        }
        return now.timeIntervalSince(last) >= interval - 0.05
    }

    private func freshRealtimeSample(hubID: UUID, systemID: String, now: Date = Date()) -> RealtimeSystemUpdate? {
        guard isRealtimeEnabled, let sample = realtimeSamples[hubID]?[systemID],
              now.timeIntervalSince(sample.receivedAt) < 5 else { return nil }
        return sample
    }

    func setRealtimeEnabled(_ enabled: Bool) {
        isRealtimeEnabled = enabled
        reconcileRealtime()
    }

    private func reconcileRealtime() {
        let visibleIDs = Set(visibleInstances.map(\.id))
        for id in Array(realtimeSubscriptions.keys) where !isRealtimeEnabled || !visibleIDs.contains(id) {
            stopRealtime(for: id)
        }
        guard isRealtimeEnabled else { return }
        for instance in visibleInstances {
            let systemIDs = Set((hubSnapshots[instance.id]?.systems ?? []).filter(\.isOnline).map(\.id))
            if realtimeSubscriptions[instance.id]?.systemIDs == systemIDs { continue }
            stopRealtime(for: instance.id)
            guard !systemIDs.isEmpty else { continue }
            let service = getOrCreateService(for: instance)
            let subscriptionID = UUID()
            let task = Task { [weak self] in
                var retrySeconds = 1
                while !Task.isCancelled {
                    do {
                        guard let updates = try await service.realtimeUpdates(systemIDs: systemIDs.sorted()) else { return }
                        for try await update in updates {
                            guard let self, self.acceptsRealtime(instance.id, subscriptionID: subscriptionID),
                                  systemIDs.contains(update.systemID) else { return }
                            retrySeconds = 1
                            self.applyRealtime(update, hubID: instance.id)
                        }
                    } catch {
                        // Collection polling remains available while the socket
                        // reconnects, including on older hubs without rt_metrics.
                    }
                    guard !Task.isCancelled,
                          self?.acceptsRealtime(instance.id, subscriptionID: subscriptionID) == true else { return }
                    do { try await Task.sleep(for: .seconds(retrySeconds)) }
                    catch { return }
                    retrySeconds = min(retrySeconds * 2, 15)
                }
            }
            realtimeSubscriptions[instance.id] = RealtimeSubscription(id: subscriptionID, systemIDs: systemIDs, task: task)
        }
    }

    private func acceptsRealtime(_ hubID: UUID, subscriptionID: UUID) -> Bool {
        isRealtimeEnabled && realtimeSubscriptions[hubID]?.id == subscriptionID
    }

    private func applyRealtime(_ update: RealtimeSystemUpdate, hubID: UUID) {
        guard var snapshot = hubSnapshots[hubID],
              let index = snapshot.systems.firstIndex(where: { $0.id == update.systemID && $0.isOnline }) else { return }
        realtimeSamples[hubID, default: [:]][update.systemID] = update
        snapshot.systems[index] = update.applying(to: snapshot.systems[index])
        snapshot.lastUpdated = update.receivedAt
        snapshot.errorMessage = nil
        hubSnapshots[hubID] = snapshot
    }

    private func stopRealtime(for hubID: UUID) {
        realtimeSubscriptions.removeValue(forKey: hubID)?.task.cancel()
        realtimeSamples[hubID] = nil
    }

    private func setResourceError(_ error: Error?, for resource: RefreshResource, hubID: UUID) {
        let prefix = "\(String(localized: String.LocalizationValue(resource.rawValue))): "
        hubSnapshots[hubID]?.resourceErrors.removeAll { $0.hasPrefix(prefix) }
        if let error {
            hubSnapshots[hubID]?.resourceErrors.append(prefix + error.localizedDescription)
        }
    }

    func waitForRefresh() async {
        for task in refreshTasks.values.flatMap({ $0.values }) { await task.value }
    }

    func stopRefreshing() {
        setRealtimeEnabled(false)
        for id in Array(refreshTasks.keys) { cancelRefresh(for: id) }
    }

    private func accepts(_ id: UUID, generation: UUID) -> Bool {
        !Task.isCancelled && generations[id] == generation && instances.contains { $0.id == id }
    }

    private func cancelRefresh(for id: UUID) {
        stopRealtime(for: id)
        lastPollStarted[id] = nil
        generations[id] = nil
        if let tasks = refreshTasks.removeValue(forKey: id) {
            for task in tasks.values { task.cancel() }
        }
        hubSnapshots[id]?.isLoading = false
    }

    func selectInstance(_ instance: Instance?) {
        if let instance, !instances.contains(where: { $0.id == instance.id }) { return }
        showsAllHubs = instance == nil
        if let instance { selectedInstance = instances.first { $0.id == instance.id } }
        storage.saveShowsAllHubs(showsAllHubs)
        storage.saveSelectedInstanceID(selectedInstance?.id)
        let visibleIDs = Set(visibleInstances.map(\.id))
        for id in Set(refreshTasks.keys).union(realtimeSubscriptions.keys) where !visibleIDs.contains(id) { cancelRefresh(for: id) }
        refresh()
        reconcileRealtime()
    }

    func addInstance(_ instance: Instance) {
        credentials.saveCredential(instance.credential, for: instance.id.uuidString)
        var stored = instance
        stored.credential = ""
        instances.append(stored)
        if selectedInstance == nil { selectedInstance = stored }
        saveInstances()
        refresh()
    }

    func removeInstance(_ instance: Instance) {
        cancelRefresh(for: instance.id)
        credentials.deleteCredential(for: instance.id.uuidString)
        apiServices[instance.id] = nil
        hubSnapshots[instance.id] = nil
        instances.removeAll { $0.id == instance.id }
        if selectedInstance?.id == instance.id { selectedInstance = instances.first }
        connectionRevision += 1
        saveInstances()
        refresh()
    }

    func updateInstance(_ instance: Instance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        if !instance.credential.isEmpty {
            credentials.saveCredential(instance.credential, for: instance.id.uuidString)
        }
        cancelRefresh(for: instance.id)
        apiServices[instance.id] = nil
        hubSnapshots[instance.id] = nil
        var stored = instance
        stored.credential = ""
        instances[index] = stored
        if selectedInstance?.id == instance.id { selectedInstance = stored }
        connectionRevision += 1
        saveInstances()
        refresh()
    }

    func instanceWithCredential(_ instance: Instance) -> Instance {
        var result = instance
        result.credential = credentials.loadCredential(for: instance.id.uuidString) ?? ""
        return result
    }

    func fetchHistory(for id: HubRecordID, range: HistoryRange, now: Date = Date()) async throws -> [SystemStatsRecord] {
        guard let instance = instances.first(where: { $0.id == id.hubID }) else { throw CancellationError() }
        return try await getOrCreateService(for: instance).fetchHistory(systemID: id.recordID, range: range, now: now)
    }

    func chartService(for id: HubRecordID) throws -> any BeszelServing {
        guard let instance = instances.first(where: { $0.id == id.hubID }) else { throw CancellationError() }
        return getOrCreateService(for: instance)
    }

    private func saveInstances() {
        storage.saveInstances(instances)
        storage.saveSelectedInstanceID(selectedInstance?.id)
    }

    private func getOrCreateService(for instance: Instance) -> any BeszelServing {
        if let service = apiServices[instance.id] { return service }
        let service = serviceFactory(instanceWithCredential(instance))
        apiServices[instance.id] = service
        return service
    }
}

struct Instance: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var email: String
    var credential: String
    var fallbackURL: String

    init(id: UUID = UUID(), name: String, url: String, email: String, credential: String, fallbackURL: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.email = email
        self.credential = credential
        self.fallbackURL = fallbackURL
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, email, fallbackURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        email = try container.decode(String.self, forKey: .email)
        credential = ""
        fallbackURL = try container.decodeIfPresent(String.self, forKey: .fallbackURL) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(email, forKey: .email)
        if !fallbackURL.isEmpty { try container.encode(fallbackURL, forKey: .fallbackURL) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Instance, rhs: Instance) -> Bool {
        lhs.id == rhs.id
    }
}

final class StorageManager {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var refreshInterval: TimeInterval {
        Double(min(max(defaults.object(forKey: "refreshInterval") as? Int ?? 30, 10), 300))
    }

    func loadShowsAllHubs() -> Bool { defaults.bool(forKey: "com.nohitdev.BeszelBar.allHubs") }
    func saveShowsAllHubs(_ value: Bool) { defaults.set(value, forKey: "com.nohitdev.BeszelBar.allHubs") }
    private let instancesKey = "com.nohitdev.BeszelBar.instances"
    private let selectedInstanceKey = "com.nohitdev.BeszelBar.selectedInstance"

    func saveInstances(_ instances: [Instance]) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: instancesKey)
    }

    func loadInstances() -> [Instance] {
        guard let data = defaults.data(forKey: instancesKey),
              let instances = try? JSONDecoder().decode([Instance].self, from: data) else {
            return []
        }
        return instances
    }

    func saveSelectedInstanceID(_ id: UUID?) {
        if let id = id {
            defaults.set(id.uuidString, forKey: selectedInstanceKey)
        } else {
            defaults.removeObject(forKey: selectedInstanceKey)
        }
    }

    func loadSelectedInstanceID() -> UUID? {
        guard let string = defaults.string(forKey: selectedInstanceKey) else { return nil }
        return UUID(uuidString: string)
    }
}
