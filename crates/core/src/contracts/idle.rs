//! Idle detection — determines if the user is away from the computer.

use std::time::Duration;

/// Detects whether the user is idle (no keyboard/mouse input).
///
/// Implemented by `engine::idle_win32` using `GetLastInputInfo`.
pub trait IdleDetector: Send + Sync {
    /// Returns `true` if the user has been idle longer than `threshold`.
    fn is_idle(&self, threshold: Duration) -> bool;

    /// Returns the duration since the last user input.
    fn idle_duration(&self) -> Duration;
}
