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

    @Test("Ping is the first available tool")
    func pingIsAvailable() {
        #expect(ToolCatalog.all.first?.id == "ping")
        #expect(ToolCatalog.all.first?.availability == .available)
    }

    @Test("DNS is available in Step 2")
    func dnsIsAvailable() throws {
        let dns = try #require(
            ToolCatalog.all.first { $0.id == "dns" }
        )

        #expect(dns.availability == .available)
    }
}
