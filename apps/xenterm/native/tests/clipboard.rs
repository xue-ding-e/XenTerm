//! Boundary checks only: no profile, native session, shell or clipboard.
use xenterm_bridge::xenterm_session_paste;

#[test]
fn clipboard_abi_rejects_invalid_inputs_without_creating_a_session() {
    let text = b"synthetic";
    assert_eq!(xenterm_session_paste(0, std::ptr::null(), 1, 0), 0);
    assert_eq!(xenterm_session_paste(0, text.as_ptr(), 0, 0), 0);
    assert_eq!(xenterm_session_paste(0, text.as_ptr(), 1, 2), 0);
    assert_eq!(xenterm_session_paste(0, text.as_ptr(), isize::MAX as usize + 1, 0), 0);
    assert_eq!(xenterm_session_paste(0, text.as_ptr(), text.len(), 0), 0);
    assert_eq!(xenterm_session_paste(u64::MAX, text.as_ptr(), text.len(), 1), 0);
}
