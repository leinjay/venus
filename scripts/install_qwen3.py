"""Download the pinned iPhone MLX model; verify files without installing a server.

Usage: python scripts/install_qwen3.py [destination]
The downloaded directory can also be imported into the iPhone app via Files.
"""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

MODEL = "mlx-community/Qwen3-1.7B-4bit"
REVISION = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"


def hashes(path):
    sha256 = hashlib.sha256()
    git_blob = hashlib.sha1(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as source:
        while chunk := source.read(4 * 1024 * 1024):
            sha256.update(chunk)
            git_blob.update(chunk)
    return sha256.hexdigest(), git_blob.hexdigest()


def install(destination):
    destination.mkdir(parents=True, exist_ok=True)
    metadata = json.load(urllib.request.urlopen(
        f"https://huggingface.co/api/models/{MODEL}/revision/{REVISION}?blobs=true", timeout=60))
    manifest = []
    for entry in metadata["siblings"]:
        name = entry["rfilename"]
        if not name.endswith((".json", ".txt", ".safetensors")):
            continue
        target = destination / name
        expected = entry.get("lfs", {}).get("sha256")
        valid = target.is_file() and target.stat().st_size == entry["size"]
        if valid:
            sha256, blob = hashes(target)
            valid = sha256 == expected if expected else blob == entry["blobId"]
        if not valid:
            print(f"Downloading {name} ({entry['size']:,} bytes)", flush=True)
            temporary = target.with_suffix(target.suffix + ".partial")
            request = urllib.request.Request(f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}")
            with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                while chunk := response.read(4 * 1024 * 1024):
                    output.write(chunk)
            sha256, blob = hashes(temporary)
            matches = sha256 == expected if expected else blob == entry["blobId"]
            if temporary.stat().st_size != entry["size"] or not matches:
                raise RuntimeError(f"Verification failed: {name}")
            temporary.replace(target)
        manifest.append({"name": name, "size": entry["size"], "sha256": sha256})
        print(f"Verified {name}", flush=True)
    (destination / "venus-model.json").write_text(json.dumps(
        {"model": MODEL, "revision": REVISION, "files": manifest}, indent=2), encoding="utf-8")
    print(f"Ready: {destination.resolve()}\nMLX inference requires an Apple device; Windows stores the verified weights only.")


if __name__ == "__main__":
    install(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".models/Qwen3-1.7B-4bit"))
