use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One canonical memory belonging to the persona before activation.
///
/// Canonical memories are intentionally stored outside the lived-memory write
/// path. Runtime code can read them but cannot append or rewrite them through
/// [`IdentityMemory`]. Updating identity is a separate, explicit bootstrap or
/// persona-pack operation rather than ordinary agent evolution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalMemory {
    id: String,
    content: String,
    tags: Vec<String>,
    source: Option<String>,
}

impl CanonicalMemory {
    pub fn new(
        id: impl Into<String>,
        content: impl Into<String>,
        tags: Vec<String>,
        source: Option<String>,
    ) -> Self {
        Self {
            id: id.into(),
            content: content.into(),
            tags,
            source,
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn tags(&self) -> &[String] {
        &self.tags
    }

    pub fn source(&self) -> Option<&str> {
        self.source.as_deref()
    }
}

/// Protected identity memory: the persona's pre-existing self.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdentityMemory {
    persona_id: String,
    display_name: String,
    /// Optional timestamp describing the canonical memory boundary.
    memory_boundary: Option<DateTime<Utc>>,
    canonical: Vec<CanonicalMemory>,
}

impl IdentityMemory {
    /// Construct identity only from a trusted persona bootstrap/pack.
    ///
    /// There is intentionally no runtime `push`, `update`, or `remove` API.
    pub fn from_persona_pack(
        persona_id: impl Into<String>,
        display_name: impl Into<String>,
        memory_boundary: Option<DateTime<Utc>>,
        canonical: Vec<CanonicalMemory>,
    ) -> Self {
        Self {
            persona_id: persona_id.into(),
            display_name: display_name.into(),
            memory_boundary,
            canonical,
        }
    }

    pub fn persona_id(&self) -> &str {
        &self.persona_id
    }

    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    pub fn memory_boundary(&self) -> Option<DateTime<Utc>> {
        self.memory_boundary
    }

    pub fn canonical(&self) -> &[CanonicalMemory] {
        &self.canonical
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_loaded_as_a_read_only_persona_pack() {
        let identity = IdentityMemory::from_persona_pack(
            "kurisu",
            "Makise Kurisu",
            None,
            vec![CanonicalMemory::new(
                "lab",
                "Research and scientific reasoning are central to my identity.",
                vec!["science".into()],
                None,
            )],
        );

        assert_eq!(identity.persona_id(), "kurisu");
        assert_eq!(identity.canonical().len(), 1);
        assert_eq!(identity.canonical()[0].id(), "lab");
    }
}
