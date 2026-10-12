//! `LensWorksMCP` (Contents/Helpers): an MCP server on stdio that an agent's MCP client launches. It forwards tool
//! requests to the running LensWorks app over its owner-only automation socket, authenticating with the secret from
//! Settings › Automation (`LENSWORKS_MCP_SECRET`).
use std::io::{self, BufRead, Write};

fn main() {
    let mut bridge = lensworks_mcp::Bridge::from_environment();
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if let Some(reply) = bridge.handle(&line)
            && writeln!(stdout, "{reply}")
                .and_then(|()| stdout.flush())
                .is_err()
        {
            break;
        }
    }
}
