//! Protocol-independent, non-secret application settings. GUI, CLI and MCP
//! must use this service rather than reproducing validation or save behavior.
use super::*;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// A partial update; an omitted field is unchanged, while an explicit default
/// (for example an empty font family) is a real choice. JSON null is not omission.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SettingsPatch {
    #[serde(default, deserialize_with = "present")]
    pub session_logs: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    pub cursor_style: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub line_spacing: Option<f32>,
    #[serde(default, deserialize_with = "present")]
    pub padding: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    pub bold: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    pub sftp_follow_cd: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    pub download_dir: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub language: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub theme_pref: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub font_family: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub font_size: Option<u32>,
    #[serde(default, deserialize_with = "present")]
    pub ui_font_family: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pub ui_font_size: Option<u32>,
}

// A present JSON null must not silently become Option::None, even when a Rust
// adapter uses Deserialize directly rather than the shared from_json helper.
fn present<'de, D, T>(deserializer: D) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

const KEYS: &[&str] = &[
    "session_logs", "cursor_style", "line_spacing", "padding", "bold",
    "sftp_follow_cd", "download_dir", "language", "theme_pref", "font_family",
    "font_size", "ui_font_family", "ui_font_size",
];

impl SettingsPatch {
    /// Shared strict decoder for every protocol adapter. Do not expose serde
    /// error text: a rejected unknown key/value might contain a pasted secret.
    pub fn from_json(value: Value) -> Result<Self> {
        let object = value.as_object().context("settings patch must be an object")?;
        anyhow::ensure!(
            object.iter().all(|(key, value)| KEYS.contains(&key.as_str()) && !value.is_null()),
            "settings patch contains unknown fields or null values"
        );
        // Validate the wire number before narrowing to ConfigFile's f32;
        // rounding must not turn a just-outside-range value into a valid one.
        if let Some(value) = object.get("line_spacing") {
            anyhow::ensure!(value.as_f64().is_some_and(|v| v.is_finite() && (0.8..=1.5).contains(&v)),
                "line_spacing must be between 0.8 and 1.5");
        }
        let patch: Self = serde_json::from_value(value)
            .map_err(|_| anyhow::anyhow!("settings patch contains an invalid field type"))?;
        patch.validate()?;
        Ok(patch)
    }

    pub fn validate(&self) -> Result<()> {
        for (value, allowed, name) in [
            (self.cursor_style.as_deref(), &["block", "bar", "underline"][..], "cursor_style"),
            (self.language.as_deref(), &["system", "en", "zh"][..], "language"),
            (self.theme_pref.as_deref(), &["system", "dark", "light"][..], "theme_pref"),
        ] {
            anyhow::ensure!(value.is_none_or(|value| allowed.contains(&value)),
                "invalid {name}");
        }
        anyhow::ensure!(
            self.line_spacing.is_none_or(|v| v.is_finite() && (0.8..=1.5).contains(&v)),
            "line_spacing must be between 0.8 and 1.5"
        );
        // Shared terminal bounds are 8..32. UI uses the same range, covering all
        // previous Flutter persisted values (10..28), not only its 11..22 picker.
        for (size, name) in [(self.font_size, "font_size"), (self.ui_font_size, "ui_font_size")] {
            anyhow::ensure!(size.is_none_or(|v| (8..=32).contains(&v)),
                "{name} must be an integer between 8 and 32");
        }
        for (value, limit, name) in [
            (self.font_family.as_deref(), 256, "font_family"),
            (self.ui_font_family.as_deref(), 256, "ui_font_family"),
            (self.download_dir.as_deref(), 4096, "download_dir"),
        ] {
            anyhow::ensure!(value.is_none_or(|v| v.len() <= limit && !v.chars().any(char::is_control)),
                "{name} is too long or contains control characters");
        }
        Ok(())
    }

