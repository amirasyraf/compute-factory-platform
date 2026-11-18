"""Validate and normalize the desired VM spec; JSON stdin/stdout, no dependencies."""
import json
import re
import sys
from pathlib import Path

# Each platform directory's platform.json (OSes, instance-type rules, reserved tags) and sizes.json
# (size -> instance type) are the single source of truth, also read by Terraform and the IDP.
PLATFORMS_DIR = Path(__file__).resolve().parent.parent / "terraform/platforms"


def platform(name):
    if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]{1,20}", name):
        raise ValueError("Unsupported compute platform or OS")
    try:
        config = json.loads((PLATFORMS_DIR / name / "platform.json").read_text())
        config["sizes"] = json.loads((PLATFORMS_DIR / name / "sizes.json").read_text())
    except FileNotFoundError:
        raise ValueError("Unsupported compute platform or OS") from None
    return config


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
    config = platform(compute["platform"])
    if compute["os"] not in config["os"]:
        raise ValueError("Unsupported compute platform or OS")
    # Exactly one of a platform size or an explicit instance type (advanced picker).
    if ("size" in compute) == ("instanceType" in compute):
        raise ValueError("Specify exactly one of compute.size or compute.instanceType")
    if "size" in compute and compute["size"] not in config["sizes"]:
        raise ValueError("Unsupported size")
    excluded = config.get("excludedInstanceTypePattern")
    if "instanceType" in compute and (
        not isinstance(compute["instanceType"], str)
        or not re.fullmatch(config["instanceTypePattern"].removeprefix("^").removesuffix("$"), compute["instanceType"])
        or (excluded and re.match(excluded, compute["instanceType"]))
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
    reserved = ("cf:", "billing:", *config["reservedTagPrefixes"])
    for key, value in tags.items():
        text(key, 128)
        # Reserve policy, identity and billing tags; arbitrary user tags cannot override them.
        if key.lower() in ("name", "cost_center", "project_code") or key.lower().startswith(reserved):
            raise ValueError("Reserved cloud tag")
        if any(char in config.get("forbiddenTagKeyCharacters", "") for char in key):
            raise ValueError("Tag key contains a character the platform does not allow")
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
