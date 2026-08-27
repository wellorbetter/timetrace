use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;

use crate::skills::{SkillDescriptor, SkillRisk, SkillSource};

pub const MCP_PROTOCOL_VERSION: &str = "2026-07-28";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpImplementation {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct McpToolDefinition {
    pub name: String,
    pub title: Option<String>,
    pub description: Option<String>,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
    #[serde(rename = "outputSchema", default)]
    pub output_schema: Option<Value>,
}

impl McpToolDefinition {
    /// MCP annotations are intentionally not trusted for safety decisions.
    /// Unknown remote tools therefore enter the skill registry conservatively.
    pub fn as_skill(&self, server: &str) -> SkillDescriptor {
        SkillDescriptor {
            id: format!("mcp.{server}.{}", self.name),
            name: self.title.clone().unwrap_or_else(|| self.name.clone()),
            description: self.description.clone().unwrap_or_default(),
            source: SkillSource::Mcp { server: server.to_owned() },
            risk: SkillRisk::ExternalWrite,
            requires: vec![],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct McpToolResult {
    pub content: Vec<Value>,
    #[serde(rename = "structuredContent", default)]
    pub structured_content: Option<Value>,
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

#[derive(Debug, Error)]
pub enum McpError {
    #[error("transport: {0}")]
    Transport(String),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

pub trait McpTransport: Send {
    fn request(&mut self, request: Value) -> Result<Value, McpError>;
}

/// Simple modern MCP stdio transport.
///
/// The 2026 protocol is self-contained per request, so this implementation can
/// safely use a fresh stdio server process for each call. A future pooled
/// transport can reuse processes without changing the client/tool contracts.
pub struct ModernStdioTransport {
    command: String,
    args: Vec<String>,
    timeout: Duration,
}

impl ModernStdioTransport {
    pub fn new(command: impl Into<String>, args: Vec<String>) -> Self {
        Self { command: command.into(), args, timeout: Duration::from_secs(20) }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }
}

impl McpTransport for ModernStdioTransport {
    fn request(&mut self, request: Value) -> Result<Value, McpError> {
        let request_id = request.get("id").cloned();
        let mut child = Command::new(&self.command)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| McpError::Transport(format!("spawn {}: {error}", self.command)))?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| McpError::Transport("stdio server has no stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| McpError::Transport("stdio server has no stdout".into()))?;
        let payload = serde_json::to_string(&request)?;
        writeln!(stdin, "{payload}")?;
        stdin.flush()?;
        drop(stdin);

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(line) if !line.trim().is_empty() => {
                        if let Ok(value) = serde_json::from_str::<Value>(&line) {
                            if request_id.is_none() || value.get("id") == request_id.as_ref() {
                                let _ = tx.send(Ok(value));
                                return;
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        let _ = tx.send(Err(McpError::Io(error)));
                        return;
                    }
                }
            }
            let _ = tx.send(Err(McpError::Transport(
                "stdio server exited without a matching response".into(),
            )));
        });

        let response = rx
            .recv_timeout(self.timeout)
            .map_err(|_| McpError::Transport("stdio MCP request timed out".into()))?;
        let _ = child.kill();
        let _ = child.wait();
        response
    }
}

pub struct McpClient<T: McpTransport> {
    transport: T,
    client: McpImplementation,
    next_id: u64,
}

impl<T: McpTransport> McpClient<T> {
    pub fn new(transport: T, client: McpImplementation) -> Self {
        Self { transport, client, next_id: 1 }
    }

    pub fn list_tools(&mut self) -> Result<Vec<McpToolDefinition>, McpError> {
        let response = self.call("tools/list", json!({}))?;
        let tools = response
            .get("tools")
            .cloned()
            .ok_or_else(|| McpError::Protocol("tools/list missing result.tools".into()))?;
        Ok(serde_json::from_value(tools)?)
    }

    pub fn call_tool(&mut self, name: &str, arguments: Value) -> Result<McpToolResult, McpError> {
        let response = self.call(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )?;
        Ok(serde_json::from_value(response)?)
    }

    fn call(&mut self, method: &str, mut params: Value) -> Result<Value, McpError> {
        let id = self.next_id;
        self.next_id += 1;
        let params_object = params
            .as_object_mut()
            .ok_or_else(|| McpError::Protocol("MCP params must be an object".into()))?;
        params_object.insert(
            "_meta".into(),
            json!({
                "io.modelcontextprotocol/protocolVersion": MCP_PROTOCOL_VERSION,
                "io.modelcontextprotocol/clientInfo": self.client,
                "io.modelcontextprotocol/clientCapabilities": {}
            }),
        );
        let response = self.transport.request(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        }))?;
        if let Some(error) = response.get("error") {
            return Err(McpError::Protocol(error.to_string()));
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| McpError::Protocol("JSON-RPC response missing result".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockTransport {
        responses: Vec<Value>,
        requests: Vec<Value>,
    }

    impl McpTransport for MockTransport {
        fn request(&mut self, request: Value) -> Result<Value, McpError> {
            self.requests.push(request);
            Ok(self.responses.remove(0))
        }
    }

    #[test]
    fn modern_mcp_requests_carry_protocol_metadata_and_map_tools_to_skills() {
        let transport = MockTransport {
            responses: vec![json!({
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "tools": [{
                        "name": "search",
                        "title": "Search",
                        "description": "Search project data",
                        "inputSchema": {"type":"object"}
                    }]
                }
            })],
            requests: vec![],
        };
        let mut client = McpClient::new(
            transport,
            McpImplementation { name: "amadeus".into(), version: "0.1.0".into() },
        );
        let tools = client.list_tools().unwrap();
        assert_eq!(tools[0].as_skill("github").id, "mcp.github.search");
        assert_eq!(tools[0].as_skill("github").risk, SkillRisk::ExternalWrite);
        let request = &client.transport.requests[0];
        assert_eq!(
            request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
            MCP_PROTOCOL_VERSION
        );
    }
}
