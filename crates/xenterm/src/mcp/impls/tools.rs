use anyhow::Result;
use serde_json::{json, Value};

pub(super) fn definitions() -> Value {
    json!([
        {
            "name": "get_settings",
            "description": "Read non-secret application settings and an opaque revision from the explicitly selected profile. Requires MCP enabled. Does not expose sessions, credentials or permission-setting fields.",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "additionalProperties": false
            },
            "annotations": {
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            }
        },
        {
            "name": "update_settings",
            "description": "Update a strict subset of non-secret settings using the expected_revision returned by get_settings. Requires an explicit profile and MCP enabled. This version reuses configuration-change authorization: both --allow-config-import and configured file-transfer permission are required. Never changes permissions or credentials. Returns the committed settings snapshot; conflicts require reload and user review, not blind retry.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "patch": {
                        "type": "object",
                        "properties": {
                            "session_logs": {
                                "type": "boolean"
                            },
                            "cursor_style": {
                                "type": "string",
                                "enum": [
                                    "block",
                                    "bar",
                                    "underline"
                                ]
                            },
                            "line_spacing": {
                                "type": "number",
                                "minimum": 0.8,
                                "maximum": 1.5
                            },
                            "padding": {
                                "type": "boolean"
                            },
                            "bold": {
                                "type": "boolean"
                            },
                            "sftp_follow_cd": {
                                "type": "boolean"
                            },
                            "download_dir": {
                                "type": "string",
                                "maxLength": 4096
                            },
                            "language": {
                                "type": "string",
                                "enum": [
                                    "system",
                                    "en",
                                    "zh"
                                ]
                            },
                            "theme_pref": {
                                "type": "string",
                                "enum": [
                                    "system",
                                    "dark",
                                    "light"
                                ]
                            },
                            "font_family": {
                                "type": "string",
                                "maxLength": 256
                            },
                            "font_size": {
                                "type": "integer",
                                "minimum": 8,
                                "maximum": 32
                            },
                            "ui_font_family": {
                                "type": "string",
                                "maxLength": 256
                            },
                            "ui_font_size": {
                                "type": "integer",
                                "minimum": 8,
                                "maximum": 32
                            }
                        },
                        "additionalProperties": false
                    },
                    "expected_revision": {
                        "type": "string"
                    }
                },
                "required": [
                    "patch",
                    "expected_revision"
                ],
                "additionalProperties": false
            },
            "annotations": {
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            }
        },
        {
            "name": "get_access_policy",
            "description": "Read the configured MCP access mode and effective permissions without changing them. Full access permits SSH commands and file operations; restricted access follows configured capability rules. Execution history is optional and off by default. SSH account and server permissions always apply. Contains no credentials. Access mode can only be changed locally in Settings > MCP & permissions or with xenterm cli permissions.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
        },
        {
            "name": "import_sessions",
            "description": "Preview or append sessions from a local MeatShell/XenTerm v1 portable export, native sessions.json, or FinalShell JSON. Defaults to dry_run=true. Applying requires --allow-config-import; all calls require the MCP file-transfer permission. Existing sessions are never overwritten: equivalent complete profiles are skipped and distinct aliases get fresh IDs. Returns counts and fixed compatibility warnings without source field values. Export files contain reversible credential obfuscation and must be kept private.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "local_path": {"type": "string", "minLength": 1, "description": "JSON file on the server host, at most 16 MiB."},
                    "dry_run": {"type": "boolean", "default": true}
                },
                "required": ["local_path"],
                "additionalProperties": false
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
        },
        {
            "name": "list_sessions",
            "description": "List saved XenTerm sessions without exposing passwords, private keys, or other secrets. Requires the MCP saved-credentials permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "group": { "type": "string", "description": "Optional exact session group filter." }
                },
                "additionalProperties": false
            }
        },
        {
            "name": "get_session",
            "description": "Get non-secret connection metadata for one saved XenTerm session. Requires the MCP saved-credentials permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Stable session id returned by list_sessions." }
                },
                "required": ["session_id"],
                "additionalProperties": false
            }
        },
        {
            "name": "run_command",
            "description": "Execute one non-interactive command on a saved SSH session. Requires the MCP saved-credentials and arbitrary-command permissions. Use get_access_policy to inspect the configured capabilities and optional execution history. SSH account and server permissions apply. XenTerm does not request per-operation risk approval.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Stable session id returned by list_sessions." },
                    "command": { "type": "string", "minLength": 1 },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "default": 30 },
                    "max_output_bytes": { "type": "integer", "minimum": 1024, "maximum": 4194304, "default": 1048576 }
                },
                "required": ["session_id", "command"],
                "additionalProperties": false
            }
        },
        {
            "name": "list_remote_files",
            "description": "List a remote directory over XenTerm SFTP without exposing credentials. Requires the MCP file-transfer permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string" },
                    "path": { "type": "string", "default": "." },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "default": 30 }
                },
                "required": ["session_id"],
                "additionalProperties": false
            }
        },
        {
            "name": "read_remote_text_file",
            "description": "Read a bounded UTF-8 text file over XenTerm SFTP. Binary, oversized, or excessively long files are rejected. Requires the MCP file-transfer permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string" },
                    "path": { "type": "string", "minLength": 1 },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "default": 30 }
                },
                "required": ["session_id", "path"],
                "additionalProperties": false
            }
        },
        {
            "name": "upload_file",
            "description": "Upload one local file to a remote directory over XenTerm SFTP. Requires the MCP file-transfer permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string" },
                    "local_path": { "type": "string", "minLength": 1 },
                    "remote_directory": { "type": "string", "minLength": 1 },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "default": 120 }
                },
                "required": ["session_id", "local_path", "remote_directory"],
                "additionalProperties": false
            }
        },
        {
            "name": "download_file",
            "description": "Download one remote file into an existing local directory over XenTerm SFTP. Existing files are not overwritten. Requires the MCP file-transfer permission.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string" },
                    "remote_path": { "type": "string", "minLength": 1 },
                    "local_directory": { "type": "string", "minLength": 1 },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "default": 120 }
                },
                "required": ["session_id", "remote_path", "local_directory"],
                "additionalProperties": false
            }
        }
    ])
}

pub(super) async fn call_mcp(
    name: &str,
    arguments: &Value,
    allow_config_import: bool,
) -> Result<Value> {
    crate::automation::call(
        name,
        arguments,
        crate::automation::Frontend::Mcp {
            allow_config_import,
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn definitions_do_not_expose_secret_arguments() {
        let text = definitions().to_string();
        assert!(!text.contains("\"password\":"));
        assert!(!text.contains("\"private_key_inline\":"));
        assert!(text.contains("run_command"));
    }

    #[test]
    fn settings_tools_describe_strict_schema_and_existing_write_authorization() {
        let definitions = definitions();
        let tools = definitions.as_array().unwrap();
        let update = tools.iter().find(|v| v["name"] == "update_settings").unwrap();
        let schema = &update["inputSchema"];
        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(schema["properties"]["patch"]["additionalProperties"], false);
        assert_eq!(schema["properties"]["patch"]["properties"].as_object().unwrap().len(), 13);
        assert!(update["description"].as_str().unwrap().contains("--allow-config-import"));
        assert!(update["description"].as_str().unwrap().contains("file-transfer"));
        assert_eq!(update["annotations"]["readOnlyHint"], false);
        assert!(schema["properties"]["patch"]["properties"].get("mcp_enabled").is_none());
    }
}
