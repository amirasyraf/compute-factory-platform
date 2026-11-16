"""Validate and normalize the desired VM spec; JSON stdin/stdout, no dependencies."""
import json
import re
import sys
from pathlib import Path

# The platform's size map (also read by Terraform and the IDP); sizes are its keys.
SIZES = json.loads((Path(__file__).resolve().parent.parent / "terraform/platforms/aws/sizes.json").read_text())


def fields(value, allowed, required=()):
    if not isinstance(value, dict):
        raise ValueError("Expected an object")
    if set(value) - set(allowed) or set(required) - set(value):
        raise ValueError("Unsupported or missing fields")


def text(value, limit=256):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError("Expected a non-empty bounded string")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Control characters are not allowed")
    return value


def normalize(spec):
    fields(spec, ["type", "owner", "lifecycle", "compute", "configuration", "billing", "cloudTags"],
           ["type", "owner", "compute"])
    if spec["type"] != "vm":
        raise ValueError("spec.type must be vm")
    owner = text(spec["owner"], 100).lower()
    if owner.startswith("group:default/"):
        owner = owner[len("group:default/"):]
    if not re.fullmatch(r"[a-z][a-z0-9-]*", owner):
        raise ValueError("Owner must be a default-namespace group")
    compute = spec["compute"]
    fields(compute, ["platform", "os", "size", "instanceType"], ["platform", "os"])
    if compute["platform"] != "aws" or compute["os"] != "ubuntu":
        raise ValueError("Unsupported compute platform or OS")
    # Exactly one of a platform size or an explicit EC2 instance type (advanced picker).
    if ("size" in compute) == ("instanceType" in compute):
        raise ValueError("Specify exactly one of compute.size or compute.instanceType")
    if "size" in compute and compute["size"] not in SIZES:
        raise ValueError("Unsupported size")
    if "instanceType" in compute and (
        not isinstance(compute["instanceType"], str)
        or not re.fullmatch(r"[a-z][a-z0-9-]*\.[a-z0-9]+", compute["instanceType"])
        or compute["instanceType"].startswith("mac")
    ):
        raise ValueError("Unsupported instance type")
    configuration = spec.get("configuration", {})
    fields(configuration, ["software", "adJoin"])
    software = configuration.get("software", [])
    if not isinstance(software, list) or not all(isinstance(item, str) for item in software):
        raise ValueError("software must be a string list")
    if len(set(software)) != len(software) or any(item not in ("git", "htop", "nginx", "docker") for item in software):
        raise ValueError("Duplicate or unsupported software")
    ad_join = configuration.get("adJoin", False)
    if not isinstance(ad_join, bool):
        raise ValueError("adJoin must be a boolean")
    billing = spec.get("billing", {})
    fields(billing, ["costCenter", "projectCode"])
    for value in billing.values():
        text(value)
    tags = spec.get("cloudTags", {})
    if not isinstance(tags, dict) or len(tags) > 40:
        raise ValueError("cloudTags must be an object with at most 40 entries")
    for key, value in tags.items():
        text(key, 128)
        # Reserve policy, identity and billing tags; arbitrary user tags cannot override them.
        if key.lower() in ("name", "cost_center", "project_code") or key.lower().startswith(("cf:", "aws:", "billing:")):
            raise ValueError("Reserved cloud tag")
        if not isinstance(value, str) or len(value) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("Tag values must be bounded strings without control characters")
    return {
        "type": "vm", "owner": f"group:default/{owner}",
        "lifecycle": text(spec.get("lifecycle", "poc"), 32),
        "compute": compute,
        "configuration": {"software": software, "adJoin": ad_join},
        "billing": billing, "cloudTags": tags,
    }


if __name__ == "__main__":
    try:
        raw = sys.stdin.read(32769)
        if len(raw) > 32768:
            raise ValueError("Spec exceeds 32 KiB")
        print(json.dumps(normalize(json.loads(raw)), separators=(",", ":")))
    except (ValueError, TypeError, KeyError) as error:
        sys.exit(f"Invalid VM spec: {error}")
