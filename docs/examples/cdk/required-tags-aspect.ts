// RequiredTagsAspect: fail synth when a taggable resource lacks a Sparkgeo
// required tag or uses a value outside the standard (policies/tags/standard.yml,
// issue #114). Copy into the CDK app and apply it to every stack:
//
//   import { RequiredTagsAspect } from './required-tags-aspect';
//   RequiredTagsAspect.apply(stack);
//
// Tags added with Tags.of(scope).add(...) are applied by CDK's own aspects;
// this aspect runs after them (READONLY priority) and reads the resolved tag
// set. Token values (unresolved at synth time) are not validated.
// Mirrors required_tags_aspect.py; the Python version is the one exercised in CI.

import { Annotations, AspectPriority, Aspects, CfnResource, IAspect, TagManager, Token } from 'aws-cdk-lib';
import { IConstruct } from 'constructs';

export type TagSpec = { pattern?: RegExp; enum?: string[] };

export const REQUIRED: Record<string, TagSpec> = {
  owner: { pattern: /^(team-[a-z0-9-]+|[a-z.]+@sparkgeo\.com)$/ },
  project: { pattern: /^[a-z0-9-]{3,40}$/ },
  environment: { enum: ['dev', 'staging', 'prod', 'shared'] },
  'data-class': { enum: ['public', 'internal', 'confidential', 'restricted'] },
  exposure: { enum: ['public', 'internal'] },
};

export class RequiredTagsAspect implements IAspect {
  static apply(scope: IConstruct, required: Record<string, TagSpec> = REQUIRED): void {
    Aspects.of(scope).add(new RequiredTagsAspect(required), { priority: AspectPriority.READONLY });
  }

  constructor(private readonly required: Record<string, TagSpec> = REQUIRED) {}

  visit(node: IConstruct): void {
    if (!CfnResource.isCfnResource(node)) return;
    const tags = (node as CfnResource & { tags?: TagManager }).tags;
    if (!(tags instanceof TagManager) || !tags.tagPropertyName) return;
    const values = tags.tagValues();
    for (const [key, spec] of Object.entries(this.required)) {
      if (!(key in values)) {
        Annotations.of(node).addError(`missing required tag "${key}"`);
        continue;
      }
      const value = values[key];
      if (Token.isUnresolved(value)) continue;
      if (spec.enum && !spec.enum.includes(value)) {
        Annotations.of(node).addError(`tag "${key}" is "${value}", expected one of ${spec.enum.join(', ')}`);
      } else if (spec.pattern && !spec.pattern.test(value)) {
        Annotations.of(node).addError(`tag "${key}" is "${value}", expected to match ${spec.pattern.source}`);
      }
    }
  }
}
