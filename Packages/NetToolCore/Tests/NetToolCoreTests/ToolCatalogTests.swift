import Testing

@testable import NetToolCore

@Suite("Tool catalog")
struct ToolCatalogTests {
    @Test("Every tool has a unique identifier")
    func identifiersAreUnique() {
        let identifiers = ToolCatalog.all.map(\.id)

        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("Every category contains at least one tool")
    func categoriesArePopulated() {
        for category in ToolCategory.allCases {
            #expect(!ToolCatalog.tools(in: category).isEmpty)
        }
    }

    @Test("Ping is the first tool")
    func pingIsFirst() {
        #expect(ToolCatalog.all.first?.id == "ping")
    }

    @Test("Catalog contains every implemented tool")
    func containsImplementedTools() {
        #expect(
            Set(ToolCatalog.all.map(\.id))
                == Set(
                    [
                        "ping",
                        "traceroute",
                        "tcp",
                        "port-scan",
                        "dns",
                        "tls",
                        "http",
                        "network-info"
                    ]
                )
        )
    }
}
