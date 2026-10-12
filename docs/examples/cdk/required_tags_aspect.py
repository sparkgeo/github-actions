"""RequiredTagsAspect: fail synth when a taggable resource lacks a Sparkgeo
required tag or uses a value outside the standard (policies/tags/standard.yml,
issue #114). Copy this file into the CDK app and apply it to every stack:

    from required_tags_aspect import RequiredTagsAspect
    RequiredTagsAspect.apply(stack)

Tags added with Tags.of(scope).add(...) are applied by CDK's own aspects; this
aspect runs after them (READONLY priority) and reads the resolved tag set.
Token values (unresolved at synth time) are not validated.
"""

import re

import jsii
from aws_cdk import Annotations, AspectPriority, Aspects, CfnResource, IAspect, TagManager, Token
from constructs import IConstruct

REQUIRED = {
    "owner": {"pattern": r"^(team-[a-z0-9-]+|[a-z.]+@sparkgeo\.com)$"},
    "project": {"pattern": r"^[a-z0-9-]{3,40}$"},
    "environment": {"enum": ["dev", "staging", "prod", "shared"]},
    "data-class": {"enum": ["public", "internal", "confidential", "restricted"]},
}


@jsii.implements(IAspect)
class RequiredTagsAspect:
    def __init__(self, required=None):
        self.required = required or REQUIRED

    @classmethod
    def apply(cls, scope, required=None):
        Aspects.of(scope).add(cls(required), priority=AspectPriority.READONLY)

    def visit(self, node: IConstruct) -> None:
        if not CfnResource.is_cfn_resource(node):
            return
        tags = getattr(node, "tags", None)
        if not isinstance(tags, TagManager) or not tags.tag_property_name:
            return
        values = tags.tag_values()
        for key, spec in self.required.items():
            if key not in values:
                Annotations.of(node).add_error(f'missing required tag "{key}"')
                continue
            value = values[key]
            if Token.is_unresolved(value):
                continue
            if "enum" in spec and value not in spec["enum"]:
                Annotations.of(node).add_error(
                    f'tag "{key}" is "{value}", expected one of {", ".join(spec["enum"])}')
            elif "pattern" in spec and not re.match(spec["pattern"], value):
                Annotations.of(node).add_error(f'tag "{key}" is "{value}", expected to match {spec["pattern"]}')
