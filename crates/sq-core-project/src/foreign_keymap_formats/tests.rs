// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ForeignKeymapPremiereResolveTests.swift. Fixtures are SYNTHETIC, built from the documented structure of both
// formats: they pin our reading, not the apps' files.

use super::*;
use crate::foreign_keymap::{ForeignKeymap, Reason};

fn kys(items: &[(u32, &[&str], &str)]) -> Vec<u8> {
    let mut s = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\"><shortcuts Version=\"5\"><context.global>\n",
    );
    for (i, (key, mods, cmd)) in items.iter().enumerate() {
        s += &format!("<item.{i}><virtualkey>{key}</virtualkey>");
        for m in *mods {
            s += &format!("<modifier.{m}>true</modifier.{m}>");
        }
        s += &format!("<commandname>{cmd}</commandname></item.{i}>\n");
    }
    s += "</context.global></shortcuts></PremiereData>\n";
    s.into_bytes()
}

fn ascii(c: char) -> u32 {
    0x8000_0000 | u32::from(c)
}

fn chord(key: ForeignKey, m: ForeignModifiers) -> ForeignChord {
    ForeignChord::new(key, m)
}

fn plain(key: ForeignKey) -> ForeignChord {
    chord(key, ForeignModifiers::EMPTY)
}

fn chords_of(cmds: &[ForeignCommand], id: &str) -> Vec<ForeignChord> {
    cmds.iter().find(|c| c.source_id == id).map(|c| c.chords.clone()).unwrap_or_default()
}

const PRESET: &str = "editBlade :=
controlPlayToggle := Space
controlPlayReverse := J
editUndo := Ctrl+Z
editRedo := Ctrl+Shift+Z
editDelete := Alt+Backspace | Shift+Del
controlGotoStart := Home
controlClipPrev := PgUp
viewZoomSubZoomIn := =
controlKeyframeNext := Alt+'
editNudgeTrimStepTrimMultiFrameRight := Shift+. | Ctrl+Shift+Right
sessionPrinterLightsBlueMinus := Num+6
markNumPlus := Ctrl+Num++
viewPlus := Ctrl++
controlFastForward := F9
markStrange := Hyper+Q
";

#[test]
fn premiere_reads_keys_modifiers_and_commands() {
    let data = kys(&[
        (ascii('G'), &[], "cmd.tools.10hand"),
        (ascii('K'), &["ctrl"], "cmd.edit.keyboardshortcuts"),
        (ascii('Z'), &["ctrl", "shift"], "cmd.edit.redo"),
        (ascii('['), &["alt"], "cmd.tlnav.trim.in.to.cti"),
        (11, &[], "cmd.transport.toggleplay"),
        (ascii(' '), &[], "cmd.monitor.playstoptoggle"),
        (ascii('\u{7F}'), &[], "cmd.edit.clear"),
    ]);
    let cmds = PremiereKysReader::read(&data).unwrap();
    assert_eq!(chords_of(&cmds, "cmd.tools.10hand"), [plain(ForeignKey::Char('g'))], "letters are lowercase");
    assert_eq!(
        chords_of(&cmds, "cmd.edit.keyboardshortcuts"),
        [chord(ForeignKey::Char('k'), ForeignModifiers::COMMAND)]
    );
    assert_eq!(
        chords_of(&cmds, "cmd.edit.redo"),
        [chord(ForeignKey::Char('z'), ForeignModifiers::COMMAND | ForeignModifiers::SHIFT)]
    );
    assert_eq!(chords_of(&cmds, "cmd.tlnav.trim.in.to.cti"), [chord(ForeignKey::Char('['), ForeignModifiers::OPTION)]);
    assert_eq!(chords_of(&cmds, "cmd.transport.toggleplay"), [plain(ForeignKey::Function(5))]);
    assert_eq!(chords_of(&cmds, "cmd.monitor.playstoptoggle"), [plain(ForeignKey::Space)]);
    assert_eq!(chords_of(&cmds, "cmd.edit.clear"), [plain(ForeignKey::ForwardDelete)]);
    let names: Vec<&str> = cmds.iter().map(|c| c.source_id.as_str()).collect();
    assert!(names.windows(2).all(|w| w[0] <= w[1]), "sorted by command name");
}

