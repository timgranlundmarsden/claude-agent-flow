#!/usr/bin/env python3
"""
Validate Backlog.md task structure before creation.

Usage:
    python validate_task.py --title "Task Title" --description "..." --plan "..." --priority high

Returns:
    Exit code 0 if valid
    Exit code 1 with error messages if invalid
"""

import argparse
import sys
import re


def validate_title(title):
    """Validate task title."""
    errors = []

    if not title or not title.strip():
        errors.append("Title is required")
        return errors

    if len(title) > 100:
        errors.append(f"Title too long ({len(title)} chars). Keep under 100 characters.")

    if len(title) < 10:
        errors.append(f"Title too short ({len(title)} chars). Be more descriptive (at least 10 characters).")

    # Check for vague words
    vague_words = ['fix', 'update', 'change', 'modify', 'improve', 'work on', 'add']
    title_lower = title.lower()
    if any(word in title_lower for word in vague_words) and len(title.split()) < 4:
        errors.append(f"Title may be too vague. Be more specific about what is being done.")

    return errors


def validate_description(description):
    """Validate task description."""
    errors = []

    if not description or not description.strip():
        errors.append("Description (-d) is required")
        return errors

    if len(description) < 50:
        errors.append(f"Description too short ({len(description)} chars). Provide more context (at least 50 characters).")

    # Check for related documents section
    if "## Related Documents" not in description:
        errors.append("Description should include '## Related Documents' section (even if empty, add '## Related Documents\\n(none)')")

    return errors


def validate_plan(plan):
    """Validate task plan."""
    errors = []

    if not plan or not plan.strip():
        errors.append("Plan (--plan) is required")
        return errors

    required_sections = [
        "Implementation background and purpose:",
        "Technical implementation approach:",
        "Required prerequisites:",
        "Expected deliverables:"
    ]

    for section in required_sections:
        if section not in plan:
            errors.append(f"Plan missing required section: '{section}'")

    if len(plan) < 100:
        errors.append(f"Plan too short ({len(plan)} chars). Provide detailed information for each section (at least 100 characters total).")

    return errors


def validate_priority(priority):
    """Validate priority level."""
    errors = []

    if not priority or not priority.strip():
        errors.append("Priority (--priority) is required")
        return errors

    valid_priorities = ['high', 'medium', 'low']
    if priority.lower() not in valid_priorities:
        errors.append(f"Priority must be one of: {', '.join(valid_priorities)} (got: {priority})")

    return errors


def estimate_task_size(title, description, plan):
    """Estimate if task might be too large."""
    warnings = []

    # Check for keywords suggesting large scope
    large_scope_words = [
        'complete', 'entire', 'full', 'comprehensive', 'all',
        'system', 'platform', 'infrastructure', 'framework'
    ]

    combined_text = f"{title} {description}".lower()
    large_words_found = [word for word in large_scope_words if word in combined_text]

    if len(large_words_found) >= 3:
        warnings.append(
            f"Task may be too large. Found words suggesting broad scope: {', '.join(large_words_found)}. "
            "Consider breaking down into smaller tasks."
        )

    # Check for multiple features mentioned
    feature_indicators = ['and', ',', 'plus', 'also', 'including']
    feature_count = sum(1 for indicator in feature_indicators if indicator in title.lower())

    if feature_count >= 2:
        warnings.append(
            "Title mentions multiple features. Consider creating separate tasks for each feature."
        )

    return warnings


def main():
    parser = argparse.ArgumentParser(description='Validate Backlog.md task structure')
    parser.add_argument('--title', required=True, help='Task title')
    parser.add_argument('--description', '-d', required=True, help='Task description')
    parser.add_argument('--plan', required=True, help='Task plan')
    parser.add_argument('--priority', required=True, help='Task priority')

    args = parser.parse_args()

    all_errors = []
    all_warnings = []

    # Validate each field
    all_errors.extend(validate_title(args.title))
    all_errors.extend(validate_description(args.description))
    all_errors.extend(validate_plan(args.plan))
    all_errors.extend(validate_priority(args.priority))

    # Estimate task size
    all_warnings.extend(estimate_task_size(args.title, args.description, args.plan))

    # Print results
    if all_errors:
        print("❌ VALIDATION FAILED")
        print("\nErrors:")
        for error in all_errors:
            print(f"  - {error}")

    if all_warnings:
        print("\n⚠️  WARNINGS:")
        for warning in all_warnings:
            print(f"  - {warning}")

    if not all_errors and not all_warnings:
        print("✅ VALIDATION PASSED")
        print("Task structure looks good!")

    # Exit with appropriate code
    sys.exit(1 if all_errors else 0)


if __name__ == '__main__':
    main()
