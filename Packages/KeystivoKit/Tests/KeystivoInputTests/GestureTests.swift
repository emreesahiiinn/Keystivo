import CoreGraphics
import Foundation
import KeystivoCore
@testable import KeystivoInput
import Testing

@Suite("Trackpad recognizer")
struct TrackpadRecognizerTests {
    /// Feeds frames of `fingers` touches moving from `start` by `delta` over `duration`.
    private func gesture(_ recognizer: inout TrackpadRecognizer, fingers: Int, start: TimeInterval = 0, duration: TimeInterval,
                         delta: (Float, Float) = (0, 0), steps: Int = 10, allowTwoFinger: Bool = false) -> [TrackpadRecognizer.Event] {
        var events: [TrackpadRecognizer.Event] = []
        for step in 0...steps {
            let t = Float(step) / Float(steps)
            let touches = (0..<fingers).map { index in
                TouchPoint(id: Int32(index), x: 0.3 + Float(index) * 0.08 + delta.0 * t, y: 0.5 + delta.1 * t)
            }
            events += recognizer.process(touches, timestamp: start + duration * Double(t), allowTwoFingerSwipes: allowTwoFinger)
        }
        events += recognizer.process([], timestamp: start + duration + 0.01, allowTwoFingerSwipes: allowTwoFinger)
        return events
    }

    @Test func threeFingerTap() {
        var recognizer = TrackpadRecognizer()
        #expect(gesture(&recognizer, fingers: 3, duration: 0.1) == [.tap(fingers: 3)])
    }

    @Test func slowTouchIsNotATap() {
        var recognizer = TrackpadRecognizer()
        #expect(gesture(&recognizer, fingers: 3, duration: 0.6).isEmpty)
    }

    @Test func doubleTap() {
        var recognizer = TrackpadRecognizer()
        _ = gesture(&recognizer, fingers: 4, duration: 0.08)
        #expect(gesture(&recognizer, fingers: 4, start: 0.2, duration: 0.08) == [.doubleTap(fingers: 4)])
    }

    @Test(arguments: [
        ((Float(0.25), Float(0)), GestureDirection.right), ((-0.25, 0), .left), ((0, 0.25), .up), ((0, -0.25), .down),
    ])
    func threeFingerSwipes(delta: (Float, Float), direction: GestureDirection) {
        var recognizer = TrackpadRecognizer()
        #expect(gesture(&recognizer, fingers: 3, duration: 0.2, delta: delta) == [.swipe(fingers: 3, direction: direction)])
    }

    @Test func twoFingerSwipeNeedsModifier() {
        var recognizer = TrackpadRecognizer()
        #expect(gesture(&recognizer, fingers: 2, duration: 0.3, delta: (0, -0.3)).isEmpty)
        #expect(gesture(&recognizer, fingers: 2, start: 2, duration: 0.3, delta: (0, -0.3), allowTwoFinger: true) == [.swipe(fingers: 2, direction: .down)])
    }

    @Test func swipeFiresOncePerContact() {
        var recognizer = TrackpadRecognizer()
        let events = gesture(&recognizer, fingers: 4, duration: 0.4, delta: (0.6, 0), steps: 30)
        #expect(events == [.swipe(fingers: 4, direction: .right)])
    }

    @Test func tipTapRight() {
        var recognizer = TrackpadRecognizer()
        var events: [TrackpadRecognizer.Event] = []
        let resting = TouchPoint(id: 1, x: 0.4, y: 0.5)
        for step in 0...5 { events += recognizer.process([resting], timestamp: Double(step) * 0.05) }
        events += recognizer.process([resting, TouchPoint(id: 2, x: 0.6, y: 0.5)], timestamp: 0.3)
        events += recognizer.process([resting, TouchPoint(id: 2, x: 0.6, y: 0.5)], timestamp: 0.35)
        events += recognizer.process([resting], timestamp: 0.4)
        events += recognizer.process([], timestamp: 0.6)
        #expect(events == [.tipTap(side: .right)])
    }
}

@Suite("Mouse strokes")
struct StrokeRecognizerTests {
    @Test func downThenRight() {
        var recognizer = StrokeRecognizer(minimumSegment: 20)
        recognizer.begin(at: CGPoint(x: 100, y: 100))
        for y in stride(from: 100, through: 180, by: 10) { recognizer.add(CGPoint(x: 100, y: CGFloat(y))) }
        for x in stride(from: 100, through: 200, by: 10) { recognizer.add(CGPoint(x: CGFloat(x), y: 180)) }
        #expect(recognizer.strokes == "DR")
    }

    @Test func jitterIsIgnored() {
        var recognizer = StrokeRecognizer(minimumSegment: 30)
        recognizer.begin(at: .zero)
        for x in stride(from: 0, through: 200, by: 5) { recognizer.add(CGPoint(x: CGFloat(x), y: CGFloat(x % 10 == 0 ? 3 : -3))) }
        #expect(recognizer.strokes == "R")
    }

