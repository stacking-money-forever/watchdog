import Foundation

struct PackageMarker: Codable, Equatable, Sendable {
    var marker: String
    var agent: String
}

struct AgentRules: Codable, Equatable, Sendable {
    var agentNames: [String]
    var packageMarkers: [PackageMarker]
    var serviceSubcommands: [String]
    var sessionHosts: [String]
    var ignoreNames: [String]

    static let fileEnvironmentKey = "WATCHDOG_RULES_PATH"

    enum LoadResult: Equatable, Sendable {
        case loaded(AgentRules, URL)
        case absent(URL)
        case invalid(URL, String)
    }

    enum CodingKeys: String, CodingKey {
        case agentNames
        case packageMarkers
        case serviceSubcommands
        case sessionHosts
        case ignoreNames
    }

    init(
        agentNames: [String] = [],
        packageMarkers: [PackageMarker] = [],
        serviceSubcommands: [String] = [],
        sessionHosts: [String] = [],
        ignoreNames: [String] = []
    ) {
        self.agentNames = agentNames
        self.packageMarkers = packageMarkers
        self.serviceSubcommands = serviceSubcommands
        self.sessionHosts = sessionHosts
        self.ignoreNames = ignoreNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentNames = try container.decodeIfPresent([String].self, forKey: .agentNames) ?? []
        packageMarkers = try container.decodeIfPresent([PackageMarker].self, forKey: .packageMarkers) ?? []
        serviceSubcommands = try container.decodeIfPresent([String].self, forKey: .serviceSubcommands) ?? []
        sessionHosts = try container.decodeIfPresent([String].self, forKey: .sessionHosts) ?? []
        ignoreNames = try container.decodeIfPresent([String].self, forKey: .ignoreNames) ?? []
    }

    var appliedCount: Int {
        agentNames.count
            + packageMarkers.count
            + serviceSubcommands.count
            + sessionHosts.count
            + ignoreNames.count
    }

    static func standardURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[fileEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Watchdog/agent-rules.json")
    }

    enum WriteError: Error, LocalizedError, Equatable {
        case alreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case let .alreadyExists(url):
                "이미 있습니다: \(url.path)"
            }
        }
    }

    /// Same example payload as `watchdog-cli rules init`.
    static func writeTemplate(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw WriteError.alreadyExists(url)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let example: [String: Any] = [
            "_comment": "Watchdog 사용자 규칙. agentNames에 없는 에이전트 CLI 이름을 추가합니다.",
            "agentNames": ["my-agent"],
            "packageMarkers": [["marker": "/@example/my-agent/", "agent": "my-agent"]],
            "serviceSubcommands": [] as [String],
            "sessionHosts": [] as [String],
            "ignoreNames": [] as [String],
        ]
        let data = try JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> LoadResult {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .absent(url)
        }
        do {
            let data = try Data(contentsOf: url)
            let rules = try JSONDecoder().decode(AgentRules.self, from: data)
            return .loaded(rules, url)
        } catch {
            return .invalid(url, error.localizedDescription)
        }
    }

    func validationIssues() -> [String] {
        var issues: [String] = []

        func checkList(_ values: [String], field: String, slashForbidden: Bool) {
            var seen: Set<String> = []
            for value in values {
                if value.isEmpty {
                    issues.append("\(field)에 빈 문자열이 있습니다")
                    continue
                }
                if value.contains(where: \.isWhitespace) {
                    issues.append("\(field)에 공백이 포함된 이름이 있습니다: \(value)")
                }
                if slashForbidden, value.contains("/") {
                    issues.append("\(field)에 '/'가 있습니다: \(value)")
                }
                if !seen.insert(value.lowercased()).inserted {
                    issues.append("\(field)에 중복된 이름이 있습니다: \(value)")
                }
            }
        }

        checkList(agentNames, field: "agentNames", slashForbidden: true)
        checkList(serviceSubcommands, field: "serviceSubcommands", slashForbidden: false)
        checkList(sessionHosts, field: "sessionHosts", slashForbidden: false)
        checkList(ignoreNames, field: "ignoreNames", slashForbidden: false)

        var seenMarkers: Set<String> = []
        for marker in packageMarkers {
            if marker.marker.isEmpty || marker.agent.isEmpty {
                issues.append("packageMarkers에 빈 문자열이 있습니다")
            }
            if marker.marker.contains(where: \.isWhitespace) || marker.agent.contains(where: \.isWhitespace) {
                issues.append("packageMarkers에 공백이 포함된 이름이 있습니다: \(marker.marker) → \(marker.agent)")
            }
            let key = marker.marker.lowercased()
            if !seenMarkers.insert(key).inserted {
                issues.append("packageMarkers에 중복된 이름이 있습니다: \(marker.marker)")
            }
        }

        let ignored = Set(ignoreNames.map { $0.lowercased() }.filter { !$0.isEmpty })
        for name in agentNames where ignored.contains(name.lowercased()) {
            issues.append("ignoreNames와 agentNames가 충돌합니다: \(name)")
        }
        return issues
    }
}
