import AppKit
import SwiftUI

// Settings lists edit array elements in place. When an element is removed while
// its row (or an editor sheet) is still on screen, a focused text field commits
// on teardown through its binding; with a plain `$array[index]` binding that
// index may no longer exist, which traps. These bindings survive it: reads fall
// back to the last value seen, writes to a removed element are dropped.

/// The last value a binding read.
final class LastValue<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// `array[index]`, safe after removals. Pass the element the row was built from.
func safeElement<T>(_ array: Binding<[T]>, _ index: Int, fallback: T) -> Binding<T> {
    let last = LastValue(fallback)
    return Binding(
        get: {
            guard array.wrappedValue.indices.contains(index) else { return last.value }
            last.value = array.wrappedValue[index]
            return last.value
        },
        set: { if array.wrappedValue.indices.contains(index) { array.wrappedValue[index] = $0 } }
    )
}

/// The element with `id`, wherever it moves, safe after removals.
func safeElement<T: Identifiable>(_ array: Binding<[T]>, id: T.ID, fallback: T) -> Binding<T> {
    let last = LastValue(fallback)
    return Binding(
        get: {
            guard let element = array.wrappedValue.first(where: { $0.id == id }) else { return last.value }
            last.value = element
            return element
        },
        set: { value in
            if let index = array.wrappedValue.firstIndex(where: { $0.id == id }) { array.wrappedValue[index] = value }
        }
    )
}

/// Commits the focused text field now, so it writes into the right element
/// before rows are removed or reordered.
func endEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

extension Array {
    /// Removes the element at `index` if it still exists (double clicks on a
    /// delete button can arrive after the row is already gone).
    mutating func removeIfPresent(at index: Int) {
        if indices.contains(index) { remove(at: index) }
    }
}
