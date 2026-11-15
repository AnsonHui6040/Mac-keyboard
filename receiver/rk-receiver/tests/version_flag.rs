//! Both shipped binaries report the package version, and the installer script and the CI checks depend on that exact text.

use std::process::Command;

const EXPECTED_VERSION: &str = "0.2.0-alpha.1";

fn stdout_of(exe: &str) -> String {
    let output = Command::new(exe).arg("--version").output().expect("binary runs");
    assert!(output.status.success(), "{exe} --version failed: {:?}", output.status);
    String::from_utf8(output.stdout).expect("utf-8 output")
}

#[test]
fn version_flag_prints_the_package_version() {
    assert_eq!(env!("CARGO_PKG_VERSION"), EXPECTED_VERSION);
    assert_eq!(stdout_of(env!("CARGO_BIN_EXE_rk-receiver")).trim_end(), format!("rk-receiver {}", env!("CARGO_PKG_VERSION")));
    assert_eq!(stdout_of(env!("CARGO_BIN_EXE_rk-diag")).trim_end(), format!("rk-diag {}", env!("CARGO_PKG_VERSION")));
}