    @Test func mouseGestureNormalizesStrokes() {
        #expect(MouseGesture(strokes: "ud").strokes == "UD")
        #expect(MouseGesture(strokes: "LR").displayString == "←→")
    }
}

@Suite("Gesture profiles & conflicts")
struct GestureResolutionTests {
    let swipe = GestureTrigger.trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .up))

    @Test func appSpecificBindingWins() {
        let global = GestureBinding(trigger: swipe, actions: [ActionInvocation("global")])
        let safari = GestureBinding(trigger: swipe, actions: [ActionInvocation("safari")], appBundleIDs: ["com.apple.Safari"])
        let bindings = [global, safari]
        #expect(GestureResolver.resolve(swipe, in: bindings, frontmostBundleID: "com.apple.Safari", profileID: nil)?.actions.first?.actionID == "safari")
        #expect(GestureResolver.resolve(swipe, in: bindings, frontmostBundleID: "com.apple.mail", profileID: nil)?.actions.first?.actionID == "global")
    }

    @Test func profileScopedBindings() {
        let work = UUID()
        var binding = GestureBinding(trigger: swipe, actions: [ActionInvocation("x")])
        binding.profileIDs = [work]
        #expect(GestureResolver.resolve(swipe, in: [binding], frontmostBundleID: nil, profileID: work) != nil)
        #expect(GestureResolver.resolve(swipe, in: [binding], frontmostBundleID: nil, profileID: UUID()) == nil)
    }

    @Test func disabledBindingsIgnored() {
        var binding = GestureBinding(trigger: swipe, actions: [])
        binding.isEnabled = false
        #expect(GestureResolver.resolve(swipe, in: [binding], frontmostBundleID: nil, profileID: nil) == nil)
    }

    @Test func detectsConflicts() {
        let combo = TriggerBinding.Trigger.keyCombo(KeyCombo(keyCode: 49, modifiers: .command))
        let bindings = [
            TriggerBinding(id: "1", trigger: combo, title: "Mine", origin: .keystivo),
            TriggerBinding(id: "2", trigger: combo, title: "Spotlight", origin: .system),
            TriggerBinding(id: "3", trigger: .trackpad(TrackpadGesture(kind: .tap, fingers: 3)), title: "Tap", origin: .keystivo),
            TriggerBinding(id: "4", trigger: .trackpad(TrackpadGesture(kind: .tap, fingers: 3)), title: "Tap in Xcode", origin: .keystivo, scope: ["com.apple.dt.Xcode"]),
        ]
        let conflicts = ConflictDetector.detect(bindings)
        #expect(conflicts.count == 2)
        #expect(conflicts.first?.severity == .error)
        #expect(conflicts.contains { $0.severity == .override })
    }

    @Test func disjointAppScopesDoNotConflict() {
        let trigger = TriggerBinding.Trigger.mouse(MouseGesture(strokes: "L"))
        let conflicts = ConflictDetector.detect([
            TriggerBinding(id: "a", trigger: trigger, title: "A", origin: .keystivo, scope: ["app.a"]),
            TriggerBinding(id: "b", trigger: trigger, title: "B", origin: .keystivo, scope: ["app.b"]),
        ])
        #expect(conflicts.isEmpty)
    }

    @Test func systemOnlyOverlapsAreIgnored() {
        let combo = TriggerBinding.Trigger.keyCombo(KeyCombo(keyCode: 1, modifiers: .command))
        let conflicts = ConflictDetector.detect([
            TriggerBinding(id: "a", trigger: combo, title: "A", origin: .system),
            TriggerBinding(id: "b", trigger: combo, title: "B", origin: .commonAppShortcut),
        ])
        #expect(conflicts.isEmpty)
    }

    @Test func deviceProfileMatching() {
        let device = InputDeviceInfo(name: "Magic Keyboard with Touch ID", vendorID: 76, productID: 666, kind: .keyboard)
        #expect(InputDeviceProfile(deviceMatch: "magic keyboard").matches(device))
        #expect(!InputDeviceProfile(deviceMatch: "Logitech").matches(device))
    }
}

@Suite("Key remapping")
struct KeyRemapTests {
    @Test func hidutilJSON() {
        let json = KeyRemapper.mappingJSON([(HIDKey.capsLock.rawValue, HIDKey.escape.rawValue)])
        #expect(json == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771113}]}")
        #expect(KeyRemapper.mappingJSON([]) == "{\"UserKeyMapping\":[]}")
        #expect(KeyRemapper.matchingJSON(vendorID: 1452, productID: 832) == "{\"VendorID\":1452,\"ProductID\":832}")
    }

    @Test func scrollSettingsDefaults() {
        let settings = ScrollSettings()
        #expect(!settings.isEnabled)
        #expect(settings.reverseMouseVertical)
        #expect(settings.mouseSpeed == 1)
    }
}
