// vswhere wrapper shim — reports fake VS install for Flutter toolchain detection.
use std::process::{Command, Stdio};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Debug log
    std::fs::write("C:\\tools\\vswhere_calls.log", args.join(" ")).ok();
    let is_toolchain_query = args.iter().any(|a| a == "-requires" || a == "--requires");

    if is_toolchain_query {
        // CMake calls with -property installationPath expecting plain text
        if args.iter().any(|a| a == "-property") {
            println!("C:\\tools\\fake-vs");
            return;
        }
        let json = r#"[{
  "instanceId": "fake001",
  "installationPath": "C:\\tools\\fake-vs",
  "installationVersion": "16.11.38",
  "productId": "Microsoft.VisualStudio.Product.BuildTools",
  "displayName": "Visual Studio Build Tools 2019 (shim)",
  "description": "Build Tools for Visual Studio 2019",
  "isComplete": true,
  "isLaunchable": true,
  "isPrerelease": false,
  "isRebootRequired": false
}]"#;
        println!("{}", json);
        return;
    }

    // Delegate to the real vswhere (same dir as this exe)
    let exe_dir = std::env::current_exe().expect("exe path");
    let real = exe_dir.parent().unwrap().join("vswhere_real.exe");
    let status = Command::new(&real)
        .args(&args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();
    match status {
        Ok(s) => std::process::exit(s.code().unwrap_or(0)),
        Err(e) => {
            eprintln!("vswhere_real error: {}", e);
            std::process::exit(1);
        }
    }
}
