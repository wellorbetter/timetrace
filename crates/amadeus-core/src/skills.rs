use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SkillSource {
    BuiltIn,
    Mcp { server: String },
    Plugin { plugin: String },
    Composite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum SkillRisk {
    ReadOnly,
    LocalWrite,
    ExternalWrite,
    Execute,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillDescriptor {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source: SkillSource,
    pub risk: SkillRisk,
    /// Other skills that must be available before this one can run.
    pub requires: Vec<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SkillRegistryError {
    #[error("skill already registered: {0}")]
    Duplicate(String),
    #[error("unknown skill: {0}")]
    Unknown(String),
    #[error("skill dependency cycle at: {0}")]
    Cycle(String),
}

#[derive(Debug, Default)]
pub struct SkillRegistry {
    skills: BTreeMap<String, SkillDescriptor>,
}

impl SkillRegistry {
    pub fn register(&mut self, skill: SkillDescriptor) -> Result<(), SkillRegistryError> {
        if self.skills.contains_key(&skill.id) {
            return Err(SkillRegistryError::Duplicate(skill.id));
        }
        self.skills.insert(skill.id.clone(), skill);
        Ok(())
    }

    pub fn get(&self, id: &str) -> Option<&SkillDescriptor> {
        self.skills.get(id)
    }

    pub fn all(&self) -> impl Iterator<Item = &SkillDescriptor> {
        self.skills.values()
    }

    /// Resolve a composite skill into a dependency-first execution plan.
    pub fn resolve_plan(&self, id: &str) -> Result<Vec<&SkillDescriptor>, SkillRegistryError> {
        let mut visiting = BTreeSet::new();
        let mut visited = BTreeSet::new();
        let mut output = Vec::new();
        self.visit(id, &mut visiting, &mut visited, &mut output)?;
        Ok(output)
    }

    fn visit<'a>(
        &'a self,
        id: &str,
        visiting: &mut BTreeSet<String>,
        visited: &mut BTreeSet<String>,
        output: &mut Vec<&'a SkillDescriptor>,
    ) -> Result<(), SkillRegistryError> {
        if visited.contains(id) {
            return Ok(());
        }
        if !visiting.insert(id.to_owned()) {
            return Err(SkillRegistryError::Cycle(id.to_owned()));
        }
        let skill = self
            .skills
            .get(id)
            .ok_or_else(|| SkillRegistryError::Unknown(id.to_owned()))?;
        for dependency in &skill.requires {
            self.visit(dependency, visiting, visited, output)?;
        }
        visiting.remove(id);
        visited.insert(id.to_owned());
        output.push(skill);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn skill(id: &str, source: SkillSource, requires: &[&str]) -> SkillDescriptor {
        SkillDescriptor {
            id: id.into(),
            name: id.into(),
            description: String::new(),
            source,
            risk: SkillRisk::ReadOnly,
            requires: requires.iter().map(|value| (*value).into()).collect(),
        }
    }

    #[test]
    fn resolves_composite_skills_dependency_first() {
        let mut registry = SkillRegistry::default();
        registry
            .register(skill("computer.history", SkillSource::BuiltIn, &[]))
            .unwrap();
        registry
            .register(skill(
                "github.current_project",
                SkillSource::Mcp {
                    server: "github".into(),
                },
                &[],
            ))
            .unwrap();
        registry
            .register(skill(
                "understand_current_work",
                SkillSource::Composite,
                &["computer.history", "github.current_project"],
            ))
            .unwrap();

        let plan = registry.resolve_plan("understand_current_work").unwrap();
        assert_eq!(
            plan.iter().map(|skill| skill.id.as_str()).collect::<Vec<_>>(),
            vec![
                "computer.history",
                "github.current_project",
                "understand_current_work"
            ]
        );
    }
}
