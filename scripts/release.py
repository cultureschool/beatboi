#!/usr/bin/env python3
"""
One-command TestFlight release for AquaSort.

This replaces the ad-hoc sequence that used to be run by hand and only existed as
three throwaway scripts in the gitignored build/ directory. Everything needed to
ship a build now lives here, in one checked-in file:

    1. bump        write the build number into the Xcode project
    2. tests       run the AquaSortTests unit suite          (skippable)
    3. archive     xcodebuild archive -configuration Release
    4. export      xcodebuild -exportArchive  -> App Store IPA
    5. upload      xcrun altool --upload-app  -> App Store Connect
    6. compliance  clear "Missing Compliance" (exempt encryption)
    7. notes       set the tester-facing "What to Test" text

The run does not block on processing. App Store Connect exposes an upload within
a minute or so, and compliance plus "What to Test" can be set while the build is
still PROCESSING, so that is where the script stops by default. Pass --wait-valid
to hold the terminal until the build is actually VALID.

If anything after the upload fails, the build is already on App Store Connect and
the same build number cannot be uploaded again, so the script reports what broke
and tells you to finish with --asc-only instead of losing the delivery.

Usage:
    python3 scripts/release.py <build_number> <notes_file> [options]

Examples:
    python3 scripts/release.py 9 build/release-notes-build9.txt
    python3 scripts/release.py 9 notes.txt --dry-run       # check everything, do nothing
    python3 scripts/release.py 9 notes.txt --skip-tests
    python3 scripts/release.py 9 notes.txt --skip-upload   # archive + export only
    python3 scripts/release.py 9 notes.txt --asc-only      # finish an upload that broke

Environment (all optional; the defaults are this app's real values):
    ASC_KEY_ID        App Store Connect API key ID
    ASC_ISSUER_ID     App Store Connect API issuer ID
    ASC_APP_ID        App Store Connect app ID
    ASC_KEY_PATH      path to the .p8 private key
    AQUASORT_TEAM_ID  Apple developer team ID (otherwise read from project.pbxproj)

The .p8 private key is never read from the repository and must never be committed:
by default it is expected at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8,
which is also where altool looks for it.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# --- Layout ------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "AquaSort.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEME = "AquaSort"
APP_NAME = "AquaSort"
BUILD_DIR = ROOT / "build"

# --- App Store Connect -------------------------------------------------------

# These are identifiers, not secrets. The private key that signs the API requests
# stays outside the repo; see the module docstring.
KEY_ID = os.environ.get("ASC_KEY_ID", "PQ6PSM2D44")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "7e713bc9-954a-41a0-b630-4cdb3054d71f")
APP_ID = os.environ.get("ASC_APP_ID", "6811129248")

STOREKIT_CONFIG = ROOT / "StoreKitConfig" / "AquaSort.storekit"
STOREKIT_MANAGER = ROOT / "AquaSort" / "App" / "StoreKitManager.swift"

KEY_DIR = Path.home() / ".appstoreconnect" / "private_keys"
KEY_PATH = Path(os.environ.get("ASC_KEY_PATH", KEY_DIR / f"AuthKey_{KEY_ID}.p8")).expanduser()

API_BASE = "https://api.appstoreconnect.apple.com"
WHATS_NEW_LIMIT = 4000  # App Store Connect's cap on "What to Test"

# How long to keep polling App Store Connect for the uploaded build to appear, or
# to finish processing when --wait-valid is used. Apple is usually done in a few
# minutes; the default is generous.
DEFAULT_TIMEOUT = 1800
POLL_INTERVAL = 20


# --- Small helpers -----------------------------------------------------------


class StepError(Exception):
    """A step failed after the upload, where the delivery itself is still good."""


def die(message: str) -> "None":
    print(f"\nERROR: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def fail(message: str) -> "None":
    """Abort the current step, keeping the already-uploaded build recoverable."""
    raise StepError(message)


def note(message: str) -> None:
    print(f"  {message}", flush=True)


def run(cmd: list, capture: bool = False) -> subprocess.CompletedProcess:
    """Run a command from the project root, streaming output unless captured."""
    printable = " ".join(shlex.quote(str(part)) for part in cmd)
    print(f"  $ {printable}", flush=True)
    result = subprocess.run(
        [str(part) for part in cmd],
        cwd=str(ROOT),
        capture_output=capture,
        text=True,
    )
    if result.returncode != 0:
        if capture:
            sys.stderr.write((result.stdout or "") + (result.stderr or ""))
        die(f"command failed with exit code {result.returncode}")
    return result


# --- App Store Connect API ---------------------------------------------------


class AppStoreConnect:
    """Minimal client for the bits of the App Store Connect API we need.

    Requests are signed with an ES256 JWT built from the App Store Connect API
    key. openssl does the ECDSA signing, so this has no third-party dependencies.
    The token is refreshed every 10 minutes to survive long processing waits.
    """

    def __init__(self) -> None:
        self._token = None
        self._token_at = 0.0

    @staticmethod
    def _b64url(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    def _make_token(self) -> str:
        now = int(time.time())
        header = self._b64url(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
        payload = self._b64url(
            json.dumps({"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode()
        )
        signing_input = f"{header}.{payload}".encode()
        try:
            der = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", str(KEY_PATH)],
                input=signing_input,
                capture_output=True,
                check=True,
            ).stdout
        except (subprocess.CalledProcessError, FileNotFoundError) as error:
            die(f"could not sign the App Store Connect token with {KEY_PATH}: {error}")

        # openssl emits a DER ECDSA signature: SEQUENCE { INTEGER r, INTEGER s }.
        # The JWT needs the raw r||s pair, each left-padded to 32 bytes.
        if not der or der[0] != 0x30:
            die("unexpected signature format from openssl")
        index = 2
        if der[index] != 0x02:
            die("unexpected signature format from openssl (r)")
        r_length = der[index + 1]
        r = der[index + 2: index + 2 + r_length]
        index2 = index + 2 + r_length
        if der[index2] != 0x02:
            die("unexpected signature format from openssl (s)")
        s_length = der[index2 + 1]
        s = der[index2 + 2: index2 + 2 + s_length]
        r = r.lstrip(b"\x00")[-32:].rjust(32, b"\x00")
        s = s.lstrip(b"\x00")[-32:].rjust(32, b"\x00")
        return f"{header}.{payload}.{self._b64url(r + s)}"

    def _bearer(self) -> str:
        if self._token is None or time.time() - self._token_at > 600:
            self._token = self._make_token()
            self._token_at = time.time()
        return self._token

    def request(self, method: str, path: str, body: dict = None, retries: int = 0):
        """Returns (status, decoded_body). Retries transient failures when asked."""
        attempt = 0
        while True:
            request = urllib.request.Request(API_BASE + path, method=method)
            request.add_header("Authorization", f"Bearer {self._bearer()}")
            data = None
            if body is not None:
                data = json.dumps(body).encode()
                request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, data) as response:
                    return response.status, json.loads(response.read() or b"{}")
            except urllib.error.HTTPError as error:
                payload = json.loads(error.read() or b"{}")
                if attempt < retries and error.code in (409, 429, 500, 502, 503):
                    attempt += 1
                    note(f"HTTP {error.code}, retrying ({attempt}/{retries})")
                    time.sleep(10 * attempt)
                    continue
                return error.code, payload
            except urllib.error.URLError as error:
                if attempt < retries:
                    attempt += 1
                    note(f"network error ({error.reason}), retrying ({attempt}/{retries})")
                    time.sleep(10 * attempt)
                    continue
                die(f"could not reach App Store Connect: {error.reason}")

    def product_ids(self) -> list:
        """Product IDs of the app's in-app purchases."""
        # Retried: App Store Connect returns sporadic 500s, and a transient blip
        # should not be reported to the user as a missing in-app purchase.
        status, body = self.request("GET", f"/v1/apps/{APP_ID}/inAppPurchasesV2", retries=3)
        if status != 200:
            die(f"could not list in-app purchases: HTTP {status} {json.dumps(body)[:300]}")
        return [item["attributes"].get("productId", "") for item in body.get("data", []) or []]

    def builds(self, build_number: int) -> list:
        query = urllib.parse.urlencode(
            {"filter[app]": APP_ID, "filter[version]": build_number, "sort": "-uploadedDate"}
        )
        # Retried: this is polled while waiting for a build, and a transient 500
        # would otherwise abort a release mid-wait.
        status, body = self.request("GET", f"/v1/builds?{query}", retries=3)
        if status != 200:
            die(f"could not list builds: HTTP {status} {json.dumps(body)[:300]}")
        return body.get("data", []) or []


