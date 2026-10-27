use super::*;
use serde_json::json;

fn fixture() -> (tempfile::TempDir, ConfigStore) {
    let directory = tempfile::tempdir().unwrap();
    let mut store = super::super::tests::temp_store();
    store.path = directory.path().join("sessions.db");
    store.save().unwrap();
    (directory, store)
}

fn disk(store: &ConfigStore) -> String {
    ConfigStore::open_existing_db(&store.path).unwrap()
        .query_row("SELECT value FROM meta WHERE key='settings'", [], |r| r.get(0)).unwrap()
}

fn update(store: &mut ConfigStore, value: Value) -> Result<SettingsSnapshot> {
    let revision = store.settings_get()?.revision;
    store.settings_update(SettingsPatch::from_json(value)?, &revision)
}

#[test]
fn strict_patch_rejects_unknown_secret_policy_null_and_wrong_types() {
    assert!(serde_json::from_value::<SettingsPatch>(json!({"font_size": null})).is_err());
    for value in [
        json!({"font_size": 7}), json!({"font_size": 33}), json!({"font_size": 14.5}),
        json!({"font_size": "14"}), json!({"font_size": null}), json!({"padding": 1}),
        json!({"theme_pref": "automatic"}), json!({"language": "unknown"}),
        json!({"line_spacing": 0.7}), json!({"line_spacing": 1.6}),
        json!({"line_spacing": 0.79999999999}), json!({"line_spacing": 1.50000000001}),
        json!({"font_family": "name\nline"}), json!({"mcp_enabled": true}),
        json!({"webdav_password": "must-not-be-returned"}), json!({"password": "private"}),
        json!({"unknown-private-key": "private"}), json!([]),
    ] {
        let error = SettingsPatch::from_json(value).unwrap_err().to_string();
        assert!(!error.contains("private"));
        assert!(!error.contains("must-not-be-returned"));
    }
    assert!(SettingsPatch { line_spacing: Some(f32::NAN), ..Default::default() }.validate().is_err());
    assert!(SettingsPatch { line_spacing: Some(f32::INFINITY), ..Default::default() }.validate().is_err());
}

#[test]
fn defaults_are_system_and_keep_terminal_ui_scopes_separate() {
    let (_directory, mut store) = fixture();
    let before = disk(&store);
    let snapshot = store.settings_get().unwrap();
    assert_eq!(snapshot.language, "system");
    assert_eq!(snapshot.theme_pref, "system");
    assert_eq!(snapshot.font_size, 13);
    assert_eq!(snapshot.ui_font_size, 14);
    assert!(snapshot.explicit_fields.is_empty());
    assert_eq!(disk(&store), before);
    let snapshot = update(&mut store, json!({"font_size": 32, "ui_font_size": 8})).unwrap();
    assert_eq!(snapshot.font_size, 32);
    assert_eq!(snapshot.ui_font_size, 8);
    assert_eq!(store.cache.panel_font, 0);
    assert_eq!(store.cache.ui_scale, 0);
}

#[test]
fn all_historical_flutter_ui_sizes_and_boundary_values_are_supported() {
    for spacing in [json!(1), json!(1.0)] {
        assert_eq!(SettingsPatch::from_json(json!({"line_spacing": spacing})).unwrap().line_spacing, Some(1.0));
    }
    for size in 8..=32 {
        assert!(SettingsPatch::from_json(json!({"ui_font_size": size, "font_size": size})).is_ok());
    }
    for size in [0, 7, 33, u32::MAX] {
        assert!(SettingsPatch::from_json(json!({"ui_font_size": size})).is_err());
    }
}

#[test]
fn invalid_field_rejects_entire_patch_before_live_cache_or_disk_mutation() {
    let (_directory, mut store) = fixture();
    let original = disk(&store);
    let revision = store.settings_get().unwrap().revision;
    let patch = SettingsPatch { session_logs: Some(true), font_size: Some(33), ..Default::default() };
    assert!(store.settings_update(patch, &revision).is_err());
    assert!(!store.cache.session_logs);
    assert_eq!(disk(&store), original);
}

