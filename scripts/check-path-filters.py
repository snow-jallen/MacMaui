#!/usr/bin/env python3
"""Fail if .github/path-filters.yml no longer covers the real project references.

Path filters that say "build when these folders change" have one dangerous failure mode: add
a project, forget the filter, and builds quietly stop happening. Nothing errors, the pipeline
just goes silent. This guard removes that risk by deriving the answer from the csproj files
and comparing it to the filters, so the drift fails a build instead of hiding.

Run with no arguments from the repository root; the release workflow runs it on every build.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILTERS = os.path.join(REPO, ".github", "path-filters.yml")

# Which project each pipeline area builds. The transitive references are worked out below.
AREA_ROOTS = {
    "api": ["MacMaui.ApiService"],
    "maui": ["MacMaui.Mobile"],
}


def project_references():
    """Map every project name to the projects it references directly."""
    refs = {}
    for entry in sorted(os.listdir(REPO)):
        directory = os.path.join(REPO, entry)
        if not os.path.isdir(directory):
            continue
        csproj = os.path.join(directory, entry + ".csproj")
        if not os.path.isfile(csproj):
            continue
        with open(csproj, encoding="utf-8-sig") as handle:
            text = handle.read()
        deps = []
        for include in re.findall(r'ProjectReference\s+Include="([^"]+)"', text):
            name = os.path.basename(include.replace("\\", "/"))
            deps.append(os.path.splitext(name)[0])
        refs[entry] = deps
    return refs


def closure(refs, roots):
    """Every project the roots depend on, including the roots themselves."""
    seen, stack = set(roots), list(roots)
    while stack:
        for dep in refs.get(stack.pop(), []):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


def configured_directories():
    """Parse the filter file into {area: {directory, ...}} without needing PyYAML.

    The file is a deliberately simple mapping of area to a list of quoted globs, so a few
    lines of parsing here avoid making the guard depend on a package being installed.
    """
    areas, current = {}, None
    with open(FILTERS, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            if not line.startswith((" ", "\t", "-")) and line.rstrip().endswith(":"):
                current = line.strip()[:-1]
                areas[current] = set()
            elif current is not None and line.strip().startswith("-"):
                pattern = line.strip().lstrip("-").strip().strip("'\"")
                if pattern.startswith("!") or not pattern.endswith("/**"):
                    continue  # exclusions and single files are not directory coverage
                areas[current].add(pattern[: -len("/**")])
    return areas


def main():
    refs = project_references()
    if not refs:
        print("error: found no projects; run this from the repository root", file=sys.stderr)
        return 1
    configured = configured_directories()

    problems = []
    for area, roots in AREA_ROOTS.items():
        missing_roots = [r for r in roots if r not in refs]
        if missing_roots:
            problems.append("area '%s' names projects that do not exist: %s"
                            % (area, ", ".join(missing_roots)))
            continue
        required = closure(refs, roots)
        covered = configured.get(area)
        if covered is None:
            problems.append("area '%s' is missing from %s" % (area, FILTERS))
            continue
        for project in sorted(required - covered):
            problems.append(
                "area '%s' builds %s but the filter does not list it. Add \"%s/**\" to the "
                "'%s' list in .github/path-filters.yml, or pushes that change it will not "
                "trigger a build." % (area, project, project, area))
        for extra in sorted(covered - required):
            if extra in refs:
                problems.append(
                    "area '%s' lists %s, which nothing in that area references any more. "
                    "Remove it so the filter stays honest." % (area, extra))

    for area, roots in AREA_ROOTS.items():
        if area in configured:
            print("%-5s covers: %s" % (area, ", ".join(sorted(closure(refs, roots)))))

    if problems:
        print("\npath filters are out of date:", file=sys.stderr)
        for problem in problems:
            print("  - " + problem, file=sys.stderr)
        return 1
    print("\npath filters match the project references.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