# --- Release -----------------------------------------------------------------


class Release:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.build_number: int = args.build_number
        self.notes: str = ""
        self.team_id: str = ""
        self.archive_path: Path = BUILD_DIR / f"{APP_NAME}-{self.build_number}.xcarchive"
        self.export_dir: Path = BUILD_DIR / f"export{self.build_number}"
        self.ipa: Path = self.export_dir / f"{APP_NAME}.ipa"
        self.build_id: str = ""
        self.delivery_uuid: str = ""
        self._step = 0
        self._total = 0

    # -- output ---------------------------------------------------------

    def _banner(self, text: str) -> None:
        self._step += 1
        print(f"\n=== [{self._step}/{self._total}] {text} ===", flush=True)

    def _plan(self, steps: list) -> None:
        self._total = len(steps)

    # -- steps ----------------------------------------------------------

    def preflight(self) -> None:
        print("AquaSort release", flush=True)
        note(f"build number : {self.build_number}")
        note(f"notes file   : {self.args.notes_file}")
        note(f"project      : {PROJECT}")

        if not PROJECT.exists():
            die(f"{PROJECT} not found; run this from a checkout of the repo")
        if not PBXPROJ.exists():
            die(f"{PBXPROJ} not found")

        self.notes = self._read_notes()
        self.team_id = resolve_team_id()
        note(f"team id      : {self.team_id}")
        note(f"notes length : {len(self.notes)} chars")

        if not self.args.asc_only:
            self._check_working_tree()

        if shutil.which("xcodebuild") is None:
            die("xcodebuild not found; install Xcode and run 'xcode-select --install'")

        if not self.args.skip_upload:
            self._check_credentials()
            if not self.args.asc_only:
                self._check_export_pack()

    def _check_working_tree(self) -> None:
        """Refuse to ship source that is not in a commit, unless told to.

        Untracked files count: the app target uses a file-system-synchronized
        group, so a new .swift file is compiled without any project change. Files
        under build/ and scripts/ never reach the app bundle and are ignored, so
        the tooling itself cannot block a release.
        """
        result = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        changes = [
            line for line in result.stdout.splitlines()
            if not line[3:].strip().strip('"').startswith(("build/", "scripts/"))
        ]
        if changes and not self.args.allow_dirty:
            listing = "\n".join(f"  {line}" for line in changes[:10])
            die(
                "the working tree has uncommitted changes, so the build would not\n"
                f"correspond to any commit:\n{listing}\n"
                "  Commit them first, or pass --allow-dirty to ship anyway."
            )

        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(ROOT), capture_output=True, text=True
        ).stdout.strip()
        upstream = subprocess.run(
            ["git", "rev-parse", "--verify", "@{upstream}"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        if head and upstream.returncode == 0 and upstream.stdout.strip() != head:
            print(
                "\nWARNING: HEAD is not pushed, so this build comes from a commit that\n"
                "  exists only on this machine.",
                file=sys.stderr,
                flush=True,
            )

    def _check_credentials(self) -> None:
        if not KEY_PATH.exists():
            die(f"App Store Connect key not found at {KEY_PATH}\n  Set ASC_KEY_PATH or download the key from App Store Connect.")
        if KEY_PATH.parent != KEY_DIR:
            print(
                f"WARNING: the upload step uses altool, which only finds keys in {KEY_DIR}.\n"
                f"  ASC_KEY_PATH points at {KEY_PATH}, so the API calls will work but the upload may not.",
                file=sys.stderr,
                flush=True,
            )
        altool = subprocess.run(["xcrun", "--find", "altool"], capture_output=True, text=True)
        if altool.returncode != 0 or not altool.stdout.strip():
            die("altool not available; install the Xcode command line tools")

        # Fail here rather than after the archive and upload: App Store Connect
        # rejects a duplicate build number, and altool's complaint is opaque.
        if not self.args.asc_only:
            existing = AppStoreConnect().builds(self.build_number)
            if existing:
                state = existing[0]["attributes"].get("processingState", "?")
                die(
                    f"build {self.build_number} is already on App Store Connect (state: {state}).\n"
                    "  Bump the build number to upload a new build, or pass --asc-only to\n"
                    "  finish its compliance and What to Test notes."
                )

    def _check_export_pack(self) -> None:
        """The Export Pack product ID must match on every side before a build ships.

        A mismatch makes the paid unlock impossible to buy in TestFlight and in the
        App Store, while Xcode's local StoreKit config keeps it looking healthy.
        That is exactly how `exportunlock` (live) and `com.bytepocket.studio.export`
        (app and config) drifted apart unnoticed, so check all three here. This is
        the only side a unit test cannot reach, which is why the gate lives on the
        release path.
        """
        requested = export_pack_product_id()
        offered = storekit_config_product_ids()
        if requested not in offered:
            die(
                f"the app requests {requested!r} but AquaSort.storekit offers {offered}.\n"
                "  Align the app constant and the StoreKit config before shipping."
            )

        live = AppStoreConnect().product_ids()
        if requested not in live:
            die(
                f"App Store Connect has no in-app purchase with the id {requested!r}\n"
                f"  (it currently has: {live or 'nothing'}).\n"
                "  The Export Pack would be unbuyable, so the build is not worth shipping.\n"
                "  Create the product under App Store Connect > your app > In-App Purchases,\n"
                "  or change the app constant if the live id is the intended one."
            )
        note(f"export pack  : {requested} (app, config and App Store Connect agree)")

    def _read_notes(self) -> str:
        path = Path(self.args.notes_file)
        if not path.is_absolute():
            path = ROOT / path
        if not path.exists():
            die(f"notes file not found: {path}")
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            die(f"notes file is empty: {path}")
        if len(text) > WHATS_NEW_LIMIT:
            die(f"notes are {len(text)} chars; App Store Connect caps What to Test at {WHATS_NEW_LIMIT}")
        return text

    def bump(self) -> None:
        """Write the build number into the app target's build configurations.

        Only the app target's CURRENT_PROJECT_VERSION ends up in the shipped
        bundle, so that is all this touches. The test bundles keep their own
        values; every build bump in this repo's history has left them alone, and
        rewriting them would put unrelated churn in the release diff.
        """
        text = PBXPROJ.read_text(encoding="utf-8")
        config_ids = app_target_configuration_ids(text)
        if not config_ids:
            die(f"could not find the build configurations for the {APP_NAME} target")

        updated = text
        current, changed = [], 0
        for config_id in config_ids:
            bounds = configuration_bounds(updated, config_id)
            if not bounds:
                die(f"could not locate build configuration {config_id}")
            start, end = bounds

            block = updated[start:end]
            match = re.search(r"(CURRENT_PROJECT_VERSION = )(\d+)(;)", block)
            if not match:
                die(f"build configuration {config_id} has no CURRENT_PROJECT_VERSION")
            current.append(match.group(2))

            if match.group(2) != str(self.build_number):
                block = (
                    block[: match.start()]
                    + f"{match.group(1)}{self.build_number}{match.group(3)}"
                    + block[match.end():]
                )
                updated = updated[:start] + block + updated[end:]
                changed += 1

        current = sorted(set(current))
        if changed == 0:
            note(f"the {APP_NAME} target is already on build {self.build_number}")
            return

        highest = max(int(value) for value in current)
        if self.build_number <= highest:
            print(
                f"WARNING: build number {self.build_number} is not higher than the current {highest}.\n"
                "  TestFlight rejects duplicate build numbers for the same version.",
                file=sys.stderr,
                flush=True,
            )

        PBXPROJ.write_text(updated, encoding="utf-8")
        note(
            f"{APP_NAME} target CURRENT_PROJECT_VERSION {current} -> "
            f"{self.build_number} ({changed} configurations)"
        )
        note("remember to commit this bump so the repo records what shipped")

    def tests(self) -> None:
        destination = self.args.destination or os.environ.get(
            "AQUASORT_TEST_DESTINATION", "platform=iOS Simulator,name=BytePocket Preview"
        )
        note(f"destination: {destination}")
        run([
            "xcodebuild", "test",
            "-project", PROJECT,
            "-scheme", SCHEME,
            "-destination", destination,
            "-only-testing:AquaSortTests",
        ])

    def archive(self) -> None:
        if self.archive_path.exists():
            shutil.rmtree(self.archive_path)
        BUILD_DIR.mkdir(parents=True, exist_ok=True)
        run([
            "xcodebuild", "archive",
            "-project", PROJECT,
            "-scheme", SCHEME,
            "-configuration", "Release",
            "-destination", "generic/platform=iOS",
            "-archivePath", self.archive_path,
            "-allowProvisioningUpdates",
        ])
        if not self.archive_path.exists():
            die(f"archive was not produced at {self.archive_path}")
        note(f"archive: {self.archive_path}")

    def export(self) -> None:
        if self.export_dir.exists():
            shutil.rmtree(self.export_dir)
        self.export_dir.mkdir(parents=True, exist_ok=True)

        # Generated rather than checked in so the export settings live next to the
        # steps that use them and cannot drift from the archive they export.
        options = BUILD_DIR / "ExportOptions.plist"
        options.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n'
            "<dict>\n"
            "\t<key>method</key>\n\t<string>app-store-connect</string>\n"
            f"\t<key>teamID</key>\n\t<string>{self.team_id}</string>\n"
            "\t<key>signingStyle</key>\n\t<string>automatic</string>\n"
            "\t<key>uploadSymbols</key>\n\t<true/>\n"
            "\t<key>destination</key>\n\t<string>export</string>\n"
            "</dict>\n"
            "</plist>\n",
            encoding="utf-8",
        )
        note(f"export options: {options}")

        run([
            "xcodebuild", "-exportArchive",
            "-archivePath", self.archive_path,
            "-exportPath", self.export_dir,
            "-exportOptionsPlist", options,
            "-allowProvisioningUpdates",
        ])

        if not self.ipa.exists():
            die(f"IPA was not produced at {self.ipa}")
        self._verify_ipa()
        note(f"ipa: {self.ipa} ({self.ipa.stat().st_size / 1_048_576:.1f} MB)")

    def _verify_ipa(self) -> None:
        """Guards against shipping a stale archive that does not carry the build number."""
        raw = subprocess.run(
            ["unzip", "-p", str(self.ipa), f"Payload/{APP_NAME}.app/Info.plist"],
            capture_output=True,
        ).stdout
        if not raw:
            die(f"could not read the Info.plist inside {self.ipa}")
        info = plistlib.loads(raw)
        bundle_build = str(info.get("CFBundleVersion", ""))
        bundle_version = str(info.get("CFBundleShortVersionString", ""))
        if bundle_build != str(self.build_number):
            die(f"IPA carries build {bundle_build}, expected {self.build_number}")
        note(f"verified: {APP_NAME} {bundle_version} ({bundle_build})")

    def upload(self) -> None:
        # altool resolves the API key from ~/.appstoreconnect/private_keys/ by key ID.
        result = run([
            "xcrun", "altool", "--upload-app",
            "-f", self.ipa,
            "-t", "ios",
            "--apiKey", KEY_ID,
            "--apiIssuer", ISSUER_ID,
        ], capture=True)
        output = (result.stdout or "") + (result.stderr or "")
        print(output.strip(), flush=True)

        match = re.search(r"(?:RequestUUID|Delivery UUID)\s*[=:]\s*([0-9a-fA-F-]{36})", output)
        if match:
            self.delivery_uuid = match.group(1)
        note("upload accepted by App Store Connect")

    def wait_for_build(self) -> None:
        """Wait until App Store Connect exposes the uploaded build.

        Uploads appear within a minute or so; the build then spends several
        minutes PROCESSING, and both compliance and "What to Test" can be set
        while that runs. So by default this returns as soon as the build exists
        instead of blocking the release on processing. --wait-valid holds the
        terminal until the build is actually VALID.
        """
        asc = AppStoreConnect()
        deadline = time.time() + self.args.timeout
        last_state = None

        while True:
            builds = asc.builds(self.build_number)
            if builds:
                build = builds[0]
                self.build_id = build["id"]
                state = build["attributes"].get("processingState", "?")
                if state != last_state:
                    note(f"build {self.build_number}: {state}")
                    last_state = state
                if state in ("INVALID", "FAILED"):
                    die(f"build {self.build_number} finished processing as {state}")
                if not self.args.wait_valid or state == "VALID":
                    return
            elif last_state is None:
                note("waiting for the build to appear...")
                last_state = "MISSING"

            if time.time() >= deadline:
                waiting_for = "to finish processing" if self.args.wait_valid else "to appear"
                die(f"timed out after {self.args.timeout}s waiting for build {self.build_number} {waiting_for}")
            time.sleep(POLL_INTERVAL)

    def compliance(self) -> None:
        asc = AppStoreConnect()
        status, body = asc.request("GET", f"/v1/builds/{self.build_id}")
        if status != 200:
            fail(f"could not read build {self.build_number}: HTTP {status} {json.dumps(body)[:300]}")

        if body["data"]["attributes"].get("usesNonExemptEncryption") is False:
            note("encryption compliance already cleared")
            return

        # The exempt-encryption Info.plist declaration usually clears this at
        # upload time; this is the fallback for when it has not caught up yet.
        status, result = asc.request(
            "PATCH",
            f"/v1/builds/{self.build_id}",
            {
                "data": {
                    "type": "builds",
                    "id": self.build_id,
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
            retries=5,
        )
        if status != 200:
            fail(f"could not clear encryption compliance: HTTP {status} {json.dumps(result)[:300]}")
        note("encryption compliance cleared")

    def set_notes(self) -> None:
        asc = AppStoreConnect()
        status, body = asc.request("GET", f"/v1/betaBuildLocalizations?filter%5Bbuild%5D={self.build_id}")
        if status != 200:
            fail(f"could not read beta build localizations: HTTP {status} {json.dumps(body)[:300]}")

        localization_id = None
        for item in body.get("data", []) or []:
            if item["attributes"].get("locale") == "en-US":
                localization_id = item["id"]
                break

        # "What to Test" is the whatsNew attribute of the build's en-US localization.
        if localization_id:
            status, result = asc.request(
                "PATCH",
                f"/v1/betaBuildLocalizations/{localization_id}",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": localization_id,
                        "attributes": {"whatsNew": self.notes},
                    }
                },
                retries=5,
            )
        else:
            status, result = asc.request(
                "POST",
                "/v1/betaBuildLocalizations",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": "en-US", "whatsNew": self.notes},
                        "relationships": {"build": {"data": {"type": "builds", "id": self.build_id}}},
                    }
                },
                retries=5,
            )

        if status not in (200, 201):
            fail(f"could not set What to Test: HTTP {status} {json.dumps(result)[:500]}")

        # Read it back so a silent API no-op cannot masquerade as success.
        status, body = asc.request("GET", f"/v1/betaBuildLocalizations?filter%5Bbuild%5D={self.build_id}")
        if status != 200:
            fail(f"could not verify What to Test: HTTP {status}")
        stored = ""
        for item in body.get("data", []) or []:
            if item["attributes"].get("locale") == "en-US":
                stored = item["attributes"].get("whatsNew") or ""
                break
        if stored.strip() != self.notes:
            fail("What to Test did not read back the same text that was sent")
        note(f"What to Test set and verified ({len(stored)} chars)")

    # -- driver ---------------------------------------------------------

    def check_archive(self) -> None:
        """Reuse the archive from an earlier attempt instead of rebuilding it."""
        if not self.archive_path.exists():
            die(f"no archive at {self.archive_path}; drop --skip-archive to build one")
        note(f"reusing {self.archive_path}")

    def run(self) -> int:
        self.preflight()

        steps = []
        if not self.args.asc_only:
            steps.append(("Write the build number into the project", self.bump))
            if not self.args.skip_tests:
                steps.append(("Run the unit tests", self.tests))
            if self.args.skip_archive:
                steps.append(("Reuse the existing archive", self.check_archive))
            else:
                steps.append(("Archive Release", self.archive))
            steps.append(("Export the App Store IPA", self.export))

        if not self.args.skip_upload:
            if not self.args.asc_only:
                steps.append(("Upload the IPA", self.upload))
            steps.append(("Find the build on App Store Connect", self.wait_for_build))
            steps.append(("Clear encryption compliance", self.compliance))
            steps.append(("Set the What to Test notes", self.set_notes))

        self._plan(steps)

        if self.args.dry_run:
            print("\nDry run - these steps would run:\n", flush=True)
            for index, (label, _) in enumerate(steps, start=1):
                print(f"  {index}. {label}", flush=True)
            print("\nNothing was executed.", flush=True)
            return 0

        try:
            for label, action in steps:
                self._banner(label)
                action()
        except StepError as error:
            print(f"\nERROR: {error}", file=sys.stderr, flush=True)
            self._report_recovery()
            return 1

        self._summarize()
        return 0

    def _report_recovery(self) -> None:
        print(
            "\nThe build is already on App Store Connect, so the delivery was not lost.\n"
            "Finish it without re-uploading with:\n"
            f"  python3 scripts/release.py {self.build_number} {self.args.notes_file} --asc-only",
            file=sys.stderr,
            flush=True,
        )

    def _summarize(self) -> None:
        print("\n=== Done ===", flush=True)
        note(f"build number  : {self.build_number}")
        if self.delivery_uuid:
            note(f"delivery uuid : {self.delivery_uuid}")
        if self.archive_path.exists():
            note(f"archive       : {self.archive_path}")
        if self.ipa.exists():
            note(f"ipa           : {self.ipa}")
        if self.args.skip_upload:
            note("upload skipped; nothing was sent to App Store Connect")
        else:
            note(f"testflight    : https://appstoreconnect.apple.com/apps/{APP_ID}/testflight/ios")
            if not self.args.wait_valid:
                note("the build may still be processing; testers see it once it is VALID")
            note("testers in the existing tester groups will pick this build up automatically")


