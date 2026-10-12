import Foundation
@testable import KeystivoInput
import Testing

@Suite("Key remap merging")
struct KeyRemapMergingTests {
    @Test func deviceMappingKeepsGlobalOnesItDoesNotOverride() {
        let caps: UInt64 = 0x39, escape: UInt64 = 0x29, f18: UInt64 = 0x6D, grave: UInt64 = 0x35, section: UInt64 = 0x64
        let merged = KeyRemapper.merged(global: [(caps, f18), (section, grave)], device: [(caps, escape)])
        #expect(merged.map(\.0) == [section, caps])
        #expect(merged.first { $0.0 == caps }?.1 == escape)
    }
}
