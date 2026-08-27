use std::sync::{Mutex, OnceLock};

use amadeus_core::{
    LivedMemory, LivedMemoryKind, LivedMemorySource, LivedMemoryStore,
    MemoryQuery, MemoryRetriever, SkillDescriptor, SkillExecutionError,
    SkillExecutor, SkillInvocation, SkillResult, SkillRisk, SkillRuntime,
    SkillSource,
};
use serde_json::{json, Value};

use crate::amadeus_host::{shared_amadeus_runtime, AmadeusHostError, SharedAmadeusRuntime};

static HOST_SKILLS: OnceLock<Mutex<SkillRuntime>> = OnceLock::new();

pub fn run_amadeus_skill(
    skill_id: String,
    arguments: Value,
    explicitly_approved: bool,
) -> Result<Vec<SkillResult>, SkillExecutionError> {
    let runtime = HOST_SKILLS.get_or_init(|| Mutex::new(build_host_skills()));
    let mut runtime = runtime
        .lock()
        .map_err(|_| SkillExecutionError::Failed {
            skill_id: skill_id.clone(),
            message: "skill runtime mutex poisoned".into(),
        })?;
    runtime.execute(
        SkillInvocation {
            skill_id,
            arguments,
        },
        explicitly_approved,
    )
}

pub fn ensure_amadeus_skills() {
    let _ = HOST_SKILLS.get_or_init(|| Mutex::new(build_host_skills()));
}

fn build_host_skills() -> SkillRuntime {
    let shared = shared_amadeus_runtime().ok();
    let mut runtime = SkillRuntime::default();
    let Some(shared) = shared else {
        return runtime;
    };

    register(
        &mut runtime,
        "computer.current_activity",
        "Current computer activity",
        "Read the app/window currently visible to Amadeus.",
        Box::new(CurrentActivitySkill {
            runtime: shared.clone(),
        }),
    );
    register(
        &mut runtime,
        "memory.search",
        "Search lived memory",
        "Search Amadeus post-activation memories by relevance.",
        Box::new(MemorySearchSkill {
            runtime: shared.clone(),
        }),
    );
    register(
        &mut runtime,
        "memory.recent",
        "Recent lived memory",
        "Read recently consolidated or conversational lived memories.",
        Box::new(RecentMemorySkill { runtime: shared }),
    );
    runtime
}

fn register(
    runtime: &mut SkillRuntime,
    id: &str,
    name: &str,
    description: &str,
    executor: Box<dyn SkillExecutor>,
) {
    let _ = runtime.register(
        SkillDescriptor {
            id: id.into(),
            name: name.into(),
            description: description.into(),
            source: SkillSource::BuiltIn,
            risk: SkillRisk::ReadOnly,
            requires: vec![],
        },
        executor,
    );
}

struct CurrentActivitySkill {
    runtime: SharedAmadeusRuntime,
}

impl SkillExecutor for CurrentActivitySkill {
    fn execute(&mut self, _arguments: &Value) -> Result<Value, String> {
        let runtime = self
            .runtime
            .lock()
            .map_err(|_| "Amadeus runtime mutex poisoned".to_owned())?;
        Ok(match runtime.working_context().current_activity.as_ref() {
            Some(activity) => json!({
                "app_id": activity.app_id,
                "display_name": activity.display_name,
                "executable_path": activity.executable_path,
                "window_title": activity.window_title,
                "started_at": runtime.working_context().started_at.map(|v| v.to_rfc3339()),
            }),
            None => Value::Null,
        })
    }
}

struct MemorySearchSkill {
    runtime: SharedAmadeusRuntime,
}

impl SkillExecutor for MemorySearchSkill {
    fn execute(&mut self, arguments: &Value) -> Result<Value, String> {
        let text = arguments
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let limit = arguments
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(8)
            .clamp(1, 50) as usize;
        let runtime = self
            .runtime
            .lock()
            .map_err(|_| "Amadeus runtime mutex poisoned".to_owned())?;
        let mut query = MemoryQuery::text(text);
        query.limit = limit;
        let hits = MemoryRetriever::default()
            .search(runtime.memory().store(), &query, chrono::Utc::now())
            .map_err(|error| error.to_string())?;
        Ok(Value::Array(
            hits.into_iter()
                .map(|hit| {
                    json!({
                        "score": hit.score,
                        "memory": memory_json(&hit.memory),
                    })
                })
                .collect(),
        ))
    }
}

struct RecentMemorySkill {
    runtime: SharedAmadeusRuntime,
}

impl SkillExecutor for RecentMemorySkill {
    fn execute(&mut self, arguments: &Value) -> Result<Value, String> {
        let limit = arguments
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(8)
            .clamp(1, 50) as usize;
        let runtime = self
            .runtime
            .lock()
            .map_err(|_| "Amadeus runtime mutex poisoned".to_owned())?;
        let memories = runtime
            .memory()
            .store()
            .recent_memories(limit)
            .map_err(|error| error.to_string())?;
        Ok(Value::Array(
            memories.iter().map(memory_json).collect::<Vec<_>>(),
        ))
    }
}

fn memory_json(memory: &LivedMemory) -> Value {
    json!({
        "kind": match memory.kind {
            LivedMemoryKind::Conversation => "conversation",
            LivedMemoryKind::Relationship => "relationship",
            LivedMemoryKind::ProjectFact => "project_fact",
            LivedMemoryKind::Preference => "preference",
            LivedMemoryKind::Reflection => "reflection",
        },
        "source": match memory.source {
            LivedMemorySource::Conversation => "conversation",
            LivedMemorySource::Computer => "computer",
            LivedMemorySource::Skill => "skill",
            LivedMemorySource::Trigger => "trigger",
            LivedMemorySource::Reflection => "reflection",
        },
        "content": memory.content,
        "salience": memory.salience,
        "created_at": memory.created_at.to_rfc3339(),
    })
}

pub fn host_skill_runtime_available() -> Result<bool, AmadeusHostError> {
    shared_amadeus_runtime()?;
    ensure_amadeus_skills();
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_skill_ids_are_stable() {
        assert_eq!("memory.search", "memory.search");
        assert_eq!("computer.current_activity", "computer.current_activity");
    }
}
