//! The LensWorks MCP bridge: MCP (JSON-RPC 2.0, newline-delimited on stdio) on one side, the LensWorks automation
//! socket on the other. `initialize`, `ping` and notifications are answered here; `tools/list` and `tools/call` are
//! forwarded to the app, which owns the tool definitions, command registry, dispatch and confirmations.
//!
//! App protocol (one JSON object per line): the bridge sends `{"type":"hello","secret":…}` and receives
//! `{"type":"welcome",…}` or `{"type":"refused","reason":…}`; then `{"id":…,"method":…,"params":…}` requests are
//! answered by `{"id":…,"result":…}` or `{"id":…,"error":{"code":…,"message":…}}`.
use serde_json::{Value, json};
use std::ffi::{CStr, c_char, c_int};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

pub const SUPPORTED_PROTOCOLS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
/// The largest app reply accepted (a bounded preview PNG in base64 fits well inside).
pub const REPLY_LIMIT: u64 = 64 << 20;
/// A tool call may wait on the person confirming a permanent delete in the app (the app times out at 120 s).
pub const REPLY_TIMEOUT: Duration = Duration::from_secs(300);

/// JSON-RPC error code for a refused or unreachable LensWorks.
pub const REFUSED: i64 = -32001;

unsafe extern "C" {
    fn confstr(name: c_int, buf: *mut c_char, len: usize) -> usize;
}
const CS_DARWIN_USER_TEMP_DIR: c_int = 65537;

/// The app's default socket: `<per-user temp dir>/net.trefry.lensworks.automation/automation.sock`.
pub fn default_socket_path() -> PathBuf {
    let mut buffer = vec![0 as c_char; 1024];
    // SAFETY: the buffer is writable for its full length and confstr NUL-terminates within it.
    let length = unsafe { confstr(CS_DARWIN_USER_TEMP_DIR, buffer.as_mut_ptr(), buffer.len()) };
    let base = if length > 0 && length <= buffer.len() {
        // SAFETY: confstr wrote a NUL-terminated string into the buffer.
        PathBuf::from(
            unsafe { CStr::from_ptr(buffer.as_ptr()) }
                .to_string_lossy()
                .into_owned(),
        )
    } else {
        std::env::temp_dir()
    };
    base.join("net.trefry.lensworks.automation/automation.sock")
}

struct Link {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

pub struct Bridge {
    secret: Option<String>,
    socket: PathBuf,
    link: Option<Link>,
}

/// Why a forwarded request failed: an app answer (`code`, `message`) or a refused/unreachable connection.
#[derive(Debug, PartialEq)]
pub struct Failure {
    pub code: i64,
    pub message: String,
}

fn refused(message: impl Into<String>) -> Failure {
    Failure {
        code: REFUSED,
        message: message.into(),
    }
}

impl Bridge {
    pub fn new(secret: Option<String>, socket: PathBuf) -> Self {
        Self {
            secret: secret.filter(|value| !value.is_empty()),
            socket,
            link: None,
        }
    }

