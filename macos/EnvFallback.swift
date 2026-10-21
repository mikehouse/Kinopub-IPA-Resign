// Cinepub on Mac: sheets lose app-level @Observable environment objects
// ("No Observable object of type ProxyManager found"). Every @Environment(X.self)
// in the app is rerouted through a keypath that falls back to the instance the
// app itself injected with .environment(_:).
import Foundation
import Observation
import SwiftUI

private let lock = NSLock()
nonisolated(unsafe) private var registry: [ObjectIdentifier: AnyObject] = [:]

// Called from the View.environment(_:) trampoline: x0 = object, x1 = its type metadata.
@_cdecl("cinepub_record")
public func cinepubRecord(_ object: UnsafeRawPointer?, _ type: UnsafeRawPointer) {
    guard let object else { return }
    let key = ObjectIdentifier(unsafeBitCast(type, to: Any.Type.self))
    let value = Unmanaged<AnyObject>.fromOpaque(object).takeUnretainedValue()
    lock.lock(); registry[key] = value; lock.unlock()
}

struct FallbackKey<T: AnyObject>: Hashable, @unchecked Sendable {
    let keyPath: KeyPath<EnvironmentValues, T?>
}

extension EnvironmentValues {
    subscript<T: AnyObject>(cinepubFallback key: FallbackKey<T>) -> T {
        if let value = self[keyPath: key.keyPath] { return value }
        lock.lock(); let stored = registry[ObjectIdentifier(T.self)]; lock.unlock()
        guard let stored = stored as? T else {
            fatalError("cinepub-fix: no \(T.self) in environment and none injected yet")
        }
        return stored
    }
}

// The optional-lookup keypath SwiftUI itself builds for @Environment(T.self) var x: T?
private func optionalKeyPath<T: AnyObject & Observable>(_ type: T.Type) -> KeyPath<EnvironmentValues, T?> {
    let env = Environment<T?>(type)
    let content = Mirror(reflecting: env).children.first { $0.label == "content" }!.value
    return Mirror(reflecting: content).children.first!.value as! KeyPath<EnvironmentValues, T?>
}

// Same generic signature (and so the same ABI) as
// SwiftUI.Environment.init<A: AnyObject & Observable>(A.Type) -> Environment<A>
@_silgen_name("cinepub_env_init")
public func cinepubEnvInit<T: AnyObject & Observable>(_ type: T.Type) -> Environment<T> {
    Environment(\EnvironmentValues.[cinepubFallback: FallbackKey(keyPath: optionalKeyPath(type))])
}
