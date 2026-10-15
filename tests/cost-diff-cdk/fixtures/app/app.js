// Fixture CDK app for tests/cost-diff-cdk (issue #90). Synthesised in CI,
// never deployed. One top-level stack and one stack inside a Stage, so the
// synth layout covers both a plain template and a nested assembly.
const { App, Stack, Stage, RemovalPolicy } = require("aws-cdk-lib");
const ec2 = require("aws-cdk-lib/aws-ec2");
const s3 = require("aws-cdk-lib/aws-s3");

const app = new App();
const shared = new Stack(app, "Shared");
new s3.Bucket(shared, "Assets", { removalPolicy: RemovalPolicy.DESTROY });

const staging = new Stage(app, "Staging");
const compute = new Stack(staging, "Compute");
const vpc = new ec2.Vpc(compute, "Vpc", { maxAzs: 1, natGateways: 1 });
new ec2.Instance(compute, "Worker", {
  vpc,
  instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
  machineImage: ec2.MachineImage.latestAmazonLinux2023(),
});
