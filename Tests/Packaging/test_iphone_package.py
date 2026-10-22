import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("packager", Path(__file__).resolve().parents[2] / "scripts/package_iphone_only.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class IPhonePackageTests(unittest.TestCase):
    def fixture(self, path, nested_watch=False, platform="iPhoneOS"):
        app = "Payload/VenusTools.app/"
        files = {
            app + "Info.plist": plistlib.dumps({"CFBundleExecutable": "VenusTools", "CFBundleSupportedPlatforms": [platform]}),
            app + "VenusTools": b"iPhone executable",
            app + "mlx-swift_Cmlx.bundle/default.metallib": b"Metal resource",
            app + "PlugIns/Useful.appex/Info.plist": plistlib.dumps({"CFBundleSupportedPlatforms": ["iPhoneOS"]}),
            app + "Watch/VenusToolsWatch.app/Info.plist": plistlib.dumps({"WKApplication": True, "CFBundleSupportedPlatforms": ["WatchOS"]}),
            app + "Watch/VenusToolsWatch.app/VenusToolsWatch": b"Watch executable",
            "WatchKitSupport2/WK": b"Watch support",
            "__MACOSX/Payload/._VenusTools.app": b"Finder metadata",
        }
        if nested_watch:
            files[app + "PlugIns/OtherWatch.app/Info.plist"] = plistlib.dumps({"WKWatchKitApp": True})
            files[app + "PlugIns/OtherWatch.app/Executable"] = b"another Watch executable"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in files.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = 0o100755 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, data)

    def test_watch_removed_while_phone_extensions_bytes_and_permissions_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "full.ipa"
            destination = Path(directory) / "phone.ipa"
            self.fixture(source, nested_watch=True)
            result = packager.package(source, destination)
            self.assertEqual(result["removed_entries"], 6)
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination) as output:
                self.assertEqual(len(original.namelist()), 10)
                self.assertEqual(len(output.namelist()), 4)
                for entry in output.infolist():
                    self.assertEqual(output.read(entry), original.read(entry.filename))
                    self.assertEqual(entry.external_attr, original.getinfo(entry.filename).external_attr)
                self.assertIn("Payload/VenusTools.app/PlugIns/Useful.appex/Info.plist", output.namelist())

    def test_refuses_overwriting_the_complete_source(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "full.ipa"
            self.fixture(source)
            original = source.read_bytes()
            with self.assertRaises(ValueError):
                packager.package(source, source)
            self.assertEqual(source.read_bytes(), original)

    def test_rejects_watch_only_input(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "watch.ipa"
            self.fixture(source, platform="WatchOS")
            with self.assertRaises(ValueError):
                packager.package(source, Path(directory) / "phone.ipa")

    def test_repackaging_phone_only_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            source, first, second = [Path(directory) / name for name in ["full.ipa", "phone.ipa", "again.ipa"]]
            self.fixture(source)
            packager.package(source, first)
            result = packager.package(first, second)
            self.assertEqual(result["removed_entries"], 0)
            self.assertEqual(first.read_bytes(), second.read_bytes())


if __name__ == "__main__":
    unittest.main()
