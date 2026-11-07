# SPDX-License-Identifier: GPL-3.0-or-later
"""The private Mac-then-Linux build recipe stays on the pins the tree already locks.

It does not invent a second SDK layout. xtool 1.20.1 builds darwin.xtoolsdk from
an installed Xcode.app; Linux installs that bundle. The public repository does
not gain a workflow that uploads the SDK.
"""

import pathlib
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
        self.assertIn("com.apple.quarantine", commands)
        self.assertIn("xattr -dr com.apple.quarantine", commands)
        self.assertLess(commands.index("shasum -a 256 -c"), commands.index("xattr -dr com.apple.quarantine"))
        self.assertLess(commands.index("xattr -dr com.apple.quarantine"), commands.index("sdk build"))
        self.assertLess(commands.index("probe done"), commands.index('"$xtool" sdk build'))
        self.assertIn("39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2", self.mac)

    def testTheLinuxStepInstallsThatBundleAndBuildsUnsigned(self):
        self.assertIn("sdk install", self.linux)
        self.assertIn("040c58d5c708f613b9b74cbdb24e25e8d72c47ff86941f19463626d811159831", self.linux)
        self.assertIn("bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21", self.linux)
        self.assertIn(self.linux_sha_from_building(), self.linux)
        self.assertIn("./pp build --variant release --unsigned", self.linux)
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