    fn apply(self, candidate: &mut ConfigFile) {
        macro_rules! apply {
            ($field:ident, $stored:ident) => {
                if let Some(value) = self.$field {
                    candidate.$stored = value;
                    candidate.settings_explicit_fields.push(stringify!($field).into());
                }
            };
        }
        apply!(session_logs, session_logs);
        apply!(cursor_style, terminal_cursor_style);
        apply!(line_spacing, terminal_line_spacing);
        apply!(padding, terminal_padding);
        apply!(bold, terminal_bold);
        if let Some(follow) = self.sftp_follow_cd {
            candidate.sftp_no_follow_cd = !follow;
            candidate.settings_explicit_fields.push("sftp_follow_cd".into());
        }
        apply!(download_dir, download_dir);
        apply!(language, language);
        apply!(theme_pref, theme_pref);
        apply!(font_family, font_family);
        apply!(font_size, font_size);
        apply!(ui_font_family, ui_font_family);
        apply!(ui_font_size, ui_font_size);
        candidate.settings_explicit_fields.sort();
        candidate.settings_explicit_fields.dedup();
    }
}

/// Deliberately not ConfigFile: credentials, session data, automation policy
/// and unknown stored fields can never cross this projection.
#[derive(Debug, Clone, Serialize)]
pub struct SettingsSnapshot {
    pub session_logs: bool,
    pub cursor_style: String,
    pub line_spacing: f32,
    pub padding: bool,
    pub bold: bool,
    pub sftp_follow_cd: bool,
    pub download_dir: String,
    pub language: String,
    pub theme_pref: String,
    pub font_family: String,
    pub font_size: u32,
    pub ui_font_family: String,
    pub ui_font_size: u32,
    /// Opaque optimistic-concurrency token, not a profile path or credential.
    pub revision: String,
    /// Only choices written through this service are known explicit choices.
    /// Missing keys are unknown legacy/default provenance, NOT migration consent.
    pub explicit_fields: Vec<String>,
    /// Field names only: invalid legacy values were rendered using safe defaults.
    /// Reading never silently rewrites them or reports their potentially private values.
    pub invalid_legacy_fields: Vec<String>,
}

fn revision(saved: &SavedState) -> String {
    match saved.disk_fingerprint {
        Some(bytes) => bytes.iter().map(|byte| format!("{byte:02x}")).collect(),
        None => "uninitialized".into(),
    }
}

impl ConfigStore {
    /// Refresh from the selected profile so CLI/MCP commits become visible in
    /// an already-running GUI. Never discard local pending edits to do so.
    /// Like normal ConfigStore loads, the guarded read can recover a pending
    /// credential journal or initialize an empty profile's database schema.
    /// A previously uncertain store requires reopening/recovery, not a poll
    /// that silently dismisses its credential warning.
    pub fn settings_get(&mut self) -> Result<SettingsSnapshot> {
        let _ordered = Self::save_lock().lock().unwrap_or_else(|p| p.into_inner());
        let mut saved = self.saved_state.lock().unwrap_or_else(|p| p.into_inner()).clone();
        if saved.credentials_uncertain {
            return Err(SessionCredentialRollbackFailed.into());
        }
        anyhow::ensure!(Self::plan_save(&self.cache, &saved).is_empty(),
            "configuration has pending edits; save or reload them before refreshing settings");
        if saved.disk_fingerprint.is_some() && !self.path.exists() {
            return Err(ConfigurationChanged.into());
        }
        let io = profile_io::ProfileIoGuard::acquire(&self.path)?;
        let (cache, fingerprint) = Self::read_cache_snapshot_locked(&self.path, &self.key, &io)?;
        if fingerprint != saved.disk_fingerprint {
            // A queued old background snapshot must not undo a refreshed view.
            {
                let mut shared = self.saved_state.lock().unwrap_or_else(|p| p.into_inner());
                shared.submitted += 1;
                saved.submitted = shared.submitted;
                saved.attempted = shared.submitted;
            }
            Self::finish_snapshot(&mut saved, &cache, fingerprint);
            Self::publish_snapshot(&self.saved_state, saved.clone());
            self.cache = cache;
        }
        Ok(self.settings_snapshot(&saved))
    }

