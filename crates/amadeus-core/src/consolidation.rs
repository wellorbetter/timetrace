use std::collections::BTreeMap;

use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::memory::{ComputerEpisode, LivedMemory, LivedMemoryKind, LivedMemorySource};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ConsolidationPolicy {
    pub min_duration_seconds: i64,
    pub max_apps: usize,
    pub max_titles: usize,
}

impl Default for ConsolidationPolicy {
    fn default() -> Self {
        Self {
            min_duration_seconds: 30,
            max_apps: 5,
            max_titles: 4,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EpisodeDigest {
    pub duration_seconds: i64,
    pub dominant_app: Option<String>,
    pub apps: Vec<String>,
    pub window_titles: Vec<String>,
    pub summary: String,
}

#[derive(Debug, Clone)]
pub struct EpisodeConsolidator {
    policy: ConsolidationPolicy,
}

impl Default for EpisodeConsolidator {
    fn default() -> Self {
        Self::new(ConsolidationPolicy::default())
    }
}

impl EpisodeConsolidator {
    pub fn new(policy: ConsolidationPolicy) -> Self {
        Self { policy }
    }

    pub fn digest(&self, episode: &ComputerEpisode) -> EpisodeDigest {
        let duration_seconds = episode.duration().num_seconds().max(0);
        let mut app_seconds = BTreeMap::<String, i64>::new();
        let mut titles = Vec::<String>::new();

        for span in &episode.spans {
            let seconds = (span.ended_at - span.started_at).num_seconds().max(0);
            *app_seconds
                .entry(span.activity.display_name.clone())
                .or_default() += seconds;
            if let Some(title) = span.activity.window_title.as_deref() {
                let title = title.trim();
                if !title.is_empty() && !titles.iter().any(|existing| existing == title) {
                    titles.push(title.to_owned());
                }
            }
        }

        let mut apps = app_seconds.into_iter().collect::<Vec<_>>();
        apps.sort_by(|(name_a, seconds_a), (name_b, seconds_b)| {
            seconds_b.cmp(seconds_a).then_with(|| name_a.cmp(name_b))
        });
        let dominant_app = apps.first().map(|(name, _)| name.clone());
        let app_names = apps
            .iter()
            .take(self.policy.max_apps)
            .map(|(name, _)| name.clone())
            .collect::<Vec<_>>();
        titles.truncate(self.policy.max_titles);

        let duration_label = if duration_seconds >= 3600 {
            format!("{}h {}m", duration_seconds / 3600, (duration_seconds % 3600) / 60)
        } else if duration_seconds >= 60 {
            format!("{}m", duration_seconds / 60)
        } else {
            format!("{}s", duration_seconds)
        };
        let app_label = if app_names.is_empty() {
            "unknown applications".to_owned()
        } else {
            app_names.join(", ")
        };
        let summary = if titles.is_empty() {
            format!("Computer work session lasting {duration_label}, mainly across {app_label}.")
        } else {
            format!(
                "Computer work session lasting {duration_label}, mainly across {app_label}. Notable windows: {}.",
                titles.join(" · ")
            )
        };

        EpisodeDigest {
            duration_seconds,
            dominant_app,
            apps: app_names,
            window_titles: titles,
            summary,
        }
    }

    pub fn consolidate(&self, episode: &ComputerEpisode) -> Option<LivedMemory> {
        let digest = self.digest(episode);
        if digest.duration_seconds < self.policy.min_duration_seconds {
            return None;
        }

        let duration_weight = (digest.duration_seconds as f32 / 7200.0).clamp(0.0, 1.0);
        let diversity_weight = (digest.apps.len() as f32 / 5.0).clamp(0.0, 1.0);
        let salience = (0.35 + duration_weight * 0.45 + diversity_weight * 0.20).clamp(0.0, 1.0);

        Some(LivedMemory {
            kind: LivedMemoryKind::ProjectFact,
            source: LivedMemorySource::Computer,
            content: digest.summary,
            salience,
            created_at: episode.ended_at.min(Utc::now()),
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, Utc};

    use super::*;
    use crate::memory::ActivitySpan;
    use crate::perception::ComputerActivity;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    #[test]
    fn consolidates_a_multi_app_episode_into_one_lived_memory() {
        let episode = ComputerEpisode {
            started_at: at(100),
            ended_at: at(700),
            spans: vec![
                ActivitySpan {
                    activity: ComputerActivity::new("editor", "Editor")
                        .with_window_title("amadeus-core/src/memory.rs"),
                    started_at: at(100),
                    ended_at: at(500),
                },
                ActivitySpan {
                    activity: ComputerActivity::new("terminal", "Terminal")
                        .with_window_title("cargo test --workspace"),
                    started_at: at(500),
                    ended_at: at(700),
                },
            ],
        };
        let consolidator = EpisodeConsolidator::default();
        let memory = consolidator.consolidate(&episode).unwrap();
        assert_eq!(memory.kind, LivedMemoryKind::ProjectFact);
        assert_eq!(memory.source, LivedMemorySource::Computer);
        assert!(memory.content.contains("Editor"));
        assert!(memory.content.contains("cargo test"));
    }

    #[test]
    fn ignores_tiny_accidental_activity() {
        let episode = ComputerEpisode {
            started_at: at(100),
            ended_at: at(110),
            spans: vec![ActivitySpan {
                activity: ComputerActivity::new("finder", "Finder"),
                started_at: at(100),
                ended_at: at(110),
            }],
        };
        assert!(EpisodeConsolidator::default().consolidate(&episode).is_none());
    }
}
