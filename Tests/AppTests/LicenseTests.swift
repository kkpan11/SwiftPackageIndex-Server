@testable import App

import XCTVapor

class LicenseTests: XCTestCase {
    
    func test_init_from_dto() throws {
        XCTAssertEqual(License(from: Github.License(key: "mit")), .mit)
        XCTAssertEqual(License(from: Github.License(key: "agpl-3.0")), .agpl_3_0)
        XCTAssertEqual(License(from: Github.License(key: "other")), .other)
        do {
            let none: Github.License? = nil
            XCTAssertEqual(License(from: none), .none)
        }
        do {
            // FIXME: clean up after removing Github.License
            let none: Github._Metadata.LicenseInfo? = nil
            XCTAssertEqual(License(from: none), .none)
        }
    }
    
    func test_init_from_dto_unknown() throws {
        // ensure unknown licenses are mapped to `.other`
        XCTAssertEqual(License(from: Github.License(key: "non-existing license")), .other)
    }
    
    func test_fullName() throws {
        XCTAssertEqual(License.mit.fullName, "MIT License")
        XCTAssertEqual(License.agpl_3_0.fullName, "GNU Affero General Public License v3.0")
        XCTAssertEqual(License.other.fullName, "Unknown License")
        XCTAssertEqual(License.none.fullName, "No License")
    }
    
    func test_shortName() throws {
        XCTAssertEqual(License.mit.shortName, "MIT")
        XCTAssertEqual(License.agpl_3_0.shortName, "AGPL 3.0")
        XCTAssertEqual(License.other.shortName, "Unknown License")
        XCTAssertEqual(License.none.shortName, "No License")
    }
    
    func test_isCompatibleWithAppStore() throws {
        XCTAssertEqual(License.mit.licenseKind, .compatibleWithAppStore)
        XCTAssertEqual(License.agpl_3_0.licenseKind, .incompatibleWithAppStore)
        XCTAssertEqual(License.other.licenseKind, .noneOrUnknown)
        XCTAssertEqual(License.none.licenseKind, .noneOrUnknown)
    }
    
}
