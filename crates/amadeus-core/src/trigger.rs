use std::collections::BTreeMap;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::perception::{ComputerActivity, PerceptionEvent};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TriggerCondition {
    AppFocused { app_id: String },
    ContinuousComputerActivity { min_seconds: i64 },
    Always,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TriggerAction {
    ConsiderInitiative { reason: String },
    RunSkill { skill_id: String },
    ProposeEvolution { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trigger {
    pub id: String,
    pub enabled: bool,
    pub condition: TriggerCondition,
    pub action: TriggerAction,
    pub cooldown_seconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriggeredAction {
    pub trigger_id: String,
    pub action: TriggerAction,
    pub fired_at: DateTime<Utc>,
}

#[derive(Debug, Default)]
pub struct TriggerEngine {
    triggers: Vec<Trigger>,
    active_since: Option<DateTime<Utc>>,
    current_activity: Option<ComputerActivity>,
    last_fired: BTreeMap<String, DateTime<Utc>>,
}

impl TriggerEngine {
    pub fn add(&mut self, trigger: Trigger) {
        self.triggers.push(trigger);
    }

    pub fn definitions(&self) -> &[Trigger] {
        &self.triggers
    }

    /// Restore persisted trigger definitions without restoring volatile
    /// observation/cooldown state. After process restart Amadeus must observe
    /// fresh activity before a trigger can fire again.
    pub fn replace_definitions(&mut self, triggers: Vec<Trigger>) {
        self.triggers = triggers;
        self.active_since = None;
        self.current_activity = None;
        self.last_fired.clear();
    }

    pub fn evaluate(&mut self, event: &PerceptionEvent) -> Vec<TriggeredAction> {
        let at = event_time(event);
        self.update_context(event);

        let mut actions = Vec::new();
        for trigger in &self.triggers {
            if !trigger.enabled || !self.matches(trigger, at) || !self.cooldown_elapsed(trigger, at) {
                continue;
            }
            self.last_fired.insert(trigger.id.clone(), at);
            actions.push(TriggeredAction {
                trigger_id: trigger.id.clone(),
                action: trigger.action.clone(),
                fired_at: at,
            });
        }
        actions
    }

    fn update_context(&mut self, event: &PerceptionEvent) {
        match event {
            PerceptionEvent::ForegroundChanged { current, at, .. } => {
                self.active_since.get_or_insert(*at);
                self.current_activity = Some(current.clone());
            }
            PerceptionEvent::IdleStarted { .. } | PerceptionEvent::GapDetected { .. } => {
                self.active_since = None;
                self.current_activity = None;
            }
            PerceptionEvent::IdleEnded { current, at } => {
                self.active_since = Some(*at);
                self.current_activity = Some(current.clone());
            }
        }
    }

    fn matches(&self, trigger: &Trigger, at: DateTime<Utc>) -> bool {
        match &trigger.condition {
            TriggerCondition::Always => true,
            TriggerCondition::AppFocused { app_id } => self
                .current_activity
                .as_ref()
                .is_some_and(|activity| &activity.app_id == app_id),
            TriggerCondition::ContinuousComputerActivity { min_seconds } => self
                .active_since
                .is_some_and(|started| at - started >= Duration::seconds(*min_seconds)),
        }
    }

    fn cooldown_elapsed(&self, trigger: &Trigger, at: DateTime<Utc>) -> bool {
        self.last_fired.get(&trigger.id).is_none_or(|last| {
            at - *last >= Duration::seconds(trigger.cooldown_seconds.max(0))
        })
    }
}

fn event_time(event: &PerceptionEvent) -> DateTime<Utc> {
    match event {
        PerceptionEvent::ForegroundChanged { at, .. }
        | PerceptionEvent::IdleStarted { at, .. }
        | PerceptionEvent::IdleEnded { at, .. }
        | PerceptionEvent::GapDetected { at } => *at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).unwrap()
    }

    fn activity(name: &str) -> ComputerActivity {
        ComputerActivity::new(name, name)
    }

    #[test]
    fn continuous_activity_trigger_survives_app_switches_and_resets_on_idle() {
        let mut engine = TriggerEngine::default();
        engine.add(Trigger {
            id: "long-work".into(),
            enabled: true,
            condition: TriggerCondition::ContinuousComputerActivity { min_seconds: 120 },
            action: TriggerAction::ConsiderInitiative {
                reason: "long continuous session".into(),
            },
            cooldown_seconds: 600,
        });

        assert!(engine
            .evaluate(&PerceptionEvent::ForegroundChanged {
                previous: None,
                current: activity("editor"),
                at: at(100),
            })
            .is_empty());
        assert!(engine
            .evaluate(&PerceptionEvent::ForegroundChanged {
                previous: Some(activity("editor")),
                current: activity("browser"),
                at: at(180),
            })
            .is_empty());
        assert_eq!(
            engine
                .evaluate(&PerceptionEvent::ForegroundChanged {
                    previous: Some(activity("browser")),
                    current: activity("terminal"),
                    at: at(230),
                })
                .len(),
            1
        );

        engine.evaluate(&PerceptionEvent::IdleStarted {
            at: at(240),
            grace_ms: 0,
        });
        assert!(engine
            .evaluate(&PerceptionEvent::IdleEnded {
                current: activity("editor"),
                at: at(500),
            })
            .is_empty());
    }

    #[test]
    fn restoring_definitions_does_not_restore_stale_cooldowns() {
        let trigger = Trigger {
            id: "always".into(),
            enabled: true,
            condition: TriggerCondition::Always,
            action: TriggerAction::ConsiderInitiative {
                reason: "test".into(),
            },
            cooldown_seconds: 999,
        };
        let mut engine = TriggerEngine::default();
        engine.add(trigger.clone());
        assert_eq!(
            engine.evaluate(&PerceptionEvent::ForegroundChanged {
                previous: None,
                current: activity("editor"),
                at: at(100),
            }).len(),
            1
        );
        engine.replace_definitions(vec![trigger]);
        assert_eq!(
            engine.evaluate(&PerceptionEvent::ForegroundChanged {
                previous: None,
                current: activity("editor"),
                at: at(101),
            }).len(),
            1
        );
    }
}