#[test]
fn save_failure_keeps_cache_disk_and_revision_but_records_error() {
    let (_directory, mut store) = fixture();
    let before = disk(&store);
    let revision = store.settings_get().unwrap().revision;
    let conn = ConfigStore::open_existing_db(&store.path).unwrap();
    conn.execute_batch("CREATE TRIGGER deny_settings BEFORE UPDATE ON meta WHEN NEW.key='settings' BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END;").unwrap();
    let patch = SettingsPatch::from_json(json!({"session_logs": true, "font_size": 20})).unwrap();
    assert!(store.settings_update(patch, &revision).is_err());
    assert!(!store.cache.session_logs);
    assert_eq!(store.cache.font_size, 0);
    assert_eq!(disk(&store), before);
    assert_eq!(store.settings_get().unwrap().revision, revision);
    assert!(store.persistence_error().is_some());
    conn.execute_batch("DROP TRIGGER deny_settings").unwrap();
    // A later unrelated save cannot accidentally commit the failed choices.
    store.set_terminal_bold(true);
    store.save().unwrap();
    assert_eq!(serde_json::from_str::<Value>(&disk(&store)).unwrap()["font_size"], 0);
}

#[test]
fn unknown_disk_fields_survive_but_never_enter_safe_projection() {
    let (_directory, mut store) = fixture();
    let conn = ConfigStore::open_existing_db(&store.path).unwrap();
    let mut raw: Value = serde_json::from_str(&disk(&store)).unwrap();
    raw["future_private"] = json!({"opaque": "synthetic-secret"});
    conn.execute("UPDATE meta SET value=?1 WHERE key='settings'", [raw.to_string()]).unwrap();
    let snapshot = update(&mut store, json!({"theme_pref": "dark"})).unwrap();
    let stored: Value = serde_json::from_str(&disk(&store)).unwrap();
    assert_eq!(stored["future_private"], raw["future_private"]);
    let snapshot = serde_json::to_string(&snapshot).unwrap();
    assert!(!snapshot.contains("future_private"));
    assert!(!snapshot.contains("synthetic-secret"));
    // Unknown data remains outside ConfigFile, including any export using it.
    assert!(!serde_json::to_string(&store.cache).unwrap().contains("future_private"));
}

#[test]
fn settings_patch_preserves_sessions_history_and_other_configuration() {
    let (_directory, mut store) = fixture();
    let mut session = Session::new_empty();
    session.name = "synthetic fixture".into();
    store.upsert(session);
    store.cache.command_history = vec!["synthetic command".into()];
    store.cache.panel_font = 120;
    store.cache.ui_scale = 110;
    store.save().unwrap();
    let before = store.cache.clone();
    update(&mut store, json!({"ui_font_family": "Synthetic UI Face", "padding": true})).unwrap();
    assert_eq!(serde_json::to_string(&store.cache.sessions).unwrap(), serde_json::to_string(&before.sessions).unwrap());
    assert_eq!(store.cache.command_history, before.command_history);
    assert_eq!(store.cache.panel_font, 120);
    assert_eq!(store.cache.ui_scale, 110);
    assert_eq!(store.cache.mcp_enabled, before.mcp_enabled);
    assert_eq!(store.cache.webdav_password.as_str(), before.webdav_password.as_str());
}

#[test]
fn stale_process_cannot_overwrite_and_refresh_observes_committed_choices() {
    let (_directory, mut first) = fixture();
    let mut second = super::super::tests::temp_store();
    second.path = first.path.clone();
    let stale = second.settings_get().unwrap().revision;
    update(&mut first, json!({"font_size": 22})).unwrap();
    let unchanged = disk(&first);
    assert!(second.settings_update(SettingsPatch::from_json(json!({"theme_pref": "light"})).unwrap(), &stale).is_err());
    assert_eq!(disk(&first), unchanged);
    assert_eq!(second.cache.font_size, 0);
    let fresh = second.settings_get().unwrap();
    assert_eq!(fresh.font_size, 22);
    assert_ne!(fresh.revision, stale);
    let saved = second.settings_update(SettingsPatch::from_json(json!({"theme_pref": "light"})).unwrap(), &fresh.revision).unwrap();
    assert_eq!(saved.font_size, 22);
}

