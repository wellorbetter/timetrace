use std::collections::BTreeSet;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::memory::{
    LivedMemory, LivedMemoryKind, LivedMemorySource, LivedMemoryStore, MemoryError,
};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct MemoryQuery {
    pub text: String,
    pub kinds: Vec<LivedMemoryKind>,
    pub sources: Vec<LivedMemorySource>,
    pub since: Option<DateTime<Utc>>,
    pub limit: usize,
}

impl MemoryQuery {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            limit: 8,
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryHit {
    pub memory: LivedMemory,
    pub score: f32,
}

#[derive(Debug, Clone, Copy)]
pub struct MemoryRetriever {
    scan_limit: usize,
}

impl Default for MemoryRetriever {
    fn default() -> Self {
        Self { scan_limit: 256 }
    }
}

impl MemoryRetriever {
    pub fn new(scan_limit: usize) -> Self {
        Self {
            scan_limit: scan_limit.max(1),
        }
    }

    pub fn search<S: LivedMemoryStore>(
        &self,
        store: &S,
        query: &MemoryQuery,
        now: DateTime<Utc>,
    ) -> Result<Vec<MemoryHit>, MemoryError> {
        let query_tokens = tokenize(&query.text);
        let mut hits = store
            .recent_memories(self.scan_limit)?
            .into_iter()
            .filter(|memory| {
                (query.kinds.is_empty() || query.kinds.contains(&memory.kind))
                    && (query.sources.is_empty() || query.sources.contains(&memory.source))
                    && query.since.is_none_or(|since| memory.created_at >= since)
            })
            .map(|memory| {
                let lexical = lexical_score(&query_tokens, &tokenize(&memory.content));
                let salience = memory.salience.clamp(0.0, 1.0);
                let recency = recency_score(memory.created_at, now);
                let score = if query_tokens.is_empty() {
                    0.62 * salience + 0.38 * recency
                } else {
                    0.62 * lexical + 0.23 * salience + 0.15 * recency
                };
                MemoryHit { memory, score }
            })
            .filter(|hit| query_tokens.is_empty() || hit.score > 0.05)
            .collect::<Vec<_>>();

        hits.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| b.memory.created_at.cmp(&a.memory.created_at))
        });
        hits.truncate(query.limit.max(1));
        Ok(hits)
    }
}

fn recency_score(created_at: DateTime<Utc>, now: DateTime<Utc>) -> f32 {
    let age = (now - created_at).max(Duration::zero()).num_seconds() as f32;
    let half_life = 7.0 * 24.0 * 3600.0;
    0.5_f32.powf(age / half_life)
}

fn lexical_score(query: &BTreeSet<String>, content: &BTreeSet<String>) -> f32 {
    if query.is_empty() || content.is_empty() {
        return 0.0;
    }
    let overlap = query.intersection(content).count() as f32;
    let precision = overlap / query.len() as f32;
    let coverage = overlap / content.len().min(query.len().max(1)) as f32;
    (precision * 0.8 + coverage * 0.2).clamp(0.0, 1.0)
}

fn tokenize(input: &str) -> BTreeSet<String> {
    let mut tokens = BTreeSet::new();
    let mut ascii = String::new();

    let flush_ascii = |ascii: &mut String, tokens: &mut BTreeSet<String>| {
        if ascii.len() >= 2 {
            tokens.insert(std::mem::take(ascii));
        } else {
            ascii.clear();
        }
    };

    for ch in input.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' || ch == '.' {
            ascii.push(ch);
        } else {
            flush_ascii(&mut ascii, &mut tokens);
            if ch.is_alphanumeric() && !ch.is_ascii() {
                tokens.insert(ch.to_string());
            }
        }
    }
    flush_ascii(&mut ascii, &mut tokens);
    tokens
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;

    use super::*;
    use crate::memory::SqliteLivedMemoryStore;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn retrieval_prefers_semantically_matching_recent_salient_memory() {
        let mut store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        for memory in [
            LivedMemory {
                kind: LivedMemoryKind::ProjectFact,
                source: LivedMemorySource::Computer,
                content: "Worked on amadeus memory retrieval and Rust tests".into(),
                salience: 0.8,
                created_at: at(900),
            },
            LivedMemory {
                kind: LivedMemoryKind::Preference,
                source: LivedMemorySource::Conversation,
                content: "Prefers warm minimal interface colors".into(),
                salience: 0.95,
                created_at: at(990),
            },
        ] {
            store.append_memory(&memory).unwrap();
        }

        let hits = MemoryRetriever::default()
            .search(&store, &MemoryQuery::text("amadeus rust memory"), at(1000))
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert!(hits[0].memory.content.contains("amadeus"));
    }

    #[test]
    fn retrieval_supports_non_ascii_character_tokens() {
        let mut store = SqliteLivedMemoryStore::open_in_memory().unwrap();
        store
            .append_memory(&LivedMemory {
                kind: LivedMemoryKind::Relationship,
                source: LivedMemorySource::Conversation,
                content: "一起讨论了记忆系统和电脑经历".into(),
                salience: 0.9,
                created_at: at(100),
            })
            .unwrap();
        let hits = MemoryRetriever::default()
            .search(&store, &MemoryQuery::text("电脑记忆"), at(101))
            .unwrap();
        assert_eq!(hits.len(), 1);
    }
}
