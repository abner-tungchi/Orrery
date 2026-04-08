// Platform-safe wrappers for C stdio globals.
// On Linux (Glibc), stdout/stderr are mutable globals that Swift 6 flags as unsafe.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc

// Glibc's stdout/stderr are mutable globals, which Swift 6 strict concurrency rejects.
// Create nonisolated(unsafe) aliases so call sites don't need per-line suppression.
nonisolated(unsafe) let _stdout = stdout
nonisolated(unsafe) let _stderr = stderr
#endif

@inline(__always)
func flushStdout() {
    #if canImport(Darwin)
    fflush(stdout)
    #else
    fflush(_stdout)
    #endif
}

@inline(__always)
func writeStderr(_ message: String) {
    #if canImport(Darwin)
    fputs(message, stderr)
    #else
    fputs(message, _stderr)
    #endif
}