#[test]
fn premiere_merges_contexts_and_skips_unknown_keys() {
    let xml = r#"<PremiereData Version="3"><shortcuts Version="5">
    <context.global><item.0><virtualkey>2147483723</virtualkey><commandname>cmd.transport.stop</commandname></item.0></context.global>
    <context.timeline>
      <item.0><virtualkey>2147483723</virtualkey><commandname>cmd.transport.stop</commandname></item.0>
      <item.1><virtualkey>2147483724</virtualkey><commandname>cmd.transport.stop</commandname></item.1>
      <item.2><virtualkey>9999</virtualkey><commandname>cmd.edit.cut</commandname></item.2>
      <item.3><commandname>cmd.edit.copy</commandname></item.3>
    </context.timeline></shortcuts></PremiereData>"#;
    let cmds = PremiereKysReader::read(xml.as_bytes()).unwrap();
    assert_eq!(
        chords_of(&cmds, "cmd.transport.stop"),
        [plain(ForeignKey::Char('k')), plain(ForeignKey::Char('l'))],
        "same chord in two contexts counts once"
    );
    let cut = cmds.iter().find(|c| c.source_id == "cmd.edit.cut");
    assert!(cut.is_some_and(|c| c.chords.is_empty() && c.unreadable == ["key code 9999"]));
    assert!(chords_of(&cmds, "cmd.edit.copy").is_empty(), "no key: unassigned");
}

#[test]
fn premiere_rejects_other_files() {
    assert_eq!(PremiereKysReader::read(b"hello"), Err(PremiereReadError::NotAKeyboardLayout));
    assert_eq!(PremiereKysReader::read(b"<a><b/></a>"), Err(PremiereReadError::NotAKeyboardLayout));
}

#[test]
fn resolve_reads_chords_and_alternatives() {
    let cmds = ResolveKeymapReader::read(PRESET.as_bytes()).unwrap();
    let c = |id: &str| chords_of(&cmds, id);
    let (cmd, shift, option) = (ForeignModifiers::COMMAND, ForeignModifiers::SHIFT, ForeignModifiers::OPTION);
    assert_eq!(c("controlPlayToggle"), [plain(ForeignKey::Space)]);
    assert_eq!(c("controlPlayReverse"), [plain(ForeignKey::Char('j'))]);
    assert_eq!(c("editUndo"), [chord(ForeignKey::Char('z'), cmd)], "Ctrl is Command on a Mac");
    assert_eq!(c("editRedo"), [chord(ForeignKey::Char('z'), cmd | shift)]);
    assert_eq!(c("editDelete"), [chord(ForeignKey::Backspace, option), chord(ForeignKey::ForwardDelete, shift)]);
    assert_eq!(c("controlGotoStart"), [plain(ForeignKey::Home)]);
    assert_eq!(c("controlClipPrev"), [plain(ForeignKey::PageUp)]);
    assert_eq!(c("viewZoomSubZoomIn"), [plain(ForeignKey::Char('='))]);
    assert_eq!(c("controlKeyframeNext"), [chord(ForeignKey::Char('\''), option)]);
    assert_eq!(
        c("editNudgeTrimStepTrimMultiFrameRight"),
        [chord(ForeignKey::Char('.'), shift), chord(ForeignKey::Right, cmd | shift)]
    );
    assert_eq!(c("sessionPrinterLightsBlueMinus"), [plain(ForeignKey::Char('6'))], "keypad twin is the same chord");
    assert_eq!(c("markNumPlus"), [chord(ForeignKey::Char('+'), cmd)]);
    assert_eq!(c("viewPlus"), [chord(ForeignKey::Char('+'), cmd)]);
    assert_eq!(c("controlFastForward"), [plain(ForeignKey::Function(9))]);
    assert!(c("editBlade").is_empty());
    let strange = cmds.iter().find(|c| c.source_id == "markStrange");
    assert!(strange.is_some_and(|c| c.chords.is_empty() && c.unreadable == ["Hyper+Q"]));
}

