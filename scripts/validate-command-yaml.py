#!/usr/bin/env python3
"""
Comprehensive command validation script that checks both YAML frontmatter and content.
Validates commands against the new template format with required 'description' field
and optional 'argument-hint' field as defined in docs/commands/COMMAND_TEMPLATE.md.
"""

import os
import re
import sys
import yaml
from pathlib import Path
from typing import Dict, List, Optional, Any

def find_commands_dir() -> Path:
    """Find the commands directory."""
    current = Path.cwd()

    # Look for system-configs/.claude/commands
    for parent in [current] + list(current.parents):
        commands_dir = parent / 'system-configs' / '.claude' / 'commands'
        if commands_dir.exists():
            return commands_dir

    raise FileNotFoundError("Could not find system-configs/.claude/commands directory")


def extract_frontmatter(content: str) -> tuple[Optional[Dict[str, Any]], str]:
    """Extract YAML frontmatter from markdown content."""
    if not content.startswith('---\n') and not content.startswith('---\r\n'):
        return None, content

    # Find the end of frontmatter (handle different line endings)
    lines = content.split('\n')
    if len(lines) < 3:
        return None, content

    start_idx = 1  # Skip first ---
    end_idx = None

    for i in range(start_idx, len(lines)):
        if lines[i].strip() == '---':
            end_idx = i
            break

    if end_idx is None:
        return None, content

    yaml_lines = lines[start_idx:end_idx]
    yaml_content = '\n'.join(yaml_lines)
    markdown_lines = lines[end_idx + 1:]
    markdown_content = '\n'.join(markdown_lines)

    try:
        frontmatter = yaml.safe_load(yaml_content)
        return frontmatter, markdown_content
    except yaml.YAMLError as e:
        # For debugging, return the parsing error with context
        return {
            '_yaml_error': str(e),
            '_yaml_content': yaml_content
        }, markdown_content


def validate_command_yaml(file_path: Path) -> Dict[str, Any]:
    """Validate a command file's YAML frontmatter and content."""
    command_name = file_path.stem

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        return {
            'command': command_name,
            'valid': False,
            'errors': [f'File read error: {e}'],
            'warnings': [],
            'has_frontmatter': False
        }

    frontmatter, markdown_content = extract_frontmatter(content)

    errors = []
    warnings = []
    has_frontmatter = frontmatter is not None

    if not has_frontmatter:
        warnings.append('Uses legacy format (no YAML frontmatter)')
        return {
            'command': command_name,
            'valid': True,  # Legacy format is still valid
            'errors': errors,
            'warnings': warnings,
            'has_frontmatter': False,
            'frontmatter': {}
        }

    # Handle YAML parsing errors
    if isinstance(frontmatter, dict) and '_yaml_error' in frontmatter:
        yaml_error = frontmatter['_yaml_error']
        yaml_content = frontmatter.get('_yaml_content', '')
        errors.append(f'YAML parsing error: {yaml_error}')

        # Try to extract values manually for common cases
        try:
            # Simple regex extraction for description and argument-hint
            desc_match = re.search(r'description:\s*(.+)', yaml_content)
            arg_match = re.search(r'argument-hint:\s*(.+)', yaml_content)

            extracted = {}
            if desc_match:
                extracted['description'] = desc_match.group(1).strip()
            if arg_match:
                extracted['argument-hint'] = arg_match.group(1).strip()

            frontmatter = extracted
            warnings.append('YAML values extracted with regex fallback - consider proper YAML quoting')
        except:
            frontmatter = {}

    # Validate required fields
    if not isinstance(frontmatter, dict):
        errors.append('Frontmatter must be a YAML object')
        frontmatter = {}

    # Required: description field
    if 'description' not in frontmatter:
        errors.append("Missing required 'description' field")
    else:
        description = frontmatter['description']
        if not description or not isinstance(description, str):
            errors.append('Description field cannot be empty')
        elif len(description) > 60:
            warnings.append(f'Description too long ({len(description)} > 60 chars) - consider shortening for better UX')

    # Optional: argument-hint field
    if 'argument-hint' in frontmatter:
        arg_hint = frontmatter['argument-hint']
        if arg_hint and isinstance(arg_hint, str):
            # Should use square brackets for argument placeholders
            if not re.match(r'^\[.*\]$', arg_hint):
                warnings.append('Argument hint should use square brackets format (e.g., [file-path])')
        elif arg_hint == '':
            # Empty string is fine - means no arguments
            pass
        elif arg_hint is not None:
            warnings.append('Argument hint should be a string or null')

    # Optional: allowed-tools field
    if 'allowed-tools' in frontmatter:
        allowed_tools = frontmatter['allowed-tools']
        if allowed_tools is not None and not isinstance(allowed_tools, (str, list)):
            warnings.append('Allowed-tools should be a string or array')

    # Optional: model field
    if 'model' in frontmatter:
        model = frontmatter['model']
        if model and isinstance(model, str):
            # Should be a valid Claude model identifier
            if not re.match(r'^claude-sonnet|^claude-haiku|^claude-opus', model):
                warnings.append('Model should specify a valid Claude model identifier')
        elif model is not None:
            warnings.append('Model should be a string')

    # Content validation
    if not markdown_content.strip():
        errors.append('Command content cannot be empty')

    return {
        'command': command_name,
        'valid': len(errors) == 0,
        'errors': errors,
        'warnings': warnings,
        'has_frontmatter': has_frontmatter,
        'frontmatter': frontmatter
    }


