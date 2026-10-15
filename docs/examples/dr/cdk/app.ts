// Starter for dr-check-cdk.yml (issue #94): register cdk-nag's NIST 800-53
// rev 5 pack only when CDK_NAG=1, so local `cdk synth` stays quiet and CI
// gets cdk.out/validation-report.json. Needs cdk-nag 3 (aws-cdk-lib 2.2xx).
import { App, Validations } from 'aws-cdk-lib';
import { NIST80053R5Checks } from 'cdk-nag';
import { DataStack } from '../lib/data-stack';

const app = new App();
const data = new DataStack(app, 'Data');

// Acknowledge a finding next to the construct, with a reason a reviewer can
// check: the tier (docs/dr-checklist.md) or the security-exception issue.
Validations.of(data.cacheBucket).acknowledge({
  id: 'NIST.800.53.R5::NIST.800.53.R5-S3BucketVersioningEnabled',
  reason: 'Tier C: cache objects are rebuilt from the source bucket on a miss',
});

if (process.env.CDK_NAG === '1') {
  Validations.of(app).addPlugins(new NIST80053R5Checks(app));
}
