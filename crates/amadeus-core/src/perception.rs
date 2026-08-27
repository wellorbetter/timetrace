use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Normalized foreground activity understood by Amadeus.
///
/// It intentionally contains no TimeTrace-specific types. Native observers,
/// TimeTrace adapters, browser integrations, or future MCP providers can all
/// emit the same structure.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ComputerActivity {
    pub app_id: String,
    pub display_name: String,
    pub executable_path: Option<String>,
    pub window_title: Option<String>,
}

impl ComputerActivity {
    pub fn new(app_id: impl Into<String>, display_name: impl Into<String>) -> Self {
        Self {
            app_id: app_id.into(),
            display_name: display_name.into(),
            executable_path: None,
            window_title: None,
        }
    }

    pub fn with_executable_path(mut self, path: impl Into<String>) -> Self {
        self.executable_path = Some(path.into());
        self
    }

    pub fn with_window_title(mut self, title: impl Into<String>) -> Self {
        self.window_title = Some(title.into());
        self
    }
}

/// Events emitted by the always-on computer perception layer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PerceptionEvent {
    ForegroundChanged {
        previous: Option<ComputerActivity>,
        current: ComputerActivity,
        at: DateTime<Utc>,
    },
    IdleStarted {
        at: DateTime<Utc>,
        /// Input-idle grace that should not be attributed to the last app.
        grace_ms: u64,
    },
    IdleEnded {
        current: ComputerActivity,
        at: DateTime<Utc>,
    },
    GapDetected {
        at: DateTime<Utc>,
    },
}
