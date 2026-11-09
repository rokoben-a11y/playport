# SPDX-License-Identifier: GPL-3.0-or-later
"""The private Mac-then-Linux build recipe stays on the pins the tree already locks.

It does not invent a second SDK layout. xtool 1.20.1 builds darwin.xtoolsdk from
an installed Xcode.app; Linux installs that bundle. The public repository does
not gain a workflow that uploads the SDK.
"""

import pathlib
import plistlib
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]


class CIBuildRecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mac = (REPO / "build/ci/darwin-sdk-export.sh").read_text()
        cls.linux = (REPO / "build/ci/linux-unsigned-build.sh").read_text()
        cls.crt = (REPO / "build/toolchain/llvm-mingw-arm64ec.sh").read_text()
        cls.building = (REPO / "docs/BUILDING.md").read_text()

    def testTheMacStepIsXtoolSdkBuildOfTheInstalledApp(self):
        self.assertIn("/Applications/Xcode_26.6.app", self.mac)
        self.assertIn("iPhoneOS26.5.sdk", self.mac)
        self.assertIn("MacOSX26.5.sdk", self.mac)
        self.assertIn("sdk build", self.mac)
        self.assertIn("--arch", self.mac)
        commands = "\n".join(line for line in self.mac.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("sdk install", commands)
        self.assertNotIn("tar -C /Applications", commands)
        self.assertNotIn("spctl --master-disable", commands)
        self.assertNotIn("xattr -dr com.apple.quarantine", commands)
        self.assertIn("Contents/Resources/bin/xtool", commands)
        self.assertNotIn('Contents/MacOS/xtool" --version', commands)
        self.assertLess(commands.index("probe done"), commands.index('"$cli" sdk build'))
        self.assertIn("39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2", self.mac)

    def testTheLinuxStepInstallsThatBundleAndBuildsUnsigned(self):
        self.assertIn("sdk install", self.linux)
        self.assertIn("040c58d5c708f613b9b74cbdb24e25e8d72c47ff86941f19463626d811159831", self.linux)
        self.assertIn("bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21", self.linux)
        self.assertIn(self.linux_sha_from_building(), self.linux)
        self.assertIn("./pp build --variant release --unsigned", self.linux)
        self.assertIn("--compressed", self.linux)
        self.assertIn("52BB7E3DE28A71BE22EC05FFEF80A866B47A981F", self.linux)
        self.assertIn("-----BEGIN PGP PUBLIC KEY BLOCK-----", self.linux)
        self.assertIn("VALIDSIG", self.linux)
        self.assertNotIn("all-keys.asc | gpg", self.linux)
        self.assertIn("iPhoneOS26.5.sdk", self.linux)
        self.assertIn("MacOSX26.5.sdk", self.linux)
        self.assertNotIn("xtool sdk build", self.linux)

    def testTheCrtRebuildUsesTheLockedMingwCommitAndArm64x(self):
        self.assertIn("57b595039040eaa15bece85b7cc71d952281b269", self.crt)
        self.assertIn("--enable-libarm64", self.crt)
        self.assertIn("--enable-arm64x", self.crt)
        self.assertIn("--enable-cfguard", self.crt)
        self.assertIn("libclang_rt.builtins-aarch64.a", self.crt)
        self.assertIn("aarch64-w64-mingw32", self.crt)

    def testTheAppIsUniversalSoALargeDisplayIsNotAPhoneCanvas(self):
        info = plistlib.loads((REPO / "app/Info.plist").read_bytes())
        self.assertEqual(info["UIDeviceFamily"], [1, 2])
        self.assertNotIn("UIRequiresFullScreen", info)
        self.assertIsInstance(info["UILaunchScreen"], dict)
        self.assertEqual(info["UISupportedInterfaceOrientations"], [
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        self.assertEqual(info["UISupportedInterfaceOrientations~ipad"], [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        jit = plistlib.loads((REPO / "app/PlayportJIT-Info.plist").read_bytes())
        self.assertEqual(jit.get("NSExtension", {}).get("NSExtensionPointIdentifier"), "com.apple.ar.viewer")

    def testNoWorkflowInThePublicTreeUploadsTheSdk(self):
        workflows = list((REPO / ".github").glob("workflows/*")) if (REPO / ".github").is_dir() else []
        for path in workflows:
            text = path.read_text(errors="replace")
            self.assertNotIn("darwin.xtoolsdk", text, path)
            self.assertNotIn("xcode-subset", text, path)

    def linux_sha_from_building(self):
        for line in self.building.splitlines():
            if "bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21" in line:
                return "bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21"
        self.fail("BUILDING.md no longer records the llvm-mingw 20260922 sha256")


if __name__ == "__main__":
    unittest.main()
