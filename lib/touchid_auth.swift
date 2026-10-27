import Foundation
import LocalAuthentication

let arguments = CommandLine.arguments

// Use the name the executable was invoked as.
let cliName = URL(fileURLWithPath: arguments[0]).lastPathComponent

// Combine all arguments into the reason, or use a sensible default.
let suppliedReason = arguments
    .dropFirst()
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)

let reason = suppliedReason.isEmpty
    ? "do something and needs your permission"
    : suppliedReason

let context = LAContext()

// Do not offer password fallback.
context.localizedFallbackTitle = ""

var authError: NSError?

guard context.canEvaluatePolicy(
    .deviceOwnerAuthenticationWithBiometrics,
    error: &authError
) else {
    let message = authError?.localizedDescription
        ?? "Biometric authentication is unavailable"

    fputs("\(cliName): \(message)\n", stderr)
    exit(1)
}

let semaphore = DispatchSemaphore(value: 0)

var authenticated = false
var evaluationError: Error?

context.evaluatePolicy(
    .deviceOwnerAuthenticationWithBiometrics,
    localizedReason: reason
) { success, error in
    authenticated = success
    evaluationError = error
    semaphore.signal()
}

semaphore.wait()

if authenticated {
    exit(0)
}

if let error = evaluationError {
    fputs("\(cliName): \(error.localizedDescription)\n", stderr)
}

exit(1)
