#!/usr/bin/env python3
"""Synthesises one tagged and one untagged stack through RequiredTagsAspect
and asserts the annotations. Needs aws-cdk-lib; run by tests/tagging/run.sh."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "docs" / "examples" / "cdk"))

import aws_cdk as cdk  # noqa: E402
from aws_cdk import aws_s3 as s3  # noqa: E402
from aws_cdk.assertions import Annotations, Match  # noqa: E402
from required_tags_aspect import RequiredTagsAspect  # noqa: E402

app = cdk.App()

tagged = cdk.Stack(app, "Tagged")
s3.Bucket(tagged, "Assets")
for k, v in {"owner": "team-platform", "project": "fixture", "environment": "dev", "data-class": "internal", "exposure": "internal"}.items():
    cdk.Tags.of(tagged).add(k, v)
RequiredTagsAspect.apply(tagged)

untagged = cdk.Stack(app, "Untagged")
s3.Bucket(untagged, "Assets")
cdk.Tags.of(untagged).add("owner", "team-platform")
cdk.Tags.of(untagged).add("environment", "production")
RequiredTagsAspect.apply(untagged)

Annotations.from_stack(tagged).has_no_error("*", Match.any_value())
errors = [f"{e.id}: {e.entry.data}" for e in Annotations.from_stack(untagged).find_error("*", Match.any_value())]
want = [
    '/Untagged/Assets/Resource: missing required tag "project"',
    '/Untagged/Assets/Resource: missing required tag "data-class"',
    '/Untagged/Assets/Resource: missing required tag "exposure"',
    '/Untagged/Assets/Resource: tag "environment" is "production", expected one of dev, staging, prod, shared',
]
if sorted(errors) != sorted(want):
    print("unexpected annotations:\n" + "\n".join(errors))
    sys.exit(1)
print("cdk aspect: tagged stack clean, untagged stack has 4 errors")
