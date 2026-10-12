# OIDC Trust Policies

GitHub Actions supports OIDC federation: workflows exchange a GitHub-signed identity token for a short-lived cloud credential. No static key is stored as a secret.

## Why OIDC over static credentials

| | Static key | OIDC |
|---|---|---|
| Expiry | Never (until manual rotation) | 1 hour max |
| Leak blast radius | Exploitable until rotated | Useless after job ends |
| Rotation burden | Manual | None |
| Audit trail | Secret name only | Full OIDC claims (repo, branch, run ID, actor) |

## AWS

### Composite action

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/aws-oidc-auth@<SHA>
        with:
          role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ca-central-1
      # AWS credentials are now available in the environment
      - run: aws sts get-caller-identity
```

The action enforces `role-session-name: {repo-name}-{run_id}`, making every CloudTrail event traceable to a specific run.

### IAM trust policy

Bind to a specific repo and branch — never the whole org:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:sparkgeo/REPO_NAME:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

**Scope conditions — from most to least restrictive:**

| Condition on `sub` | Allows |
|---|---|
| `repo:sparkgeo/app:ref:refs/heads/main` | Main branch only |
| `repo:sparkgeo/app:environment:production` | Any branch deploying to `production` environment |
| `repo:sparkgeo/app:ref:refs/heads/*` | Any branch (never use for production roles) |
| `repo:sparkgeo/*` | Any repo in org — avoid |

### Required AWS setup (one-time per account)

1. Create the OIDC provider in IAM:
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
   ```
   > **Thumbprints:** Since mid-2023 AWS validates the GitHub OIDC endpoint
   > against its own trusted CA store and **ignores** the thumbprint for
   > `token.actions.githubusercontent.com`, so rotation of GitHub's intermediate
   > certs no longer breaks federation. The value is still required at creation.
   > Both of GitHub's published thumbprints (rooted in DigiCert) are listed above
   > for completeness — supplying both survives a primary→secondary cert rotation
   > on any tooling that does still verify them.
2. Create the IAM role with the trust policy above.
3. Attach only the permissions the role needs (least privilege).
4. Store the role ARN as a repo/environment variable (not a secret — ARNs are not sensitive):
   ```
   AWS_DEPLOY_ROLE_ARN = arn:aws:iam::123456789012:role/sparkgeo-app-deploy
   ```

### Asset drift role (read-only)

`asset-drift.yml` (issue #117) assumes one role per account to read every taggable resource through the Resource Groups Tagging API. The role needs no write permission of any kind; attach this policy and the standard trust policy above, scoped to the repository that runs the drift schedule:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadTaggedResources",
      "Effect": "Allow",
      "Action": ["tag:GetResources", "tag:GetTagKeys", "tag:GetTagValues", "sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
```

`tag:GetResources` returns ARNs and tags only; the role cannot describe, list or modify the resources themselves. If a later query needs resource details (for example `aws_s3_bucket` for encryption state), add the matching `Describe*`/`Get*`/`List*` actions one at a time and record them here.

## GitHub environments and environment-scoped secrets

For production deployments, gate the job on a GitHub environment with protection rules:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production          # requires approver review before job runs
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: sparkgeo/github-actions/.github/actions/aws-oidc-auth@<SHA>
        with:
          role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}  # environment-scoped variable
          aws-region: ca-central-1
```

Environment configuration (Settings → Environments → production):
- Required reviewers: `@sparkgeo/platform-team`
- Deployment branches: `main` only
- Environment variables: `AWS_DEPLOY_ROLE_ARN` (prod ARN, different from staging)

**Secret scoping rule:**
- Org secrets: non-sensitive shared config only (`AWS_ACCOUNT_ID`, `SONAR_HOST_URL`)
- Environment secrets: sensitive values scoped to their environment — staging jobs cannot access production credentials

## Migration checklist

Use this when onboarding a repo from static credentials to OIDC:

```
[ ] Identify static AWS keys stored as repo/org secrets
[ ] Create IAM role with trust policy scoped to the specific repo + branch/environment
[ ] Set up GitHub environment protection rules for production roles
[ ] Replace static key usage with aws-oidc-auth composite action
[ ] Remove the static key secret from GitHub
[ ] Disable/delete the IAM user the key belonged to
[ ] Verify CloudTrail shows sts:AssumeRoleWithWebIdentity events (not IAM user events)
```
