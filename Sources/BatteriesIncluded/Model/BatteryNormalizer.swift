import Foundation

struct BatteryNormalizer: Sendable {
    func normalize(_ observations: [BatteryObservation], now: Date = .now) -> [DeviceBattery] {
        var grouped: [String: [BatteryObservation]] = [:]

        for observation in observations where observation.isConnected {
            let key = groupingKey(for: observation)
            grouped[key, default: []].append(observation)
        }

        mergeUniqueCrossSourceGroupsByName(&grouped)

        return grouped.values.map { observations in
            makeDevice(from: observations, now: now)
        }.sorted {
            let leftName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if leftName != .orderedSame {
                return leftName == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func groupingKey(for observation: BatteryObservation) -> String {
        if let stableID = observation.stableID {
            return "stable:\(stableID)"
        }
        return "\(observation.source.rawValue):\(observation.sourceID)"
    }

    private func mergeUniqueCrossSourceGroupsByName(
        _ grouped: inout [String: [BatteryObservation]]
    ) {
        var keysByName: [String: [String]] = [:]
        for (key, values) in grouped {
            guard let name = values.first(where: { !$0.name.isEmpty })?.name else { continue }
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedName.isEmpty else { continue }
            keysByName[normalizedName, default: []].append(key)
        }

        for keys in keysByName.values where keys.count >= 2 {
            let keyedClasses = keys.compactMap { key -> (String, Int)? in
                guard let values = grouped[key], let sourceClass = sourceClass(for: values) else {
                    return nil
                }
                return (key, sourceClass)
            }
            guard keyedClasses.count == keys.count,
                  Set(keyedClasses.map(\.1)).count == keyedClasses.count else { continue }

            let anchor = keyedClasses.min { $0.1 < $1.1 }!.0
            for key in keyedClasses.map(\.0) where key != anchor {
                grouped[anchor, default: []].append(
                    contentsOf: grouped.removeValue(forKey: key) ?? []
                )
            }
        }
    }

    private func sourceClass(for observations: [BatteryObservation]) -> Int? {
        let sources = Set(observations.map(\.source))
        if !sources.isDisjoint(with: [.system, .systemProfiler]) &&
            sources.isSubset(of: [.system, .systemProfiler]) { return 0 }
        if sources == [.coreBluetooth] { return 1 }
        if sources == [.logitechHID] { return 2 }
        return nil
    }

    private func makeDevice(from observations: [BatteryObservation], now: Date) -> DeviceBattery {
        let newestFirst = observations.enumerated().sorted { left, right in
            if left.element.observedAt != right.element.observedAt {
                return left.element.observedAt > right.element.observedAt
            }
            return left.offset < right.offset
        }.map(\.element)

        let name = newestFirst.first(where: { !$0.name.isEmpty })?.name ?? "Unknown Device"
        let category = newestFirst.compactMap(\.category).first ?? .other

        var selected: [BatteryComponent: BatteryObservation] = [:]
        for observation in newestFirst where isValid(observation, now: now) {
            guard let existing = selected[observation.component] else {
                selected[observation.component] = observation
                continue
            }
            if isPreferred(observation, over: existing) {
                selected[observation.component] = observation
            }
        }

        let headphoneComponents: [BatteryComponent] = [.left, .right, .case]
        let hasExplicitComponents = newestFirst.contains {
            $0.component != .whole && $0.source != .system && isValid($0, now: now)
        }
        if category == .headphones,
           let wholePercentage = selected[.whole]?.percentage, wholePercentage > 0,
           !hasExplicitComponents,
           headphoneComponents.allSatisfy({
               selected[$0]?.source == .system && selected[$0]?.percentage == 0
           }) {
            // Generic Bluetooth selectors can expose placeholder zeros for headphones
            // with one battery. Prefer the positive overall reading in that case.
            for component in headphoneComponents {
                selected.removeValue(forKey: component)
            }
        }

        if selected.keys.contains(where: { $0 != .whole }) {
            selected.removeValue(forKey: .whole)
        }

        let levels = selected.compactMap { component, observation in
            observation.percentage.map { (component: component, percentage: $0) }
        }
            .sorted { $0.component < $1.component }
        let coarseLevel = levels.isEmpty ? selected[.whole]?.coarseLevel : nil
        // Status may be available even when another source supplies a better level.
        // Keep the newest explicit report, including unknown, so old charging flags
        // cannot survive a newer report that no longer confirms them.
        let chargingState = selected.keys.contains(where: { $0 != .whole }) ? nil :
            newestFirst.first(where: {
                $0.component == .whole && $0.chargingState != nil &&
                now.timeIntervalSince($0.observedAt) <= 60
            })?.chargingState

        return DeviceBattery(
            id: normalizedID(for: observations[0]),
            name: name,
            category: category,
            levels: levels,
            coarseLevel: coarseLevel,
            chargingState: chargingState
        )
    }

    private func normalizedID(for observation: BatteryObservation) -> String {
        if let stableID = observation.stableID {
            return "stable:\(stableID)"
        }
        return "\(observation.source.rawValue):\(observation.sourceID)"
    }

    private func isValid(_ observation: BatteryObservation, now: Date) -> Bool {
        guard observation.percentage.map({ (0...100).contains($0) }) == true ||
              observation.coarseLevel != nil else {
            return false
        }
        let age = now.timeIntervalSince(observation.observedAt)
        return age <= 60
    }

    private func isPreferred(_ candidate: BatteryObservation, over existing: BatteryObservation) -> Bool {
        if (candidate.percentage != nil) != (existing.percentage != nil) {
            return candidate.percentage != nil
        }
        if candidate.source == .systemProfiler || existing.source == .systemProfiler {
            return candidate.source.rawValue > existing.source.rawValue
        }
        let difference = abs(candidate.observedAt.timeIntervalSince(existing.observedAt))
        if difference <= 1 {
            if candidate.source.rawValue != existing.source.rawValue {
                return candidate.source.rawValue > existing.source.rawValue
            }
        }
        return candidate.observedAt > existing.observedAt
    }
}
