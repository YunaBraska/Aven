from pathlib import Path
import sys

import yaml


def validate(root: Path) -> list[str]:
    failures: list[str] = []
    for entrypoint in sorted(root.glob("*/SKILL.md")):
        text = entrypoint.read_text(encoding="utf-8")
        if "TODO" in text or "[TODO" in text:
            failures.append(f"{entrypoint}: unfinished scaffold text")
            continue
        if not text.startswith("---\n"):
            failures.append(f"{entrypoint}: missing YAML frontmatter")
            continue
        try:
            _, raw_frontmatter, _ = text.split("---", 2)
            frontmatter = yaml.safe_load(raw_frontmatter)
        except (ValueError, yaml.YAMLError) as error:
            failures.append(f"{entrypoint}: invalid YAML: {error}")
            continue
        if not isinstance(frontmatter, dict):
            failures.append(f"{entrypoint}: frontmatter must be a mapping")
            continue
        if frontmatter.get("name") != entrypoint.parent.name:
            failures.append(f"{entrypoint}: name must match its directory")
        description = frontmatter.get("description")
        if not isinstance(description, str) or not description.strip():
            failures.append(f"{entrypoint}: description is required")
        metadata = entrypoint.parent / "agents" / "openai.yaml"
        if metadata.exists():
            try:
                parsed = yaml.safe_load(metadata.read_text(encoding="utf-8"))
            except yaml.YAMLError as error:
                failures.append(f"{metadata}: invalid YAML: {error}")
                continue
            if not isinstance(parsed, dict) or not isinstance(parsed.get("interface"), dict):
                failures.append(f"{metadata}: interface metadata is required")
    return failures


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("usage: validate_skills.py <skills-directory>", file=sys.stderr)
        return 2
    root = Path(arguments[1])
    failures = validate(root)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Validated {len(list(root.glob('*/SKILL.md')))} bundled skills")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
