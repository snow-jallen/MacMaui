#!/usr/bin/env python3
"""Create or update the MacMaui Xcode Cloud workflow through the App Store Connect API.

Xcode Cloud products cannot be created through the API: POST /v1/ciProducts answers
"The resource 'ciProducts' does not allow 'CREATE'". So the one-time onboarding, which
connects the repository and registers the product, has to happen once in Xcode. Everything
after that is scriptable, which is what this file does.

Usage:
    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=/path/AuthKey_XXX.p8 \
        python scripts/xcode-cloud-workflow.py [--start-build]

Requires: pip install pyjwt cryptography
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com"

PRODUCT_NAME = "MacMaui"
REPO_OWNER = "snow-jallen"
REPO_NAME = "MacMaui"
WORKFLOW_NAME = "TestFlight"
CONTAINER_FILE_PATH = "XcodeCloud/MacMauiCloud.xcodeproj"
SCHEME = "MacMaui.Mobile"
BRANCH = "main"
# The .NET 10 iOS workload targets this Xcode; a newer one warns, an older one fails.
XCODE_VERSION_NAME = "Xcode 26.6"
MACOS_VERSION_NAME = "macOS Tahoe 26.6"


def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    with open(os.environ["ASC_KEY_PATH"], "rb") as fh:
        private_key = fh.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(path, method="GET", body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    last = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return exc.code, {"raw": raw.decode(errors="replace")[:400]}
        except Exception as exc:  # transient connection resets
            last = exc
            time.sleep(2 * (attempt + 1))
    raise last


def die(message, payload=None):
    print("error: " + message, file=sys.stderr)
    if payload:
        for err in payload.get("errors", [])[:5]:
            print("  " + str(err.get("title")) + ": " + str(err.get("detail")), file=sys.stderr)
    sys.exit(1)


def find(path, predicate, what):
    status, body = call(path)
    if status != 200:
        die("could not list " + what, body)
    for item in body.get("data", []):
        if predicate(item):
            return item
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-build", action="store_true", help="start a build once configured")
    args = parser.parse_args()

    for var in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if not os.environ.get(var):
            die(var + " is not set")

    # Xcode names the product after the scheme or the app, so match loosely rather than
    # insisting on one spelling: MacMaui, MacMaui.Mobile and MacMauiCloud all qualify.
    product = find(
        "/v1/ciProducts?limit=200",
        lambda d: PRODUCT_NAME.lower() in (d["attributes"].get("name") or "").lower(),
        "Xcode Cloud products",
    )
    if not product:
        die(
            "no Xcode Cloud product whose name contains '%s'. Create it once in Xcode: open %s "
            "on a Mac, then Product > Xcode Cloud > Create Workflow. This script configures it "
            "afterwards." % (PRODUCT_NAME, CONTAINER_FILE_PATH)
        )
    print("product      %s (%s)" % (product["id"], product["attributes"].get("name")))

    repo = find(
        "/v1/scmRepositories?limit=200",
        lambda d: d["attributes"].get("ownerName") == REPO_OWNER
        and d["attributes"].get("repositoryName") == REPO_NAME,
        "repositories",
    )
    if not repo:
        die("Xcode Cloud cannot see %s/%s. Grant its GitHub app access to that repository."
            % (REPO_OWNER, REPO_NAME))
    print("repository   " + repo["id"])

    xcode = find("/v1/ciXcodeVersions?limit=200",
                 lambda d: d["attributes"].get("name") == XCODE_VERSION_NAME, "Xcode versions")
    macos = find("/v1/ciMacOsVersions?limit=200",
                 lambda d: d["attributes"].get("name") == MACOS_VERSION_NAME, "macOS versions")
    if not xcode:
        die("Xcode version '%s' is not offered by Xcode Cloud" % XCODE_VERSION_NAME)
    if not macos:
        die("macOS version '%s' is not offered by Xcode Cloud" % MACOS_VERSION_NAME)
    print("xcode        %s (%s)" % (xcode["id"], XCODE_VERSION_NAME))
    print("macos        %s (%s)" % (macos["id"], MACOS_VERSION_NAME))

    attributes = {
        "name": WORKFLOW_NAME,
        "description": "Build the .NET MAUI iOS app and send it to TestFlight.",
        "isEnabled": True,
        "isLockedForEditing": False,
        "clean": False,
        "containerFilePath": CONTAINER_FILE_PATH,
        "branchStartCondition": {
            "source": {"isAllMatch": False,
                       "patterns": [{"pattern": BRANCH, "isPrefix": False}]},
            "autoCancel": True,
        },
        "actions": [
            {
                "name": "Archive iOS",
                "actionType": "ARCHIVE",
                "platform": "IOS",
                "scheme": SCHEME,
                # What makes Xcode Cloud hand the archive to TestFlight internal testers.
                "buildDistributionAudience": "INTERNAL_ONLY",
                "isRequiredToPass": True,
                "destination": None,
                "testConfiguration": None,
            }
        ],
    }
    relationships = {
        "product": {"data": {"type": "ciProducts", "id": product["id"]}},
        "repository": {"data": {"type": "scmRepositories", "id": repo["id"]}},
        "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": xcode["id"]}},
        "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": macos["id"]}},
    }

    existing = find(
        "/v1/ciProducts/%s/workflows?limit=200" % product["id"],
        lambda d: d["attributes"].get("name") == WORKFLOW_NAME,
        "workflows",
    )

    if existing:
        status, body = call(
            "/v1/ciWorkflows/" + existing["id"],
            "PATCH",
            {"data": {"type": "ciWorkflows", "id": existing["id"], "attributes": attributes}},
        )
        if status not in (200, 204):
            die("could not update the workflow", body)
        workflow_id = existing["id"]
        print("updated workflow " + workflow_id)
    else:
        status, body = call(
            "/v1/ciWorkflows",
            "POST",
            {"data": {"type": "ciWorkflows", "attributes": attributes,
                      "relationships": relationships}},
        )
        if status not in (200, 201):
            die("could not create the workflow", body)
        workflow_id = body["data"]["id"]
        print("created workflow " + workflow_id)

    if args.start_build:
        status, body = call(
            "/v1/ciBuildRuns",
            "POST",
            {"data": {"type": "ciBuildRuns",
                      "relationships": {"workflow": {"data": {"type": "ciWorkflows",
                                                              "id": workflow_id}}}}},
        )
        if status not in (200, 201):
            die("could not start a build", body)
        run = body["data"]
        print("started build number %s (%s)"
              % (run["attributes"].get("number"), run["id"]))


if __name__ == "__main__":
    main()
