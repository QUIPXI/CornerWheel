#!/usr/bin/env python3
"""Check CornerWheel's staged feed or public HTTPS update files without installing."""

import argparse
import base64
import hashlib
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_FEED_BYTES = 4 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024


def https_url(value, stable=True):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.fragment or (stable and parsed.query)
            or any(c.isspace() or ord(c) < 32 for c in value)):
        raise ValueError("Use a stable HTTPS URL without credentials, queries, fragments, or whitespace.")
    # Accessing port also validates malformed port strings.
    _ = parsed.port
    if parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("The update URL must be publicly reachable.")
    return parsed


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        https_url(newurl, stable=False)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def response_for(url):
    https_url(url)
    request = urllib.request.Request(url, headers={
        "User-Agent": "CornerWheel-Update-Host-Check/1.0",
        "Accept-Encoding": "identity",
        "Cache-Control": "no-cache",
    })
    # No cookies, login session, or Authorization header are used.
    response = urllib.request.build_opener(HTTPSRedirects()).open(request, timeout=30)
    https_url(response.url, stable=False)
    if response.status != 200:
        response.close()
        raise ValueError("Expected HTTP 200 for an update resource.")
    return response


def read_feed(data):
    if len(data) > MAX_FEED_BYTES:
        raise ValueError("The feed is unexpectedly large.")
    if re.search(br"<!\s*(?:DOCTYPE|ENTITY)\b", data, flags=re.I):
        raise ValueError("The feed must not contain a DTD or entity declaration.")
    root = ET.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Expected raw RSS XML; an HTML page or viewer URL is not an appcast.")
    items = root.findall("channel/item")
    if not items:
        raise ValueError("The appcast has no releases.")
    return items


def item_version(item):
    enclosure = item.find("enclosure")
    value = item.findtext(SPARKLE + "version")
    if value is None and enclosure is not None:
        value = enclosure.get(SPARKLE + "version")
    if not value or not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("CornerWheel releases require positive integer build numbers.")
    return int(value)


def filename_for(url):
    name = urllib.parse.unquote(https_url(url).path.rsplit("/", 1)[-1])
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        raise ValueError("An update URL must end in a safe filename.")
    return name


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.digest()


def validate_item(item):
    build = item_version(item)
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError(f"Build {build} has no full update archive.")
    url = enclosure.get("url", "")
    name = filename_for(url)
    if not name.endswith(".zip"):
        raise ValueError(f"Build {build} must point to a ZIP archive.")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    try:
        valid_signature = len(base64.b64decode(signature, validate=True)) == 64
    except (ValueError, base64.binascii.Error):
        valid_signature = False
    if not valid_signature:
        raise ValueError(f"Build {build} has no validly formatted Ed25519 signature.")
    size = int(enclosure.get("length", "0"))
    if not 0 < size <= MAX_ARCHIVE_BYTES:
        raise ValueError(f"Build {build} has an invalid or unexpectedly large archive size.")
    minimum = item.findtext(SPARKLE + "minimumSystemVersion", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum):
        raise ValueError(f"Build {build} is missing its minimum macOS version.")
    if tuple(int(n) for n in minimum.split(".")) < (14, 0):
        raise ValueError(f"Build {build} advertises macOS older than CornerWheel supports.")
    if item.findtext(SPARKLE + "hardwareRequirements") != "arm64":
        raise ValueError(f"Build {build} must advertise the Apple silicon requirement.")
    return build, url, name, size


def check(feed_url, local_directory=None, expected_directory=None, expected_build=None):
    feed_name = filename_for(feed_url)
    if not feed_name.endswith(".xml"):
        raise ValueError("The stable feed URL must end in .xml.")
    if local_directory:
        data = (local_directory / feed_name).read_bytes()
    else:
        with response_for(feed_url) as response:
            data = response.read(MAX_FEED_BYTES + 1)
        if expected_directory and data != (expected_directory / feed_name).read_bytes():
            raise ValueError("The hosted feed differs from the staged feed (possibly stale caching).")
    items = read_feed(data)
    builds = [item_version(item) for item in items]
    if len(set(builds)) != len(builds):
        raise ValueError("The feed contains duplicate build numbers.")
    if expected_build is not None and max(builds) != expected_build:
        raise ValueError("The newest feed build does not match the expected build.")
    for item in items:
        build, url, name, expected_size = validate_item(item)
        if local_directory:
            archive = local_directory / name
            if archive.stat().st_size != expected_size:
                raise ValueError(f"Build {build}: staged archive size does not match the feed.")
            with archive.open("rb") as stream:
                prefix = stream.read(4)
        else:
            digest, actual_size, prefix = hashlib.sha256(), 0, b""
            with response_for(url) as response:
                if "text/html" in response.headers.get("Content-Type", "").lower():
                    raise ValueError(f"Build {build}: the download returned an HTML page.")
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    if not prefix:
                        prefix = chunk[:4]
                    actual_size += len(chunk)
                    if actual_size > expected_size:
                        raise ValueError(f"Build {build}: download exceeds the signed feed's size.")
                    digest.update(chunk)
            if actual_size != expected_size:
                raise ValueError(f"Build {build}: download size does not match the feed.")
            if expected_directory and digest.digest() != file_digest(expected_directory / name):
                raise ValueError(f"Build {build}: hosted archive differs from the signed staged archive.")
        if prefix != b"PK\x03\x04":
            raise ValueError(f"Build {build}: the resource is not a ZIP archive.")
        print(f"OK: build {build}, {name}, {expected_size} bytes")
    if not local_directory and not expected_directory:
        print("Availability and metadata passed. Use --expected-directory to compare with signed release bytes.")
    print("Feed checks passed. No app was installed; this does not replace an in-app update test.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed_url", help="The public, stable HTTPS .xml URL.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--local-directory", type=pathlib.Path,
                      help="Validate staged files only; make no network requests.")
    mode.add_argument("--expected-directory", type=pathlib.Path,
                      help="Download all hosted archives and compare to these signed staged files.")
    parser.add_argument("--expected-build", type=int)
    args = parser.parse_args()
    try:
        check(args.feed_url, args.local_directory, args.expected_directory, args.expected_build)
    except (ValueError, OSError, ET.ParseError, urllib.error.URLError) as error:
        print(f"Update check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
