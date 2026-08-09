// Quick test: extract icons via the bridge's icons module
use timetrace_bridge::icons::extract_icon_rgba;

fn main() {
    let paths = [
        r"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.24.11911.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"D:\Microsoft VS Code\Code.exe",
        r"C:\Windows\explorer.exe",
    ];
    for p in paths {
        match extract_icon_rgba(p) {
            Some((w, h, data)) => println!("OK  {} -> {}x{} ({} bytes)", p.rsplit('\\').next().unwrap_or(p), w, h, data.len()),
            None => println!("NULL {}", p),
        }
    }
}