    fn settings_snapshot(&self, saved: &SavedState) -> SettingsSnapshot {
        let mut invalid = Vec::new();
        let mut choice = |raw: &str, options: &[&str], fallback: &str, name: &str| {
            if options.contains(&raw) {
                raw.to_owned()
            } else {
                if !raw.is_empty() {
                    invalid.push(name.to_owned());
                }
                fallback.to_owned()
            }
        };
        let language = choice(&self.cache.language, &["system", "en", "zh"], "system", "language");
        let theme_pref = choice(&self.cache.theme_pref, &["system", "dark", "light"], "system", "theme_pref");
        let cursor_style = choice(&self.cache.terminal_cursor_style, &["block", "bar", "underline"], "block", "cursor_style");
        let mut size = |raw: u32, fallback: u32, name: &str| {
            if (8..=32).contains(&raw) { raw } else {
                if raw != 0 { invalid.push(name.to_owned()); }
                fallback
            }
        };
        let font_size = size(self.cache.font_size, 13, "font_size");
        let ui_font_size = size(self.cache.ui_font_size, 14, "ui_font_size");
        let spacing = self.cache.terminal_line_spacing;
        let line_spacing = if spacing.is_finite() && (0.8..=1.5).contains(&spacing) {
            spacing
        } else {
            if spacing != 0.0 { invalid.push("line_spacing".into()); }
            1.0
        };
        SettingsSnapshot {
            session_logs: self.cache.session_logs,
            cursor_style, line_spacing,
            padding: self.cache.terminal_padding,
            bold: self.cache.terminal_bold,
            sftp_follow_cd: !self.cache.sftp_no_follow_cd,
            download_dir: self.cache.download_dir.clone(),
            language, theme_pref,
            font_family: self.cache.font_family.clone(),
            font_size,
            ui_font_family: self.cache.ui_font_family.clone(),
            ui_font_size,
            revision: revision(saved),
            explicit_fields: self.cache.settings_explicit_fields.iter()
                .filter(|key| KEYS.contains(&key.as_str())).cloned().collect(),
            invalid_legacy_fields: invalid,
        }
    }

    /// Validate all fields, persist a private candidate with the existing full
    /// transaction/recovery/OCC path, and publish only after the SQL commit.
    /// A failed update cannot leak into a later unrelated save.
    pub fn settings_update(
        &mut self,
        patch: SettingsPatch,
        expected_revision: &str,
    ) -> Result<SettingsSnapshot> {
        patch.validate()?;
        let _ordered = Self::save_lock().lock().unwrap_or_else(|p| p.into_inner());
        let mut saved = {
            let mut shared = self.saved_state.lock().unwrap_or_else(|p| p.into_inner());
            if revision(&shared) != expected_revision {
                return Err(ConfigurationChanged.into());
            }
            anyhow::ensure!(Self::plan_save(&self.cache, &shared).is_empty(),
                "configuration has pending edits; save or reload them before changing settings");
            shared.submitted += 1;
            let mut saved = shared.clone();
            saved.attempted = shared.submitted;
            saved
        };
        let mut candidate = self.cache.clone();
        patch.apply(&mut candidate);
        let result = Self::persist_snapshot(
            &candidate, &mut saved, None, self.key, &self.path,
            self.backup_dir.as_deref(), self.keyring_enabled,
        );
        if let Err(ref error) = result {
            Self::record_save_error(&mut saved, error);
        }
        Self::publish_snapshot(&self.saved_state, saved.clone());
        result?;
        self.cache = candidate;
        Ok(self.settings_snapshot(&saved))
    }
}

/// Overlay only the known ConfigFile representation on the existing raw object.
/// Unknown on-disk fields survive, but never become fields of an export or API.
pub(super) fn merge_settings_blob(previous: Option<&str>, settings: &ConfigFile) -> Result<String> {
    let mut object: Map<String, Value> = match previous {
        Some(raw) => serde_json::from_str::<Value>(raw)
            .ok().and_then(|v| v.as_object().cloned())
            .context("stored settings are not a valid object; original preserved")?,
        None => Map::new(),
    };
    let known = serde_json::to_value(settings)?;
    // This known field is intentionally omitted by serde for None. Preserve
    // unknown keys, not old values of known optional keys being cleared.
    if settings.mcp_access_mode.is_none() {
        object.remove("mcp_access_mode");
    }
    object.extend(known.as_object().context("settings must serialize as an object")?.clone());
    Ok(serde_json::to_string(&object)?)
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;