#[test]
fn resolve_rejects_other_files() {
    assert_eq!(ResolveKeymapReader::read(b"hello\nworld"), Err(ResolveReadError::NotAKeyboardLayout));
    assert_eq!(ResolveKeymapReader::read(&[0xFF, 0x00, 0x13]), Err(ResolveReadError::NotAKeyboardLayout));
}

#[test]
fn resolve_repeated_id_adds_to_the_first() {
    let cmds = ResolveKeymapReader::read(b"a := J\nb := K\na := L | J | Hyper+Q\n").unwrap();
    assert_eq!(cmds.len(), 2);
    assert_eq!(cmds[0].chords, [plain(ForeignKey::Char('j')), plain(ForeignKey::Char('l'))]);
    assert_eq!(cmds[0].unreadable, ["Hyper+Q"]);
}

#[test]
fn detection_picks_the_format() {
    let kys_data = kys(&[(ascii('G'), &[], "cmd.tools.10hand")]);
    assert_eq!(ForeignKeymapFile::read(&kys_data, None).map(|c| c.format), Ok(ForeignKeymapFormat::Premiere));
    assert_eq!(ForeignKeymapFile::read(PRESET.as_bytes(), None).map(|c| c.format), Ok(ForeignKeymapFormat::Resolve));
    let cut = PlistValue::Dict(BTreeMap::from([(
        "Cut".to_string(),
        PlistValue::Dict(BTreeMap::from([
            ("characterString".to_string(), PlistValue::String("x".into())),
            ("modifiers".to_string(), PlistValue::String("command".into())),
        ])),
    )]));
    assert_eq!(ForeignKeymapFile::read(b"bplist", Some(&cut)).map(|c| c.format), Ok(ForeignKeymapFormat::FinalCut));
    assert_eq!(ForeignKeymapFile::read(b"nothing here", None), Err(ForeignKeymapFileError::UnknownFormat));
}

#[test]
fn tables_map_and_report_unmapped() {
    let cmds = PremiereKysReader::read(&kys(&[
        (ascii('C'), &[], "cmd.tools.06razor"),
        (ascii('Q'), &["ctrl"], "cmd.file.quit"),
        (ascii('X'), &[], "cmd.not.in.our.table"),
    ]))
    .unwrap();
    let p = ForeignKeymap::translate(&cmds, &ForeignKeymapFormat::Premiere.table());
    assert_eq!(p.mapped.iter().map(|b| b.command_id.as_str()).collect::<Vec<_>>(), ["tool.razor"]);
    let reason = |id: &str| p.unmapped.iter().find(|u| u.source_id == id).map(|u| u.reason);
    assert_eq!(reason("cmd.file.quit"), Some(Reason::System));
    assert_eq!(reason("cmd.not.in.our.table"), Some(Reason::NoEquivalent));

    let r = ForeignKeymap::translate(
        &ResolveKeymapReader::read(PRESET.as_bytes()).unwrap(),
        &ForeignKeymapFormat::Resolve.table(),
    );
    let mapped = |id: &str| r.mapped.iter().find(|b| b.source_id == id).map(|b| b.command_id.clone());
    assert_eq!(mapped("controlPlayToggle").as_deref(), Some("playPause"));
    assert_eq!(mapped("editUndo").as_deref(), Some("undo"));
    assert!(r.unmapped.iter().any(|u| u.source_id == "markStrange"), "an unreadable key is still reported");
    assert_eq!(r.unassigned, 1, "editBlade has no key");
}
