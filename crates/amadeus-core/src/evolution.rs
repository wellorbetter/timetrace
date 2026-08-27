use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EvolutionDomain {
    Behavior,
    Relationship,
    Skill,
    Persona,
    Identity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EvolutionRisk {
    Low,
    Medium,
    High,
    Protected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EvolutionStatus {
    Proposed,
    Accepted,
    Rejected,
    Applied,
    RolledBack,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EvolutionCandidate {
    pub id: String,
    pub domain: EvolutionDomain,
    pub risk: EvolutionRisk,
    pub summary: String,
    pub evidence: Vec<String>,
    pub confidence: f32,
    pub created_at: DateTime<Utc>,
    pub status: EvolutionStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvolutionDecision {
    AutoAccept,
    RequireApproval,
    Reject,
}

/// Guardrails for self-evolution.
///
/// Identity and high-risk persona changes are never silently adopted. Low-risk
/// behavioral/relationship/skill adaptations can be auto-accepted only when
/// confidence is high enough; every candidate remains auditable and rollbackable.
#[derive(Debug, Clone)]
pub struct EvolutionPolicy {
    pub auto_accept_confidence: f32,
}

impl Default for EvolutionPolicy {
    fn default() -> Self {
        Self {
            auto_accept_confidence: 0.9,
        }
    }
}

impl EvolutionPolicy {
    pub fn decide(&self, candidate: &EvolutionCandidate) -> EvolutionDecision {
        if candidate.domain == EvolutionDomain::Identity
            || candidate.risk == EvolutionRisk::Protected
        {
            return EvolutionDecision::RequireApproval;
        }
        if matches!(candidate.domain, EvolutionDomain::Persona)
            || matches!(candidate.risk, EvolutionRisk::High)
        {
            return EvolutionDecision::RequireApproval;
        }
        if candidate.risk == EvolutionRisk::Low
            && candidate.confidence >= self.auto_accept_confidence
        {
            return EvolutionDecision::AutoAccept;
        }
        EvolutionDecision::RequireApproval
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(domain: EvolutionDomain, risk: EvolutionRisk, confidence: f32) -> EvolutionCandidate {
        EvolutionCandidate {
            id: "candidate".into(),
            domain,
            risk,
            summary: String::new(),
            evidence: Vec::new(),
            confidence,
            created_at: Utc::now(),
            status: EvolutionStatus::Proposed,
        }
    }

    #[test]
    fn identity_never_auto_evolves() {
        let policy = EvolutionPolicy::default();
        assert_eq!(
            policy.decide(&candidate(EvolutionDomain::Identity, EvolutionRisk::Low, 1.0)),
            EvolutionDecision::RequireApproval
        );
    }

    #[test]
    fn high_confidence_low_risk_skill_adaptation_can_auto_accept() {
        let policy = EvolutionPolicy::default();
        assert_eq!(
            policy.decide(&candidate(EvolutionDomain::Skill, EvolutionRisk::Low, 0.95)),
            EvolutionDecision::AutoAccept
        );
    }
}
