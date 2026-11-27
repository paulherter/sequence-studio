use super::*;
use std::sync::mpsc::channel;

fn dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("sq-instance-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

#[test]
fn the_first_launch_is_primary_and_the_second_forwards_its_file() {
    let d = dir("two");
    let (tx, rx) = channel();
    let first = claim(&d, Some(Path::new("/a.sqproj")), tx).unwrap();
    assert!(matches!(first, Claim::Primary(_)));
    let (tx2, rx2) = channel();
    let second = claim(&d, Some(Path::new("/b/My Film.sqproj")), tx2).unwrap();
    assert!(matches!(second, Claim::Forwarded));
    assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), Some(PathBuf::from("/b/My Film.sqproj")));
    assert!(rx2.try_recv().is_err(), "the second launch kept nothing");
    // A launch without a file just raises the window.
    assert!(matches!(claim(&d, None, channel().0).unwrap(), Claim::Forwarded));
    assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), None);
}

#[test]
fn a_stale_claim_file_does_not_block_a_new_primary() {
    let d = dir("stale");
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join(CLAIM_FILE), "9 deadbeef").unwrap();
    assert!(matches!(claim(&d, None, channel().0).unwrap(), Claim::Primary(_)));
}

#[test]
fn a_request_with_the_wrong_token_is_ignored() {
    let d = dir("token");
    let (tx, rx) = channel();
    let _first = claim(&d, None, tx).unwrap();
    let port: u16 =
        std::fs::read_to_string(d.join(CLAIM_FILE)).unwrap().split_whitespace().next().unwrap().parse().unwrap();
    let mut s = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
    s.write_all(b"wrong\n/evil.sqproj\n").unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(400)).is_err());
}

#[test]
fn two_launches_at_the_same_moment_make_exactly_one_primary() {
    let d = dir("race");
    let results: Vec<_> = (0..6)
        .map(|i| {
            let d = d.clone();
            std::thread::spawn(move || {
                let (tx, rx) = channel();
                let c = claim(&d, Some(Path::new(&format!("/p{i}.sqproj"))), tx).unwrap();
                (c, rx)
            })
        })
        .collect::<Vec<_>>()
        .into_iter()
        .map(|h| h.join().unwrap())
        .collect();
    let primaries: Vec<_> = results.iter().filter(|(c, _)| matches!(c, Claim::Primary(_))).collect();
    assert_eq!(primaries.len(), 1, "exactly one primary");
    assert_eq!(results.iter().filter(|(c, _)| matches!(c, Claim::Forwarded)).count(), 5);
    let (_, rx) = primaries[0];
    assert_eq!(std::iter::from_fn(|| rx.recv_timeout(Duration::from_secs(2)).ok()).take(5).count(), 5);
}

/// Child side of the two-process tests: runs only when the parent named a folder.
#[test]
fn child_launch_for_the_process_tests() {
    let Some(dir) = std::env::var_os("SQ_INSTANCE_CHILD_DIR") else { return };
    let (tx, _rx) = channel();
    match claim(Path::new(&dir), Some(Path::new("/from-child.sqproj")), tx).unwrap() {
        Claim::Forwarded => sq_os::outln!("CHILD-FORWARDED"),
        Claim::Primary(_p) => {
            sq_os::outln!("CHILD-PRIMARY");
            std::thread::sleep(Duration::from_secs(60));
        }
    }
}

fn spawn_child(d: &Path) -> std::process::Child {
    std::process::Command::new(std::env::current_exe().unwrap())
        .args(["child_launch_for_the_process_tests", "--nocapture", "--test-threads=1"])
        .env("SQ_INSTANCE_CHILD_DIR", d)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn a_second_process_forwards_to_the_first_and_exits() {
    let d = dir("proc");
    let (tx, rx) = channel();
    let _first = claim(&d, None, tx).unwrap();
    let out = spawn_child(&d).wait_with_output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("CHILD-FORWARDED"));
    assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), Some(PathBuf::from("/from-child.sqproj")));
}

#[test]
fn a_killed_primary_leaves_no_stale_lock() {
    use std::io::Read;
    let d = dir("crash");
    let mut child = spawn_child(&d);
    // Wait until the child is primary (its claim file exists), then kill it without any cleanup.
    let t = std::time::Instant::now();
    while !d.join(CLAIM_FILE).exists() {
        assert!(t.elapsed() < Duration::from_secs(20), "child never became primary");
        std::thread::sleep(Duration::from_millis(50));
    }
    child.kill().unwrap();
    let mut out = String::new();
    child.stdout.take().unwrap().read_to_string(&mut out).unwrap();
    child.wait().unwrap();
    assert!(d.join(CLAIM_FILE).exists(), "the claim file is left behind");
    assert!(matches!(claim(&d, None, channel().0).unwrap(), Claim::Primary(_)));
}
