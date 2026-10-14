import Foundation
import Testing
@testable import ConnectSphere

/// Hobby profile details: school search, years, relationship values.
struct HobbyDetailsTests {
    @Test func schoolSearchIgnoresAccentsAndCase() {
        #expect(SchoolCatalog.search("bach khoa ha noi").contains("Đại học Bách khoa Hà Nội"))
        #expect(SchoolCatalog.search("GREENWICH") == ["Đại học Greenwich (Việt Nam)"])
        #expect(SchoolCatalog.search("   ").isEmpty)
    }

    @Test func foldTurnsDIntoD() {
        #expect(SchoolCatalog.fold("Đà Nẵng") == "da nang")
    }

    @Test func yearsText() throws {
        func school(_ s: Int?, _ e: Int?) throws -> Education {
            let json = #"{"id":"e","school_name":"FPT","school_type":"university","major":null,"start_year":\#(s.map(String.init) ?? "null"),"end_year":\#(e.map(String.init) ?? "null")}"#
            return try JSONDecoder().decode(Education.self, from: Data(json.utf8))
        }
        #expect(try school(2020, 2024).yearsText(loc: { $0 }) == "2020 – 2024")
        #expect(try school(2022, nil).yearsText(loc: { $0 }) == "From 2022")
        #expect(try school(nil, 2026).yearsText(loc: { $0 }) == "Class of 2026")
        #expect(try school(nil, nil).yearsText(loc: { $0 }) == nil)
    }

    @Test func relationshipValuesMatchTheServer() {
        #expect(RelationshipStatus.allCases.count == 11)
        #expect(RelationshipStatus(rawValue: "in_relationship") == .inRelationship)
    }

    @MainActor @Test func editorNeedsASchoolAndOrderedYears() {
        let vm = EducationEditorViewModel()
        #expect(!vm.canSave)
        vm.schoolName = "Đại học Greenwich (Việt Nam)"
        #expect(vm.canSave && vm.suggestions.isEmpty)   // an exact pick needs no suggestions
        vm.startYear = 2024; vm.endYear = 2020
        #expect(!vm.canSave && vm.yearsProblem != nil)
    }
}
