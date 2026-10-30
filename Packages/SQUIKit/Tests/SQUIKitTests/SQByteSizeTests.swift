import Foundation
import Testing
@testable import SQUIKit

@Suite struct SQByteSizeTests {
    @Test func usesDecimalPointAndFileUnits() {
        #expect(SQByteSize.string(25_900_000) == "25.9 MB")
        #expect(SQByteSize.string(1_500_000_000) == "1.5 GB")
        #expect(!SQByteSize.string(2_345_678).contains(","))
    }
}
