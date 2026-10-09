#!/usr/bin/env python3
import hashlib
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "HermesMobile.xcodeproj/project.pbxproj"
SCHEME = ROOT / "HermesMobile.xcodeproj/xcshareddata/xcschemes/HermesMobile.xcscheme"
OUTPUT = ROOT / "Tests/ProjectStructure/fixtures/pre-watch-project.json"


def load_project():
    converted = subprocess.run(
        ["plutil", "-convert", "xml1", "-o", "-", str(PROJECT)],
        check=True,
        capture_output=True,
    ).stdout
    return plistlib.loads(converted)


def capture():
    project = load_project()
    objects = project["objects"]
    root = objects[project["rootObject"]]
    targets = []
    for target_id in root["targets"]:
        target = objects[target_id]
        config_list = objects[target["buildConfigurationList"]]
        phases = []
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            phases.append({
                "id": phase_id,
                "isa": phase["isa"],
                "files": phase.get("files", []),
                "dstPath": phase.get("dstPath"),
                "dstSubfolderSpec": phase.get("dstSubfolderSpec"),
                "name": phase.get("name"),
            })
        targets.append({
            "id": target_id,
            "name": target["name"],
            "productType": target["productType"],
            "productReference": target["productReference"],
            "buildConfigurationList": target["buildConfigurationList"],
            "configurations": [
                {
                    "id": config_id,
                    "name": objects[config_id]["name"],
                    "baseConfigurationReference": objects[config_id].get("baseConfigurationReference"),
                    "buildSettings": objects[config_id]["buildSettings"],
                }
                for config_id in config_list["buildConfigurations"]
            ],
            "phases": phases,
            "dependencies": target.get("dependencies", []),
            "packageProductDependencies": target.get("packageProductDependencies", []),
        })
    return {
        "scheme_sha256": hashlib.sha256(SCHEME.read_bytes()).hexdigest(),
        "target_ids": root["targets"],
        "targets": targets,
        "main_group_children": objects[root["mainGroup"]]["children"],
        "product_group_children": objects[root["productRefGroup"]]["children"],
        "package_references": root.get("packageReferences", []),
    }


OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(json.dumps(capture(), indent=2, sort_keys=True) + "\n")