#[test]
fn stale_noop_is_not_confirmed_as_a_save() {
    let (_directory, mut store) = fixture();
    let old = store.settings_get().unwrap().revision;
    let conn = ConfigStore::open_existing_db(&store.path).unwrap();
    conn.execute("INSERT INTO meta VALUES('unrelated_newer_key','newer')", []).unwrap();
    assert!(store.settings_update(SettingsPatch::default(), &old).is_err());
}

#[test]
fn explicit_defaults_remain_distinct_from_omission_without_migration() {
    let (_directory, mut store) = fixture();
    update(&mut store, json!({})).unwrap();
    assert!(store.cache.settings_explicit_fields.is_empty());
    let snapshot = update(&mut store, json!({"font_family": "", "theme_pref": "system"})).unwrap();
    assert_eq!(snapshot.explicit_fields, vec!["font_family", "theme_pref"]);
    assert!(!snapshot.explicit_fields.contains(&"language".to_owned()));
}

#[test]
fn invalid_legacy_enum_is_reported_by_name_not_rewritten() {
    let (_directory, mut store) = fixture();
    store.cache.language = "synthetic-private-legacy-value".into();
    store.save().unwrap();
    let before = disk(&store);
    let snapshot = store.settings_get().unwrap();
    assert_eq!(snapshot.language, "system");
    assert_eq!(snapshot.invalid_legacy_fields, vec!["language"]);
    assert!(!serde_json::to_string(&snapshot).unwrap().contains("synthetic-private"));
    assert_eq!(disk(&store), before);
}

#[test]
fn refresh_and_update_never_discard_pending_local_edits() {
    let (_directory, mut store) = fixture();
    let before = disk(&store);
    let revision = store.settings_get().unwrap().revision;
    store.set_terminal_bold(true);
    assert!(store.settings_get().is_err());
    assert!(store.settings_update(SettingsPatch::default(), &revision).is_err());
    assert!(store.cache.terminal_bold);
    assert_eq!(disk(&store), before);
}

#[test]
fn malformed_existing_blob_is_not_replaced() {
    for bad in ["[]", "null", "not-json"] {
        assert!(merge_settings_blob(Some(bad), &ConfigFile::default()).is_err());
    }
    let result: Value = serde_json::from_str(&merge_settings_blob(
        Some(r#"{"mcp_access_mode":"full","future":true}"#),
        &ConfigFile::default(),
    ).unwrap()).unwrap();
    assert!(result.get("mcp_access_mode").is_none());
    assert_eq!(result["future"], true);
}

#[test]
fn deleted_previously_loaded_database_is_not_recreated_by_refresh() {
    let (_directory, mut store) = fixture();
    let previous = serde_json::to_string(&store.cache).unwrap();
    std::fs::remove_file(&store.path).unwrap();
    assert!(store.settings_get().is_err());
    assert!(!store.path.exists());
    assert_eq!(serde_json::to_string(&store.cache).unwrap(), previous);
}

#[test]
fn refresh_keeps_uncertain_credential_warning_until_explicit_reopen() {
    let (_directory, mut store) = fixture();
    {
        let mut saved = store.saved_state.lock().unwrap();
        saved.credentials_uncertain = true;
        saved.error = Some("synthetic unresolved recovery".into());
    }
    let before = disk(&store);
    assert!(store.settings_get().is_err());
    let saved = store.saved_state.lock().unwrap();
    assert!(saved.credentials_uncertain);
    assert_eq!(saved.error.as_deref(), Some("synthetic unresolved recovery"));
    assert_eq!(disk(&store), before);
}

#[test]
fn ordinary_refresh_never_adds_settings_keys_or_a_write_revision() {
    let (_directory, mut store) = fixture();
    let before = disk(&store);
    let before_fingerprint = ConfigStore::disk_fingerprint(&ConfigStore::open_existing_db(&store.path).unwrap()).unwrap();
    store.settings_get().unwrap();
    assert_eq!(disk(&store), before);
    assert_eq!(ConfigStore::disk_fingerprint(&ConfigStore::open_existing_db(&store.path).unwrap()).unwrap(), before_fingerprint);
}