def print_validation_report(results: List[Dict[str, Any]]):
    """Print a formatted validation report."""
    print("\n" + "="*80)
    print("COMMAND YAML VALIDATION REPORT")
    print("="*80)

    # Summary statistics
    total_commands = len(results)
    valid_commands = sum(1 for r in results if r['valid'])
    commands_with_frontmatter = sum(1 for r in results if r['has_frontmatter'])
    commands_with_errors = sum(1 for r in results if r['errors'])
    commands_with_warnings = sum(1 for r in results if r['warnings'])

    print(f"\n📊 SUMMARY")
    print(f"   Total Commands: {total_commands}")
    print(f"   Valid Commands: {valid_commands}/{total_commands} ({valid_commands/total_commands*100:.1f}%)")
    print(f"   Commands with YAML Frontmatter: {commands_with_frontmatter}/{total_commands} ({commands_with_frontmatter/total_commands*100:.1f}%)")
    print(f"   Commands with Errors: {commands_with_errors}")
    print(f"   Commands with Warnings: {commands_with_warnings}")

    # Grade calculation
    success_rate = valid_commands / total_commands
    if success_rate >= 0.95:
        grade = "A"
    elif success_rate >= 0.85:
        grade = "B"
    elif success_rate >= 0.75:
        grade = "C"
    elif success_rate >= 0.65:
        grade = "D"
    else:
        grade = "F"

    print(f"\n   📈 VALIDATION GRADE: {grade} ({success_rate*100:.1f}%)")

    # Detailed results
    print(f"\n📋 DETAILED RESULTS")
    print("-"*80)

    for result in sorted(results, key=lambda x: x['command']):
        status = "✅" if result['valid'] else "❌"
        frontmatter_status = "📄" if result['has_frontmatter'] else "📜"

        print(f"{status} /{result['command']:20} {frontmatter_status}")

        for error in result['errors']:
            print(f"    ❌ {error}")

        for warning in result['warnings']:
            print(f"    ⚠️  {warning}")

    # Migration recommendations
    legacy_commands = [r for r in results if not r['has_frontmatter']]
    if legacy_commands:
        print(f"\n💡 MIGRATION RECOMMENDATIONS")
        print("-"*80)
        print(f"\n{len(legacy_commands)} commands use legacy format and should be migrated:")
        for r in legacy_commands:
            print(f"  - /{r['command']}")
        print(f"\nUse docs/commands/COMMAND_TEMPLATE.md as migration guide")

    print("\n" + "="*80)


def main():
    """Main validation function."""
    try:
        commands_dir = find_commands_dir()
        print(f"Found commands directory: {commands_dir}")

        # Validate all command files
        results = []
        for cmd_file in sorted(commands_dir.glob("*.md")):
            if cmd_file.stem not in ['README', 'TEMPLATE']:
                result = validate_command_yaml(cmd_file)
                results.append(result)

        # Print report
        print_validation_report(results)

        # Save detailed results to JSON
        output_dir = Path.cwd() / '.tmp'
        output_dir.mkdir(exist_ok=True)
        output_file = output_dir / 'command_yaml_validation_results.json'

        with open(output_file, 'w') as f:
            import json
            json.dump(results, f, indent=2)

        print(f"\nDetailed results saved to: {output_file}")

        # Exit with error if any commands are invalid
        invalid_commands = [r for r in results if not r['valid']]
        if invalid_commands:
            print(f"\n❌ {len(invalid_commands)} commands have validation errors")
            sys.exit(1)
        else:
            print(f"\n✅ All {len(results)} commands passed validation")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