def app_target_configuration_ids(text: str) -> list:
    """Look up the Debug/Release configuration IDs of the app target.

    Parsed from the project file rather than hardcoded, so the script keeps
    working if the project is regenerated or the IDs change.
    """
    target = re.search(
        rf"/\* {re.escape(APP_NAME)} \*/ = \{{\s*isa = PBXNativeTarget;.*?buildConfigurationList = ([0-9A-F]{{24}})",
        text,
        re.S,
    )
    if not target:
        return []
    listing = re.search(
        rf"{target.group(1)} /\* Build configuration list for PBXNativeTarget \"{re.escape(APP_NAME)}\" \*/ = \{{.*?buildConfigurations = \((.*?)\);",
        text,
        re.S,
    )
    if not listing:
        return []
    return re.findall(r"([0-9A-F]{24})", listing.group(1))


def export_pack_product_id() -> str:
    """The product ID the shipping app actually requests."""
    text = STOREKIT_MANAGER.read_text(encoding="utf-8")
    match = re.search(r'unlockProductID\s*=\s*"([^"]+)"', text)
    if not match:
        die(f"could not find unlockProductID in {STOREKIT_MANAGER}")
    return match.group(1)


def storekit_config_product_ids() -> list:
    """Product IDs offered by the local StoreKit config, which Xcode uses."""
    if not STOREKIT_CONFIG.exists():
        die(f"missing {STOREKIT_CONFIG}")
    data = json.loads(STOREKIT_CONFIG.read_text(encoding="utf-8"))
    return [product.get("productID", "") for product in data.get("products", [])]