    pub fn from_environment() -> Self {
        let socket = std::env::var_os("LENSWORKS_MCP_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(default_socket_path);
        Self::new(std::env::var("LENSWORKS_MCP_SECRET").ok(), socket)
    }

    /// One MCP message in, at most one message out (none for notifications and responses).
    pub fn handle(&mut self, line: &str) -> Option<String> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        let message: Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(error) => {
                return Some(error_reply(
                    Value::Null,
                    -32700,
                    &format!("Parse error: {error}"),
                ));
            }
        };
        let Some(object) = message.as_object() else {
            return Some(error_reply(
                Value::Null,
                -32600,
                "Each message must be one JSON-RPC object.",
            ));
        };
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            return None; // A response to a server request; this server sends none.
        };
        let Some(id) = object.get("id").cloned() else {
            return None; // Notifications (initialized, cancelled) need no answer.
        };
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        let reply = match method {
            "initialize" => Ok(initialize(&params)),
            "ping" => Ok(json!({})),
            "tools/list" | "tools/call" => self.forward(method, params),
            _ => Err(Failure {
                code: -32601,
                message: format!("Method not found: {method}"),
            }),
        };
        Some(match reply {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string(),
            Err(failure) => error_reply(id, failure.code, &failure.message),
        })
    }

    /// Sends one request to the app, connecting (and reconnecting once after a dropped connection) as needed.
    pub fn forward(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        let reused = self.link.is_some();
        match self.exchange(method, &params) {
            Err(failure)
                if reused && failure.code == REFUSED && failure.message.contains("connection") =>
            {
                self.link = None;
                self.exchange(method, &params)
            }
            other => other,
        }
    }

    fn exchange(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        if self.link.is_none() {
            self.link = Some(self.connect()?);
        }
        let link = self.link.as_mut().expect("connected");
        link.next_id += 1;
        let id = link.next_id;
        let request = json!({"id": id, "method": method, "params": params}).to_string() + "\n";
        let reply = link
            .writer
            .write_all(request.as_bytes())
            .map_err(|error| {
                refused(format!(
                    "LensWorks closed the automation connection: {error}"
                ))
            })
            .and_then(|()| read_line(&mut link.reader));
        let reply = match reply {
            Ok(reply) => reply,
            Err(failure) => {
                self.link = None;
                return Err(failure);
            }
        };
        if reply.get("id").and_then(Value::as_u64) != Some(id) {
            self.link = None;
            return Err(refused(
                "LensWorks answered out of order; the connection was reset.",
            ));
        }
        if let Some(error) = reply.get("error") {
            return Err(Failure {
                code: error.get("code").and_then(Value::as_i64).unwrap_or(-32603),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("LensWorks reported an error.")
                    .to_owned(),
            });
        }
        reply
            .get("result")
            .cloned()
            .ok_or_else(|| refused("LensWorks sent a reply without a result."))
    }

    fn connect(&self) -> Result<Link, Failure> {
        let Some(secret) = &self.secret else {
            return Err(refused(
                "LENSWORKS_MCP_SECRET is not set. Copy the client configuration from LensWorks Settings › Automation.",
            ));
        };
        let stream = UnixStream::connect(&self.socket).map_err(|error| {
            refused(format!(
                "LensWorks automation is off, or LensWorks is not running (no automation socket at {}: {error}). Turn it on in LensWorks Settings › Automation.",
                self.socket.display()
            ))
        })?;
        let io =
            |error: std::io::Error| refused(format!("The automation connection failed: {error}"));
        stream.set_read_timeout(Some(REPLY_TIMEOUT)).map_err(io)?;
        let mut writer = stream.try_clone().map_err(io)?;
        let mut reader = BufReader::new(stream);
        let hello = json!({"type": "hello", "secret": secret, "bridge": env!("CARGO_PKG_VERSION")})
            .to_string()
            + "\n";
        writer.write_all(hello.as_bytes()).map_err(io)?;
        let answer = read_line(&mut reader).map_err(|failure| {
            refused(format!(
                "LensWorks refused the connection: {}",
                failure.message
            ))
        })?;
        match answer.get("type").and_then(Value::as_str) {
            Some("welcome") => Ok(Link {
                writer,
                reader,
                next_id: 0,
            }),
            _ => Err(refused(format!(
                "LensWorks refused the connection: {}",
                answer
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("no reason given")
            ))),
        }
    }
}

fn read_line(reader: &mut BufReader<UnixStream>) -> Result<Value, Failure> {
    let mut line = String::new();
    let count = reader
        .by_ref()
        .take(REPLY_LIMIT)
        .read_line(&mut line)
        .map_err(|error| refused(format!("The automation connection failed: {error}")))?;
    if count == 0 || !line.ends_with('\n') {
        return Err(refused("LensWorks closed the automation connection."));
    }
    serde_json::from_str(&line)
        .map_err(|error| refused(format!("LensWorks sent malformed JSON: {error}")))
}

fn initialize(params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = requested
        .filter(|value| SUPPORTED_PROTOCOLS.contains(value))
        .unwrap_or(SUPPORTED_PROTOCOLS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": "lensworks", "title": "LensWorks", "version": env!("CARGO_PKG_VERSION")},
        "instructions": "Drives the running LensWorks app. Call get_state for layer and catalog ids, list_commands for what can run now and why not, invoke_command to run one (edits are labeled “(Agent)” in LensWorks history and Undo reverts them; permanent deletes ask the person first), and render_preview to see the result."
    })
}

