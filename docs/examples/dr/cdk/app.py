"""Starter for dr-check-cdk.yml (issue #94): register cdk-nag's NIST 800-53
rev 5 pack only when CDK_NAG=1, so local `cdk synth` stays quiet and CI gets
cdk.out/validation-report.json. Needs cdk-nag 3 (aws-cdk-lib 2.2xx); call the
workflow with runtime: python.
"""

import os

from aws_cdk import Acknowledgment, App, Validations
from cdk_nag import NIST80053R5Checks
from stacks.data_stack import DataStack

app = App()
data = DataStack(app, "Data")

# Acknowledge a finding next to the construct, with a reason a reviewer can
# check: the tier (docs/dr-checklist.md) or the security-exception issue.
Validations.of(data.cache_bucket).acknowledge(
    Acknowledgment(
        id="NIST.800.53.R5::NIST.800.53.R5-S3BucketVersioningEnabled",
        reason="Tier C: cache objects are rebuilt from the source bucket on a miss",
    )
)

if os.environ.get("CDK_NAG") == "1":
    Validations.of(app).add_plugins(NIST80053R5Checks(app))

app.synth()
