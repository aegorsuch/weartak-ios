#!/usr/bin/env python3
"""Prepare the signed iPhone plist without exposing the optional CI identity."""
import argparse
import hashlib
import os
import plistlib
import re
import zipfile
from pathlib import Path


def prepare(template, output, value):
    value = value.strip()
    if value and (len(value) > 24_576 or not re.fullmatch(r"[A-Za-z0-9_+/=-]+", value)):
        raise ValueError("DITTO_COMMUNITY_PDL must contain a bounded encoded PDL, not a file path.")
    with Path(template).open("rb") as source:
        info = plistlib.load(source)
    info["DITTO_COMMUNITY_PDL"] = value
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as destination:
        plistlib.dump(info, destination)
    return len(value), hashlib.sha256(value.encode("ascii")).hexdigest()


def verify(template, ipa):
    expected = plistlib.loads(Path(template).read_bytes())["DITTO_COMMUNITY_PDL"]
    with zipfile.ZipFile(ipa) as archive:
        candidates = [name for name in archive.namelist()
                      if name.startswith("Payload/") and name.endswith(".app/Info.plist")
                      and name.count("/") == 2]
        if len(candidates) != 1:
            raise ValueError("Expected one iPhone Info.plist.")
        actual = plistlib.loads(archive.read(candidates[0])).get("DITTO_COMMUNITY_PDL")
    if not isinstance(actual, str) or actual != expected:
        raise ValueError("Exported community identity does not match the prepared plist.")
    return len(actual), hashlib.sha256(actual.encode("ascii")).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output")
    mode.add_argument("--verify-ipa")
    args = parser.parse_args()
    try:
        if args.verify_ipa:
            length, digest = verify(args.template, args.verify_ipa)
        else:
            length, digest = prepare(args.template, args.output, os.environ.get("DITTO_COMMUNITY_PDL", ""))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException):
        parser.exit(1, "ERROR: Unable to prepare the optional Ditto community identity plist.\n")
    if length:
        print(f"Community Ditto identity included: length={length}, SHA256={digest}")
    else:
        print("Community Ditto identity not provisioned; the app will show missing-identity status.")


if __name__ == "__main__":
    main()
