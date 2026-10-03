//! Explicit CLI updates from a native encrypted snapshot; no network or MCP access.
use super::*;
use std::collections::HashSet;

impl ConfigStore {
    pub fn sync_native_snapshot(&mut self, path: &Path) -> Result<(usize, usize)> {
        let raw = import::read_import(path)?;
        let value: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|_| anyhow::anyhow!("invalid native snapshot JSON"))?;
        let rows = value.get("sessions").cloned()
            .ok_or_else(|| anyhow::anyhow!("snapshot must contain sessions"))?;
        let mut incoming: Vec<Session> = serde_json::from_value(rows)
            .map_err(|_| anyhow::anyhow!("invalid snapshot sessions"))?;
        let mut seen = HashSet::new();
        let mut candidate = self.cache.clone();
        let (mut updated, mut added) = (0, 0);
        for (index, session) in incoming.iter_mut().enumerate() {
            anyhow::ensure!(!session.id.trim().is_empty() && seen.insert(session.id.clone()),
                "snapshot contains an empty or repeated ID");
            if matches!(session.kind, SessionKind::Ssh | SessionKind::Telnet) {
                anyhow::ensure!(super::super::validation::is_valid_hostname(
                    session.host.strip_suffix('.').unwrap_or(&session.host)) && session.port > 0,
                    "snapshot contains an invalid endpoint");
            }
            self.decode_import_secret(&mut session.password, index, "password")?;
            self.decode_import_secret(&mut session.private_key_inline, index, "private key")?;
            for trigger in &mut session.triggers {
                self.decode_import_secret(&mut trigger.response, index, "trigger response")?;
            }
            let mut bad_proxy = false;
            if let Some(proxy) = Self::map_proxy_password(&session.proxy, |password| {
                let mut secret = Secret::new(password);
                if self.decode_import_secret(&mut secret, index, "proxy password").is_err() {
                    bad_proxy = true; return None;
                }
                Some(secret.as_str().to_string())
            }) { session.proxy = proxy; }
            anyhow::ensure!(!bad_proxy, "snapshot proxy credential could not be decrypted");
            // Remote snapshots never grant GUI credential-reveal consent.
            if let Some(existing) = candidate.sessions.iter_mut().find(|s| s.id == session.id) {
                session.allow_secret_reveal = existing.allow_secret_reveal;
                if serde_json::to_value(&*existing)? != serde_json::to_value(&*session)? {
                    *existing = session.clone(); updated += 1;
                }
            } else {
                session.allow_secret_reveal = false;
                candidate.sessions.push(session.clone()); added += 1;
            }
        }
        for session in &candidate.sessions {
            super::super::jump_chain::resolve_jump_chain(&candidate.sessions, session)?;
        }
        if updated == 0 && added == 0 { return Ok((0, 0)); }
        // Save uses the existing ordered transaction and stale-writer guard.
        // Retain destination-only entries and settings; source deletion is additive.
        let original = std::mem::replace(&mut self.cache, candidate);
        if let Err(error) = self.save_all() {
            self.cache = original; return Err(error);
        }
        Ok((updated, added))
    }
}
