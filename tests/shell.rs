use std::{
    io::Write,
    process::{Command, Output, Stdio},
};

use anyhow::{Context, Result};
use fabric::{
    config::{FabricHome, PeerBook},
    daemon::FabricNode,
};
use tempfile::TempDir;

fn fabric_bin() -> &'static str {
    env!("CARGO_BIN_EXE_fabric")
}

fn run_shell(home: &FabricHome, peer: &str, input: &str) -> Result<Output> {
    let mut child = Command::new(fabric_bin())
        .arg("--home")
        .arg(home.root())
        .arg("shell")
        .arg(peer)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn fabric shell")?;

    child
        .stdin
        .as_mut()
        .context("fabric shell stdin missing")?
        .write_all(input.as_bytes())?;

    child.wait_with_output().context("fabric shell failed")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn trusted_peer_with_allow_shell_runs_remote_shell_and_propagates_exit() -> Result<()> {
    let node_a_dir = TempDir::new()?;
    let node_b_dir = TempDir::new()?;
    let node_a_home = FabricHome::new(node_a_dir.path());
    let node_b_home = FabricHome::new(node_b_dir.path());

    let node_a = FabricNode::start_with_options(node_a_home.clone(), true).await?;
    let node_b = FabricNode::start(node_b_home.clone()).await?;
    trust_peer(
        &node_a_home,
        &node_a,
        node_b.id(),
        Some("node-b"),
        Some(node_b.addr()),
    )
    .await?;
    trust_peer(
        &node_b_home,
        &node_b,
        node_a.id(),
        Some("node-a"),
        Some(node_a.addr()),
    )
    .await?;

    let output = run_shell(
        &node_b_home,
        "node-a",
        "printf 'fabric-shell-ok\\n'; exit 7\n",
    )?;
    assert_eq!(output.status.code(), Some(7));
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("fabric-shell-ok"),
        "stdout was: {}",
        String::from_utf8_lossy(&output.stdout)
    );

    node_b.shutdown().await?;
    node_a.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn trusted_peer_without_allow_shell_is_refused() -> Result<()> {
    let node_a_dir = TempDir::new()?;
    let node_b_dir = TempDir::new()?;
    let node_a_home = FabricHome::new(node_a_dir.path());
    let node_b_home = FabricHome::new(node_b_dir.path());

    let node_a = FabricNode::start(node_a_home.clone()).await?;
    let node_b = FabricNode::start(node_b_home.clone()).await?;
    trust_peer(
        &node_a_home,
        &node_a,
        node_b.id(),
        Some("node-b"),
        Some(node_b.addr()),
    )
    .await?;
    trust_peer(
        &node_b_home,
        &node_b,
        node_a.id(),
        Some("node-a"),
        Some(node_a.addr()),
    )
    .await?;

    let output = run_shell(&node_b_home, "node-a", "exit 0\n")?;
    assert_eq!(output.status.code(), Some(126));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("remote shell is disabled"),
        "stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    node_b.shutdown().await?;
    node_a.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn untrusted_peer_is_refused_even_when_shell_is_allowed() -> Result<()> {
    let node_a_dir = TempDir::new()?;
    let node_c_dir = TempDir::new()?;
    let node_a_home = FabricHome::new(node_a_dir.path());
    let node_c_home = FabricHome::new(node_c_dir.path());

    let node_a = FabricNode::start_with_options(node_a_home.clone(), true).await?;
    let node_c = FabricNode::start(node_c_home.clone()).await?;
    trust_peer(
        &node_c_home,
        &node_c,
        node_a.id(),
        Some("node-a"),
        Some(node_a.addr()),
    )
    .await?;

    let output = run_shell(&node_c_home, "node-a", "echo should-not-run\n")?;
    assert!(
        !output.status.success(),
        "untrusted shell unexpectedly succeeded"
    );
    assert!(
        !String::from_utf8_lossy(&output.stdout).contains("should-not-run"),
        "untrusted shell command ran: {}",
        String::from_utf8_lossy(&output.stdout)
    );

    node_c.shutdown().await?;
    node_a.shutdown().await?;
    Ok(())
}

async fn trust_peer(
    home: &FabricHome,
    node: &FabricNode,
    id: iroh::EndpointId,
    name: Option<&str>,
    addr: Option<iroh::EndpointAddr>,
) -> Result<()> {
    let mut peers = PeerBook::load(home)?;
    peers.add(id, name.map(str::to_string), addr);
    peers.save(home)?;
    node.state().reload_peers().await?;
    Ok(())
}
