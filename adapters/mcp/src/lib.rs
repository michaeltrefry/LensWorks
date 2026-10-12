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
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

pub const SUPPORTED_PROTOCOLS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
/// The largest app reply accepted (a bounded preview PNG in base64 fits well inside).
pub const REPLY_LIMIT: u64 = 64 << 20;
/// The largest request forwarded to the app, which closes a connection that sends a longer line.
pub const REQUEST_LIMIT: usize = 1 << 20;
/// A tool call may wait on the person confirming a permanent delete in the app (the app times out at 120 s).
pub const REPLY_TIMEOUT: Duration = Duration::from_secs(300);

/// JSON-RPC error code for a refused or unreachable LensWorks.
pub const REFUSED: i64 = -32001;

unsafe extern "C" {
    fn confstr(name: c_int, buf: *mut c_char, len: usize) -> usize;
    fn recv(socket: c_int, buffer: *mut u8, length: usize, flags: c_int) -> isize;
}
const CS_DARWIN_USER_TEMP_DIR: c_int = 65537;
const MSG_PEEK: c_int = 0x2;
const MSG_DONTWAIT: c_int = 0x80;

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

impl Link {
    /// Whether the app already closed this connection (it quit, automation was turned off, or the secret changed).
    /// Checked before a request is sent, so a request is never sent twice.
    fn is_closed(&self) -> bool {
        let mut byte = 0u8;
        // SAFETY: the descriptor is open for the life of `writer` and the buffer is one writable byte.
        let count = unsafe {
            recv(
                self.writer.as_raw_fd(),
                &mut byte,
                1,
                MSG_PEEK | MSG_DONTWAIT,
            )
        };
        // 0 is end of stream; an error other than "nothing to read yet" is a dead socket. Bytes waiting with no
        // request outstanding are a protocol violation, so that connection is dropped too.
        count >= 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::WouldBlock
    }
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

    /// Sends one request to the app, connecting first when there is no live connection. A request is sent at most
    /// once: when the connection fails after it was sent, the failure is reported rather than the request repeated,
    /// because the app may already have run it.
    pub fn forward(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        if self.link.as_ref().is_some_and(Link::is_closed) {
            self.link = None;
        }
        self.exchange(method, &params)
    }

    fn exchange(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        if self.link.is_none() {
            self.link = Some(self.connect()?);
        }
        let link = self.link.as_mut().expect("connected");
        link.next_id += 1;
        let id = link.next_id;
        let request = json!({"id": id, "method": method, "params": params}).to_string() + "\n";
        if request.len() > REQUEST_LIMIT {
            return Err(Failure {
                code: -32600,
                message: format!(
                    "The request is {} bytes; LensWorks accepts at most {REQUEST_LIMIT}.",
                    request.len()
                ),
            });
        }
        let reply = link
            .writer
            .write_all(request.as_bytes())
            .map_err(|error| {
                refused(format!(
                    "LensWorks closed the automation connection before answering ({error}); check get_state before repeating the request."
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
        return Err(refused(
            "LensWorks closed the automation connection before answering; check get_state before repeating the request.",
        ));
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

    /// A stand-in app that counts the requests it receives and closes each connection after `answers` replies
    /// (0: it reads the request and closes without answering).
    fn closing_app(
        answers: usize,
    ) -> (
        tempdir::Dir,
        PathBuf,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let dir = tempdir::Dir::new();
        let path = dir.0.join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let received = std::sync::Arc::new(AtomicUsize::new(0));
        let counter = received.clone();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut writer = stream.try_clone().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                writeln!(writer, "{}", json!({"type": "welcome"})).unwrap();
                for answered in 0.. {
                    line.clear();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let count = counter.fetch_add(1, Ordering::SeqCst) + 1;
                    if answered >= answers {
                        break;
                    }
                    writeln!(
                        writer,
                        "{}",
                        json!({"id": request["id"], "result": {"count": count}})
                    )
                    .unwrap();
                    if answered + 1 == answers {
                        break;
                    }
                }
            }
        });
        (dir, path, received)
    }

    #[test]
    fn a_closed_connection_is_replaced_before_the_next_request_is_sent() {
        let (_dir, path, received) = closing_app(1);
        let mut bridge = Bridge::new(Some("s".into()), path);
        let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "invoke_command"}});
        assert_eq!(call_reply(&mut bridge, &call)["result"]["count"], 1);
        // The app closed that connection after answering; the next request goes out once, on a new one.
        thread::sleep(Duration::from_millis(100));
        assert_eq!(call_reply(&mut bridge, &call)["result"]["count"], 2);
        assert_eq!(received.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[test]
    fn a_request_the_app_never_answered_is_reported_and_never_sent_twice() {
        let (_dir, path, received) = closing_app(0);
        let mut bridge = Bridge::new(Some("s".into()), path);
        let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "invoke_command"}});
        let reply = call_reply(&mut bridge, &call);
        assert_eq!(reply["error"]["code"], REFUSED);
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("before answering")
        );
        assert_eq!(received.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn an_oversized_request_is_refused_without_being_sent() {
        let (_dir, path, received) = closing_app(1);
        let mut bridge = Bridge::new(Some("s".into()), path);
        let reply = call_reply(
            &mut bridge,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "x", "arguments": {"pad": "a".repeat(REQUEST_LIMIT)}}}),
        );
        assert_eq!(reply["error"]["code"], -32600);
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("at most 1048576")
        );
        assert_eq!(received.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    fn call_reply(bridge: &mut Bridge, message: &Value) -> Value {
        serde_json::from_str(&bridge.handle(&message.to_string()).unwrap()).unwrap()
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
