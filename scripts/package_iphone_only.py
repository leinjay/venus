"""Derive an unsigned iPhone-only IPA without extracting or changing iOS files.

Usage: python scripts/package_iphone_only.py full.ipa iphone-only.ipa
The result still requires signing. Removing Watch content does not certify any
particular AltServer version or prove the cause of an installer crash.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import zipfile


def is_watch(info):
    return bool(info.get("WKApplication") or info.get("WKWatchKitApp")
                or "WatchOS" in info.get("CFBundleSupportedPlatforms", []))


def package(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Source and destination must differ; preserve the full build.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".partial")
    with zipfile.ZipFile(source) as original:
        entries = original.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate entries.")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("IPA contains an invalid archive path.")
        roots = [name for name in names if len(PurePosixPath(name).parts) == 3
                 and name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if len(roots) != 1:
            raise ValueError("Expected exactly one top-level iPhone app.")
        main_plist = roots[0]
        app = main_plist.removesuffix("Info.plist")
        info = plistlib.loads(original.read(main_plist))
        if is_watch(info) or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
            raise ValueError("The top-level app is not an iPhone device build.")
        binary = app + info["CFBundleExecutable"]
        metal = app + "mlx-swift_Cmlx.bundle/default.metallib"
        if binary not in names or metal not in names:
            raise ValueError("The iPhone executable or MLX Metal resource is missing.")

        excluded = [app + "Watch/", "WatchKitSupport/", "WatchKitSupport2/", "__MACOS/"]
        # Also recognize watchOS bundles embedded in a nonstandard location.
        for name in names:
            if name.startswith(app) and name != main_plist and name.endswith("/Info.plist"):
                if is_watch(plistlib.loads(original.read(name))):
                    excluded.append(name.removesuffix("Info.plist"))

        def remove(name):
            return any(name.startswith(prefix) or name == prefix.rstrip("/") for prefix in excluded)

        kept = [entry for entry in entries if not remove(entry.filename)]
        with zipfile.ZipFile(temporary, "w") as output:
            for entry in kept:
                # Preserve executable permissions, symlink attributes and all iOS file bytes.
                output.writestr(entry, original.read(entry))
        with zipfile.ZipFile(temporary) as output:
            if set(output.namelist()) != {entry.filename for entry in kept}:
                raise ValueError("Output archive is incomplete.")
            for entry in kept:
                if output.read(entry.filename) != original.read(entry.filename):
                    raise ValueError("An iPhone file changed during repackaging.")
            if output.testzip() is not None:
                raise ValueError("Output archive CRC validation failed.")
    temporary.replace(destination)
    digest = hashlib.sha256()
    with destination.open("rb") as data:
        while chunk := data.read(1024 * 1024):
            digest.update(chunk)
    return {"output": str(destination.resolve()), "removed_entries": len(entries) - len(kept),
            "retained_entries": len(kept), "size": destination.stat().st_size,
            "sha256": digest.hexdigest(), "watch_content": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.source, args.destination), indent=2))
