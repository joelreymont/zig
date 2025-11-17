// Simple test program for ARM64 backend
pub fn main() void {
    const a: i32 = 5;
    const b: i32 = 3;
    const c = add(a, b);
    _ = c;
}

fn add(x: i32, y: i32) i32 {
    return x + y;
}
