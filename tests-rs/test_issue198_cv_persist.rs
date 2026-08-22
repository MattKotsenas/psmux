// Tests for issue #198 (comment 4281810240): C-v still intercepted after unbind
//
// The reporter confirmed on psmux 3.3.3 that Ctrl+V is STILL intercepted
// even after running unbind-key -n C-v. These tests prove WHY:
//
// 1. ROOT_DEFAULTS has NO C-v binding, so unbind-key -n C-v removes nothing
// 2. PREFIX_DEFAULTS has 'v' (plain v, rectangle-toggle), NOT 'C-v'
// 3. unbind-key C-v targets Ctrl+V in prefix table, but the only 'v' there is plain
// 4. The actual Ctrl+V interception is hardcoded in client.rs Windows paste detection
//
// These unit tests prove the key_tables layer works correctly (the fix from
// commits 5ef0f01 and cb0d429 is correct), but the problem is ABOVE key_tables
// in the client event loop.

use super::*;

fn mock_app() -> AppState {
    AppState::new("test_session".to_string())
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 1: ROOT_DEFAULTS does not contain C-v
// ═══════════════════════════════════════════════════════════════════

#[test]
fn root_defaults_has_no_ctrl_v() {
    // The user runs "unbind-key -n C-v" expecting it to stop Ctrl+V interception.
    // But ROOT_DEFAULTS only has PageUp. There is nothing to unbind.
    for (key_str, _cmd) in crate::help::ROOT_DEFAULTS {
        assert_ne!(
            *key_str, "C-v",
            "ROOT_DEFAULTS should NOT contain C-v (it only has PageUp)"
        );
    }
}

#[test]
fn unbind_key_n_cv_is_noop_on_fresh_state() {
    // Populate defaults, then unbind-key -n C-v.
    // Since root table has no C-v, nothing changes.
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    let root_before = app.key_tables.get("root").map(|v| v.len()).unwrap_or(0);

    parse_unbind_key(&mut app, "unbind-key -n C-v");

    let root_after = app.key_tables.get("root").map(|v| v.len()).unwrap_or(0);
    assert_eq!(
        root_before, root_after,
        "unbind-key -n C-v should not change root table size (was {}, now {})",
        root_before, root_after
    );
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 2: PREFIX_DEFAULTS has 'v' (plain), NOT 'C-v' (Ctrl+V)
// ═══════════════════════════════════════════════════════════════════

#[test]
fn prefix_defaults_has_plain_v_not_ctrl_v() {
    // PREFIX_DEFAULTS has ("v", "rectangle-toggle") which is plain 'v',
    // not Ctrl+V. These are entirely different keys.
    let has_plain_v = crate::help::PREFIX_DEFAULTS.iter().any(|(k, _)| *k == "v");
    let has_ctrl_v = crate::help::PREFIX_DEFAULTS.iter().any(|(k, _)| *k == "C-v");

    assert!(has_plain_v, "PREFIX_DEFAULTS should have plain 'v' (rectangle-toggle)");
    assert!(!has_ctrl_v, "PREFIX_DEFAULTS should NOT have 'C-v'");
}

#[test]
fn unbind_key_cv_does_not_remove_plain_v() {
    // unbind-key C-v targets KeyCode::Char('v') + CONTROL modifier.
    // The prefix table has KeyCode::Char('v') WITHOUT CONTROL (plain v).
    // These should be treated as different keys.
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    let prefix = app.key_tables.get("prefix").unwrap();
    let has_plain_v_before = prefix.iter().any(|b| {
        matches!(b.key.0, KeyCode::Char('v')) && !b.key.1.contains(KeyModifiers::CONTROL)
    });
    assert!(has_plain_v_before, "Prefix should have plain 'v' before unbind");

    // unbind-key C-v (Ctrl+V, not plain v)
    parse_unbind_key(&mut app, "unbind-key C-v");

    let prefix = app.key_tables.get("prefix").unwrap();
    let has_plain_v_after = prefix.iter().any(|b| {
        matches!(b.key.0, KeyCode::Char('v')) && !b.key.1.contains(KeyModifiers::CONTROL)
    });

    // Plain 'v' should STILL be present (C-v and v are different keys)
    // NOTE: If this test fails, it means parse_unbind_key conflates C-v with v,
    // which would be a DIFFERENT bug.
    assert!(
        has_plain_v_after,
        "Plain 'v' (rectangle-toggle) should survive unbind-key C-v. \
         C-v (Ctrl+V) and v (plain) are different keys."
    );
}

#[test]
fn unbind_key_plain_v_removes_rectangle_toggle() {
    // unbind-key v (plain v) SHOULD remove rectangle-toggle from prefix.
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    parse_unbind_key(&mut app, "unbind-key v");

    let prefix = app.key_tables.get("prefix").unwrap();
    let has_plain_v = prefix.iter().any(|b| {
        matches!(b.key.0, KeyCode::Char('v')) && !b.key.1.contains(KeyModifiers::CONTROL)
    });
    assert!(
        !has_plain_v,
        "Plain 'v' (rectangle-toggle) should be removed by unbind-key v"
    );
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 3: Even after unbinding ALL tables, key_tables has no C-v to remove
// ═══════════════════════════════════════════════════════════════════

#[test]
fn exhaustive_unbind_still_leaves_hardcoded_cv_path() {
    // This test proves that even if the user does EVERYTHING possible with
    // unbind-key, there is NO C-v entry in any key table to remove.
    // The Ctrl+V interception is entirely outside of key_tables.
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    // Unbind C-v from every possible table
    parse_unbind_key(&mut app, "unbind-key C-v");        // prefix
    parse_unbind_key(&mut app, "unbind-key -n C-v");      // root
    parse_unbind_key(&mut app, "unbind-key -T prefix C-v"); // explicit prefix
    parse_unbind_key(&mut app, "unbind-key -T root C-v");   // explicit root

    // Now verify: was there EVER a C-v in ANY table?
    // Answer: No. The only 'v' in key_tables is plain 'v' (no CONTROL).
    let ctrl_v_found_anywhere = app.key_tables.iter().any(|(_, binds)| {
        binds.iter().any(|b| {
            matches!(b.key.0, KeyCode::Char('v')) && b.key.1.contains(KeyModifiers::CONTROL)
        })
    });

    // This assertion PASSES because there was never a C-v to begin with.
    // The Ctrl+V interception lives in client.rs, not key_tables.
    assert!(
        !ctrl_v_found_anywhere,
        "No Ctrl+V binding should exist in any key table (it was never there)"
    );
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 4: Adding a custom C-v binding then unbinding it works fine
// (proves unbind-key mechanism is correct, just nothing to unbind by default)
// ═══════════════════════════════════════════════════════════════════

#[test]
fn bind_then_unbind_ctrl_v_works() {
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    // User explicitly adds a C-v binding to root table
    parse_bind_key(&mut app, "bind-key -n C-v send-keys custom-action");

    let root = app.key_tables.get("root").unwrap();
    let has_cv = root.iter().any(|b| {
        matches!(b.key.0, KeyCode::Char('v')) && b.key.1.contains(KeyModifiers::CONTROL)
    });
    assert!(has_cv, "C-v should be in root table after explicit bind");

    // Now unbind it
    parse_unbind_key(&mut app, "unbind-key -n C-v");

    let root = app.key_tables.get("root").unwrap();
    let has_cv_after = root.iter().any(|b| {
        matches!(b.key.0, KeyCode::Char('v')) && b.key.1.contains(KeyModifiers::CONTROL)
    });
    assert!(
        !has_cv_after,
        "C-v should be removed from root table after unbind-key -n C-v"
    );
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 5: Config file unbind scenario from real user
// ═══════════════════════════════════════════════════════════════════

#[test]
fn config_unbind_cv_scenario_from_reporter() {
    // The reporter tried these in their config:
    //   unbind-key -a C-v    (this clears ALL prefix bindings! probably not intended)
    //   unbind-key -n C-v    (this targets root table, which has no C-v)
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    let prefix_count_before = app.key_tables.get("prefix").map(|v| v.len()).unwrap_or(0);
    assert!(prefix_count_before > 0, "precondition: default prefix bindings exist");

    // "unbind-key -a C-v" is parsed as "unbind all" (the -a flag), ignoring C-v
    // This would CLEAR the entire prefix table, not unbind just C-v!
    parse_unbind_key(&mut app, "unbind-key -a C-v");

    // After -a, prefix table should be empty (the -a flag clears all)
    let prefix_count_after = app.key_tables.get("prefix").map(|v| v.len()).unwrap_or(0);
    assert_eq!(
        prefix_count_after, 0,
        "unbind-key -a clears ALL prefix bindings (got {} remaining). \
         The -a flag means 'all keys', not 'all tables'. \
         The user likely meant unbind-key C-v (without -a).",
        prefix_count_after
    );
    assert!(
        app.defaults_suppressed,
        "defaults_suppressed should be true after unbind-key -a"
    );
}

#[test]
fn config_correct_unbind_cv_syntax() {
    // The CORRECT way to unbind Ctrl+V from the prefix table:
    //   unbind-key C-v
    // And from the root table:
    //   unbind-key -n C-v
    // But NEITHER has any effect because there is no C-v binding in any table.
    let mut app = mock_app();
    populate_default_bindings(&mut app);

    let total_before: usize = app.key_tables.values().map(|v| v.len()).sum();

    parse_config_content(&mut app, "unbind-key C-v\nunbind-key -n C-v\n");

    let total_after: usize = app.key_tables.values().map(|v| v.len()).sum();

    // The binding counts should be IDENTICAL because there was nothing to remove.
    assert_eq!(
        total_before, total_after,
        "Unbinding C-v should change nothing (no C-v exists in any default table). \
         Before: {}, After: {}",
        total_before, total_after
    );
}

// ═══════════════════════════════════════════════════════════════════
// PROOF 6: parse_key_name correctly distinguishes 'v' from 'C-v'
// ═══════════════════════════════════════════════════════════════════

#[test]
fn parse_key_name_distinguishes_v_from_ctrl_v() {
    // Verify the key parser treats "v" and "C-v" as different keys
    let plain_v = parse_key_name("v");
    let ctrl_v = parse_key_name("C-v");

    assert!(plain_v.is_some(), "parse_key_name should parse 'v'");
    assert!(ctrl_v.is_some(), "parse_key_name should parse 'C-v'");

    let (v_code, v_mods) = plain_v.unwrap();
    let (cv_code, cv_mods) = ctrl_v.unwrap();

    assert!(matches!(v_code, KeyCode::Char('v')), "plain v should parse to Char('v')");
    assert!(matches!(cv_code, KeyCode::Char('v')), "C-v should parse to Char('v')");
    assert!(!v_mods.contains(KeyModifiers::CONTROL), "plain v should have no CONTROL modifier");
    assert!(cv_mods.contains(KeyModifiers::CONTROL), "C-v should have CONTROL modifier");

    // After normalization, they should still be different
    let norm_v = normalize_key_for_binding((v_code, v_mods));
    let norm_cv = normalize_key_for_binding((cv_code, cv_mods));
    assert_ne!(
        norm_v, norm_cv,
        "Normalized 'v' and 'C-v' should be different keys"
    );
}
