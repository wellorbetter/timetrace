use std::collections::BTreeMap;

use serde_json::Value;
use thiserror::Error;

use crate::skills::{SkillDescriptor, SkillRegistry, SkillRegistryError, SkillRisk};

#[derive(Debug, Clone, PartialEq)]
pub struct SkillInvocation {
    pub skill_id: String,
    pub arguments: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SkillResult {
    pub skill_id: String,
    pub output: Value,
}

#[derive(Debug, Error)]
pub enum SkillExecutionError {
    #[error(transparent)]
    Registry(#[from] SkillRegistryError),
    #[error("no executor registered for skill: {0}")]
    MissingExecutor(String),
    #[error("skill {skill_id} requires approval because risk is {risk:?}")]
    ApprovalRequired { skill_id: String, risk: SkillRisk },
    #[error("skill {skill_id} failed: {message}")]
    Failed { skill_id: String, message: String },
}

pub trait SkillExecutor: Send {
    fn execute(&mut self, arguments: &Value) -> Result<Value, String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkillApprovalPolicy {
    pub auto_approve_up_to: SkillRisk,
}

impl Default for SkillApprovalPolicy {
    fn default() -> Self {
        Self { auto_approve_up_to: SkillRisk::ReadOnly }
    }
}

pub struct SkillRuntime {
    registry: SkillRegistry,
    executors: BTreeMap<String, Box<dyn SkillExecutor>>,
    approval: SkillApprovalPolicy,
}

impl Default for SkillRuntime {
    fn default() -> Self {
        Self {
            registry: SkillRegistry::default(),
            executors: BTreeMap::new(),
            approval: SkillApprovalPolicy::default(),
        }
    }
}

impl SkillRuntime {
    pub fn registry(&self) -> &SkillRegistry {
        &self.registry
    }

    pub fn registry_mut(&mut self) -> &mut SkillRegistry {
        &mut self.registry
    }

    pub fn set_approval_policy(&mut self, policy: SkillApprovalPolicy) {
        self.approval = policy;
    }

    pub fn register(
        &mut self,
        descriptor: SkillDescriptor,
        executor: Box<dyn SkillExecutor>,
    ) -> Result<(), SkillRegistryError> {
        let id = descriptor.id.clone();
        self.registry.register(descriptor)?;
        self.executors.insert(id, executor);
        Ok(())
    }

    pub fn execute(
        &mut self,
        invocation: SkillInvocation,
        explicitly_approved: bool,
    ) -> Result<Vec<SkillResult>, SkillExecutionError> {
        let plan = self
            .registry
            .resolve_plan(&invocation.skill_id)?
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
        let mut results = Vec::new();

        for descriptor in plan {
            if descriptor.risk > self.approval.auto_approve_up_to && !explicitly_approved {
                return Err(SkillExecutionError::ApprovalRequired {
                    skill_id: descriptor.id,
                    risk: descriptor.risk,
                });
            }
            let executor = self
                .executors
                .get_mut(&descriptor.id)
                .ok_or_else(|| SkillExecutionError::MissingExecutor(descriptor.id.clone()))?;
            let arguments = if descriptor.id == invocation.skill_id {
                invocation.arguments.clone()
            } else {
                Value::Object(Default::default())
            };
            let output = executor
                .execute(&arguments)
                .map_err(|message| SkillExecutionError::Failed {
                    skill_id: descriptor.id.clone(),
                    message,
                })?;
            results.push(SkillResult {
                skill_id: descriptor.id,
                output,
            });
        }
        Ok(results)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::skills::SkillSource;

    struct Echo;
    impl SkillExecutor for Echo {
        fn execute(&mut self, arguments: &Value) -> Result<Value, String> {
            Ok(arguments.clone())
        }
    }

    fn descriptor(id: &str, risk: SkillRisk, requires: Vec<String>) -> SkillDescriptor {
        SkillDescriptor {
            id: id.into(),
            name: id.into(),
            description: String::new(),
            source: SkillSource::BuiltIn,
            risk,
            requires,
        }
    }

    #[test]
    fn write_skills_require_explicit_approval_by_default() {
        let mut runtime = SkillRuntime::default();
        runtime
            .register(
                descriptor("write", SkillRisk::LocalWrite, vec![]),
                Box::new(Echo),
            )
            .unwrap();
        let error = runtime
            .execute(
                SkillInvocation { skill_id: "write".into(), arguments: json!({"x": 1}) },
                false,
            )
            .unwrap_err();
        assert!(matches!(error, SkillExecutionError::ApprovalRequired { .. }));
        assert_eq!(
            runtime
                .execute(
                    SkillInvocation { skill_id: "write".into(), arguments: json!({"x": 1}) },
                    true,
                )
                .unwrap()[0]
                .output,
            json!({"x": 1})
        );
    }
}
