// Fixture CDK app for tests/dr-check-cdk (issue #94). Synthesised in CI,
// never deployed. Deliberate resilience gaps for cdk-nag's NIST 800-53 rev 5
// pack: a single-AZ RDS instance and a DynamoDB table outside any backup
// plan, a DynamoDB table without point-in-time recovery, and an unversioned
// S3 bucket. One bucket acknowledges its rules with a reason, one with a
// reason too short to explain anything.
const { App, Stack, Validations, RemovalPolicy } = require("aws-cdk-lib");
const dynamodb = require("aws-cdk-lib/aws-dynamodb");
const ec2 = require("aws-cdk-lib/aws-ec2");
const rds = require("aws-cdk-lib/aws-rds");
const s3 = require("aws-cdk-lib/aws-s3");
const { NIST80053R5Checks } = require("cdk-nag");

const app = new App();
const stack = new Stack(app, "DrFixture");

const vpc = new ec2.Vpc(stack, "Vpc", { maxAzs: 2, natGateways: 0 });
new rds.DatabaseInstance(stack, "Database", {
  engine: rds.DatabaseInstanceEngine.postgres({ version: rds.PostgresEngineVersion.VER_16 }),
  vpc,
  vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
  multiAz: false,
  removalPolicy: RemovalPolicy.DESTROY,
});
new dynamodb.Table(stack, "Orders", {
  partitionKey: { name: "id", type: dynamodb.AttributeType.STRING },
  removalPolicy: RemovalPolicy.DESTROY,
});
new s3.Bucket(stack, "Uploads", { removalPolicy: RemovalPolicy.DESTROY });

const scratch = new s3.Bucket(stack, "Scratch", { removalPolicy: RemovalPolicy.DESTROY });
Validations.of(scratch).acknowledge({
  id: "NIST.800.53.R5::NIST.800.53.R5-S3BucketVersioningEnabled",
  reason: "Scratch space for build intermediates; objects are regenerated on every run.",
});
const cache = new s3.Bucket(stack, "Cache", { removalPolicy: RemovalPolicy.DESTROY });
Validations.of(cache).acknowledge({ id: "NIST.800.53.R5::NIST.800.53.R5-S3BucketVersioningEnabled", reason: "ok" });

// The integration pattern documented in docs/examples/dr/cdk: on only when CDK_NAG=1.
if (process.env.CDK_NAG === "1") {
  Validations.of(app).addPlugins(new NIST80053R5Checks(app));
}
