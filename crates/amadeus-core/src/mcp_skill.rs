use serde_json::Value;

use crate::mcp::{McpClient, McpTransport};
use crate::skill_runtime::SkillExecutor;

/// Adapts one MCP tool into Amadeus' generic skill execution interface.
pub struct McpToolExecutor<T: McpTransport> {
    client: McpClient<T>,
    tool_name: String,
}

impl<T: McpTransport> McpToolExecutor<T> {
    pub fn new(client: McpClient<T>, tool_name: impl Into<String>) -> Self {
        Self { client, tool_name: tool_name.into() }
    }
}

impl<T: McpTransport> SkillExecutor for McpToolExecutor<T> {
    fn execute(&mut self, arguments: &Value) -> Result<Value, String> {
        let result = self
            .client
            .call_tool(&self.tool_name, arguments.clone())
            .map_err(|error| error.to_string())?;
        if result.is_error {
            return Err(serde_json::to_string(&result.content).unwrap_or_else(|_| "MCP tool error".into()));
        }
        Ok(result.structured_content.unwrap_or_else(|| Value::Array(result.content)))
    }
}