def configuration_bounds(text: str, config_id: str):
    """Start/end offsets of an XCBuildConfiguration block, or None if not found."""
    start = text.find(f"{config_id} /* ")
    if start == -1:
        return None
    end = text.find("\n\t\t};", start)
    if end == -1:
        return None
    return start, end


def resolve_team_id() -> str:
    """The app target's DEVELOPMENT_TEAM.

    Read from the app target specifically, not the first match in the file: the
    test bundles carry their own DEVELOPMENT_TEAM value, so a plain search is not
    reliably the team that signs the archive.
    """
    override = os.environ.get("AQUASORT_TEAM_ID")
    if override:
        return override

    text = PBXPROJ.read_text(encoding="utf-8")
    for config_id in app_target_configuration_ids(text):
        bounds = configuration_bounds(text, config_id)
        if not bounds:
            continue
        match = re.search(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", text[bounds[0]:bounds[1]])
        if match:
            return match.group(1)
    die("could not find the app target's DEVELOPMENT_TEAM; set AQUASORT_TEAM_ID")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Archive, export, upload, and describe an AquaSort TestFlight build.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("build_number", type=int, help="TestFlight build number, e.g. 9")
    parser.add_argument("notes_file", help="file holding the 'What to Test' text")
    parser.add_argument("--skip-tests", action="store_true", help="do not run the unit suite")
    parser.add_argument("--skip-archive", action="store_true", help="reuse the archive already on disk")
    parser.add_argument("--skip-upload", action="store_true", help="stop after exporting the IPA")
    parser.add_argument(
        "--asc-only", action="store_true",
        help="skip the build; just finish compliance and notes on an uploaded build",
    )
    parser.add_argument("--wait-valid", action="store_true", help="block until the build finishes processing")
    parser.add_argument("--allow-dirty", action="store_true", help="ship even with uncommitted changes")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and exit without doing anything")
    parser.add_argument("--destination", help="test destination (default: the BytePocket Preview simulator)")
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT,
        help=(
            "seconds to wait for the build to appear, or to finish processing with "
            f"--wait-valid (default: {DEFAULT_TIMEOUT})"
        ),
    )
    args = parser.parse_args()

    if args.build_number < 1:
        parser.error("build number must be a positive integer")
    if args.asc_only and args.skip_upload:
        parser.error("--asc-only needs the App Store Connect phase, so it cannot be combined with --skip-upload")
    return args


if __name__ == "__main__":
    sys.exit(Release(parse_args()).run())