fn error_reply(id: Value, code: i64, message: &str) -> String {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::thread;

    /// A stand-in app: accepts connections, checks the secret, answers tools/list with one tool.
    fn fake_app(secret: &'static str) -> (tempdir::Dir, PathBuf) {
        let dir = tempdir::Dir::new();
        let path = dir.0.join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let hello: Value = serde_json::from_str(&line).unwrap();
                    if hello["secret"] != secret {
                        writeln!(writer, "{}", json!({"type": "refused", "reason": "The automation secret is not valid."})).unwrap();
                        return;
                    }
                    writeln!(writer, "{}", json!({"type": "welcome"})).unwrap();
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            return;
                        }
                        let request: Value = serde_json::from_str(&line).unwrap();
                        let reply = match request["method"].as_str() {
                            Some("tools/list") => {
                                json!({"id": request["id"], "result": {"tools": [{"name": "get_state"}]}})
                            }
                            _ => {
                                json!({"id": request["id"], "error": {"code": -32602, "message": "Unknown tool: nope"}})
                            }
                        };
                        writeln!(writer, "{reply}").unwrap();
                    }
                });
            }
        });
        (dir, path)
    }

    mod tempdir {
        pub struct Dir(pub std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let path =
                    std::path::PathBuf::from(format!("/tmp/lwmcp-{}-{n}", std::process::id()));
                std::fs::create_dir_all(&path).unwrap();
                Self(path)
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    fn call(bridge: &mut Bridge, message: Value) -> Value {
        serde_json::from_str(&bridge.handle(&message.to_string()).unwrap()).unwrap()
    }

    #[test]
    fn initialize_negotiates_a_supported_protocol_without_contacting_the_app() {
        let mut bridge = Bridge::new(None, PathBuf::from("/nonexistent/s.sock"));
        let reply = call(
            &mut bridge,
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
        );
        assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(
            reply["result"]["capabilities"]["tools"]["listChanged"],
            false
        );
        let reply = call(
            &mut bridge,
            json!({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}),
        );
        assert_eq!(reply["result"]["protocolVersion"], SUPPORTED_PROTOCOLS[0]);
        assert!(
            bridge
                .handle(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                .is_none()
        );
        assert_eq!(
            call(
                &mut bridge,
                json!({"jsonrpc": "2.0", "id": 3, "method": "ping"})
            )["result"],
            json!({})
        );
        assert_eq!(
            call(
                &mut bridge,
                json!({"jsonrpc": "2.0", "id": 4, "method": "resources/list"})
            )["error"]["code"],
            -32601
        );
        assert_eq!(
            serde_json::from_str::<Value>(&bridge.handle("not json").unwrap()).unwrap()["error"]["code"],
            -32700
        );
    }

    #[test]
    fn tools_requests_are_forwarded_after_the_secret_handshake() {
        let (_dir, path) = fake_app("right");
        let mut bridge = Bridge::new(Some("right".into()), path);
        let reply = call(
            &mut bridge,
            json!({"jsonrpc": "2.0", "id": "a", "method": "tools/list"}),
        );
        assert_eq!(reply["id"], "a");
        assert_eq!(reply["result"]["tools"][0]["name"], "get_state");
        let reply = call(
            &mut bridge,
            json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "nope"}}),
        );
        assert_eq!(
            reply["error"],
            json!({"code": -32602, "message": "Unknown tool: nope"})
        );
    }

    #[test]
    fn a_wrong_or_missing_secret_and_a_missing_socket_are_refused_with_the_reason() {
        let (_dir, path) = fake_app("right");
        let mut wrong = Bridge::new(Some("wrong".into()), path.clone());
        let reply = call(
            &mut wrong,
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        );
        assert_eq!(reply["error"]["code"], REFUSED);
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("secret is not valid")
        );
        let mut missing = Bridge::new(None, path);
        let reply = call(
            &mut missing,
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        );
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("LENSWORKS_MCP_SECRET is not set")
        );
        let mut off = Bridge::new(
            Some("right".into()),
            PathBuf::from("/tmp/lwmcp-none/s.sock"),
        );
        let reply = call(
            &mut off,
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        );
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("automation is off")
        );
    }

    #[test]
    fn default_socket_is_in_the_per_user_temp_directory() {
        let path = default_socket_path();
        assert!(path.ends_with("net.trefry.lensworks.automation/automation.sock"));
        assert!(
            path.starts_with("/var/folders")
                || path.starts_with("/private/var/folders")
                || path.starts_with(std::env::temp_dir())
        );
    }
}
