//! Distribution profile admission, with process isolation for OnceLock state.
//! The default-location scenarios run on Linux with a synthetic XDG/HOME only.
use std::ffi::CStr;
use std::path::Path;
#[cfg(target_os = "linux")]
use std::process::Command;

#[test]
fn release_feature_identity_matches_the_build_mode() {
    assert_eq!(xenterm_bridge::xenterm_isolated_flutter_release(), cfg!(feature = "isolated-flutter-release"));
}

#[test]
fn release_profile_child() {
    let Ok(root) = std::env::var("XT_RELEASE_TEST_ROOT") else { return; };
    let root = Path::new(&root);
    let mode = std::env::var("XT_RELEASE_TEST_MODE").unwrap();
    let ptr = unsafe { xenterm_bridge::xenterm_sessions_json() };
    if mode == "invalid" {
        assert!(ptr.is_null(), "invalid explicit path must fail, not fall back");
        assert!(!root.join("xdg/xentermflutternext").exists());
        return;
    }
    assert!(!ptr.is_null());
    let text = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
    xenterm_bridge::xenterm_string_free(ptr);
    assert_eq!(text, "[]", "synthetic legacy data must not be imported");
    assert!(xenterm::config::has_explicit_data_dir());
    let expected = if mode == "explicit" {
        root.join("selected")
    } else {
        root.join("xdg/xentermflutternext")
    };
    assert_eq!(xenterm::config::data_dir(), expected.canonicalize().unwrap());
    assert!(expected.join("sessions.db").is_file());
    assert!(!expected.join("legacy-sentinel").exists());
}

#[cfg(target_os = "linux")]
fn run(root: &Path, mode: &str) {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.args(["--exact", "release_profile_child", "--nocapture"])
        .env("XT_RELEASE_TEST_ROOT", root)
        .env("XT_RELEASE_TEST_MODE", mode)
        .env("HOME", root.join("home"))
        .env("XDG_CONFIG_HOME", root.join("xdg"))
        .env_remove("MEATSHELL_DATA_DIR")
        .env_remove("XENTERM_DATA_DIR");
    if mode == "explicit" { command.env("XENTERM_DATA_DIR", root.join("selected")); }
    if mode == "invalid" { command.env("XENTERM_DATA_DIR", root.join("not-a-directory")); }
    let output = command.output().unwrap();
    assert!(output.status.success(), "{}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
}

#[cfg(target_os = "linux")]
#[test]
fn explicit_override_and_invalid_path_keep_their_semantics() {
    let root = std::env::temp_dir().join(format!("xt-release-explicit-{}", std::process::id()));
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("xdg/meatshell")).unwrap();
    std::fs::write(root.join("xdg/meatshell/legacy-sentinel"), b"synthetic unchanged").unwrap();
    std::fs::write(root.join("not-a-directory"), b"synthetic unchanged").unwrap();
    run(&root, "invalid");
    assert_eq!(std::fs::read(root.join("not-a-directory")).unwrap(), b"synthetic unchanged");
    run(&root, "explicit");
    run(&root, "explicit");
    assert!(!root.join("xdg/xentermflutternext").exists());
}

#[cfg(all(target_os = "linux", feature = "isolated-flutter-release"))]
#[test]
fn release_default_is_stable_reusable_and_does_not_import_legacy() {
    let root = std::env::temp_dir().join(format!("xt-release-default-{}", std::process::id()));
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("xdg/meatshell")).unwrap();
    std::fs::write(root.join("xdg/meatshell/legacy-sentinel"), b"synthetic unchanged").unwrap();
    run(&root, "default");
    let own = root.join("xdg/xentermflutternext");
    std::fs::write(own.join("keep-on-restart"), b"synthetic own data").unwrap();
    run(&root, "default");
    assert_eq!(std::fs::read(own.join("keep-on-restart")).unwrap(), b"synthetic own data");
    assert_eq!(std::fs::read(root.join("xdg/meatshell/legacy-sentinel")).unwrap(), b"synthetic unchanged");
}
