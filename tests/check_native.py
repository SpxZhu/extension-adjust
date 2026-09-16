"""Compile Android bridge locally against real SDKs; never uploads sources."""
import argparse
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--javac", required=True, type=Path)
    parser.add_argument("--android-jar", required=True, type=Path)
    parser.add_argument("--adjust-aar", required=True, type=Path)
    parser.add_argument("--ndk", required=True, type=Path)
    parser.add_argument("--defold-sdk", required=True, type=Path,
                        help="Unpacked defoldsdk directory, containing sdk/include")
    args = parser.parse_args()
    out = ROOT / ".work" / "native-check"
    out.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.adjust_aar) as archive:
        (out / "adjust.jar").write_bytes(archive.read("classes.jar"))
    import os
    classpath = os.pathsep.join(map(str, [args.android_jar.resolve(), out / "adjust.jar"]))
    subprocess.run([str(args.javac), "--release", "8", "-Xlint:-options", "-cp", classpath,
                    "-d", str(out / "classes"),
                    str(ROOT / "extension-adjust/src/java/com/defold/adjust/AdjustPlugin.java")], check=True)
    host = {"win32": "windows-x86_64", "darwin": "darwin-x86_64"}.get(sys.platform, "linux-x86_64")
    clang = args.ndk / "toolchains/llvm/prebuilt" / host / "bin" / ("clang++.exe" if sys.platform == "win32" else "clang++")
    for abi, target in [("arm64", "aarch64-linux-android24"), ("armv7", "armv7a-linux-androideabi24")]:
        for name in ["adjust.cpp", "adjust_android.cpp"]:
            subprocess.run([str(clang), "--target=" + target, "-std=c++11", "-Wall", "-Wextra", "-Werror",
                            "-DDM_PLATFORM_ANDROID", "-DANDROID",
                            "-I", str(args.defold_sdk / "include"),
                            "-I", str(args.defold_sdk / "sdk/include"),
                            "-I", str(args.ndk / "sources/android/native_app_glue"),
                            "-c", str(ROOT / "extension-adjust/src" / name),
                            "-o", str(out / (abi + "-" + name + ".o"))], check=True)
    print("PASS Android Java + arm64/armv7 C++ object compilation (not a full link/package test)")


if __name__ == "__main__":
    main()
