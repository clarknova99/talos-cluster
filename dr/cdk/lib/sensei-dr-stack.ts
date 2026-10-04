import * as path from 'path';
import { CfnOutput, Duration, RemovalPolicy, SecretValue, Stack, StackProps } from 'aws-cdk-lib';
import * as autoscaling from 'aws-cdk-lib/aws-autoscaling';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cwActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subs from 'aws-cdk-lib/aws-sns-subscriptions';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

export interface SenseiDrProps extends StackProps {
  domain: string;
  alertEmail?: string;
  instanceTypes: string[];
  dataVolumeGiB: number;
  failoverHosts: string[];
  drillHost: string;
  gitUrl: string;
  fluxVersion: string;
}

/**
 * Cold-standby DR for senseichess.com. Nothing runs while idle except a 1-minute orchestrator
 * Lambda; the ASG (0..1) is scaled by the orchestrator. See ../../PLAN.md.
 *
 * Secrets `sensei-dr/age-key` and `sensei-dr/cloudflare` are created out of band
 * (dr/bin/setup-secrets.sh) so their values never appear in CloudFormation.
 */
export class SenseiDrStack extends Stack {
  constructor(scope: Construct, id: string, props: SenseiDrProps) {
    super(scope, id, props);

    const table = new dynamodb.Table(this, 'State', {
      tableName: 'sensei-dr',
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const ageSecret = secretsmanager.Secret.fromSecretNameV2(this, 'AgeKey', 'sensei-dr/age-key');
    const cfSecret = secretsmanager.Secret.fromSecretNameV2(this, 'Cloudflare', 'sensei-dr/cloudflare');
    const cnpgBucket = s3.Bucket.fromBucketName(this, 'CnpgBucket', 'sensei-cnpg');

    const topic = new sns.Topic(this, 'Alerts', { topicName: 'sensei-dr-alerts', displayName: 'sensei DR' });
    if (props.alertEmail) topic.addSubscription(new subs.EmailSubscription(props.alertEmail));

    new ssm.StringParameter(this, 'GitBranch', {
      parameterName: '/sensei-dr/git-branch',
      stringValue: 'main',
      description: 'Branch of talos-cluster the DR cluster syncs (kubernetes/dr/aws)',
    });
    new ssm.StringParameter(this, 'SourceServer', {
      parameterName: '/sensei-dr/source-server',
      stringValue: 'auto',
      description: 'CNPG serverName to restore from; "auto" = newest postgres16vector-v* WAL archive',
    });

    // ---- network: public subnets only, no inbound -------------------------------------------
    const vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr('10.88.0.0/16'),
      maxAzs: 3,
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });
    const sg = new ec2.SecurityGroup(this, 'InstanceSg', {
      vpc,
      description: 'sensei DR instance: egress only (cloudflared tunnel, SSM)',
      allowAllOutbound: true,
    });

    // ---- instance role ------------------------------------------------------------------------
    const role = new iam.Role(this, 'InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    table.grantReadWriteData(role);
    ageSecret.grantRead(role);
    cfSecret.grantRead(role);
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['ssm:GetParameter'],
      resources: [this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: 'sensei-dr/*' })],
    }));
    // CNPG (barman-cloud, inheritFromIAMRole): read the home archive, write only DR serverNames.
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:ListBucket', 's3:GetBucketLocation'],
      resources: [cnpgBucket.bucketArn],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: [cnpgBucket.arnForObjects('*')],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:PutObject', 's3:DeleteObject', 's3:AbortMultipartUpload'],
      resources: [cnpgBucket.arnForObjects('postgres16vector-dr-*')],
    }));

    // ---- instance bootstrap -------------------------------------------------------------------
    const assets = new s3assets.Asset(this, 'InstanceAssets', {
      path: path.join(__dirname, '..', 'assets', 'instance'),
    });
    assets.grantRead(role);

    const userData = ec2.UserData.forLinux();
    userData.addCommands('set -euxo pipefail', 'dnf install -y -q unzip jq');
    const zip = userData.addS3DownloadCommand({ bucket: assets.bucket, bucketKey: assets.s3ObjectKey });
    userData.addCommands(
      `mkdir -p /opt/sensei-dr && unzip -o ${zip} -d /opt/sensei-dr && chmod +x /opt/sensei-dr/*.sh`,
      `cat >/etc/sensei-dr.env <<'EOF'`,
      `AWS_REGION=${this.region}`,
      `DR_TABLE=${table.tableName}`,
      `AGE_SECRET=sensei-dr/age-key`,
      `CF_SECRET=sensei-dr/cloudflare`,
      `CNPG_BUCKET=${cnpgBucket.bucketName}`,
      `GIT_URL=${props.gitUrl}`,
      `FLUX_VERSION=${props.fluxVersion}`,
      'EOF',
      'cp /opt/sensei-dr/*.service /opt/sensei-dr/*.timer /etc/systemd/system/',
      'systemctl daemon-reload',
      'systemctl enable sensei-dr-bootstrap.service',
      'systemctl start --no-block sensei-dr-bootstrap.service',
    );

    const launchTemplate = new ec2.LaunchTemplate(this, 'LaunchTemplate', {
      launchTemplateName: 'sensei-dr',
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.X86_64 }),
      instanceType: new ec2.InstanceType(props.instanceTypes[0]),
      role,
      securityGroup: sg,
      userData,
      requireImdsv2: true,
      httpPutResponseHopLimit: 2, // pods (barman-cloud) use the instance role via IMDS
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(props.dataVolumeGiB, {
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          iops: 6000,
          throughput: 500,
          encrypted: true,
          deleteOnTermination: true,
        }),
      }],
    });

    const group = new autoscaling.AutoScalingGroup(this, 'Asg', {
      autoScalingGroupName: 'sensei-dr',
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      minCapacity: 0,
      maxCapacity: 1,
      // desiredCapacity intentionally unset: the orchestrator owns it and deploys must not reset it.
      mixedInstancesPolicy: {
        launchTemplate,
        launchTemplateOverrides: props.instanceTypes.map((t) => ({ instanceType: new ec2.InstanceType(t) })),
        instancesDistribution: { onDemandPercentageAboveBaseCapacity: 100 },
      },
    });

    // ---- orchestrator -------------------------------------------------------------------------
    const fn = new lambda.Function(this, 'Orchestrator', {
      functionName: 'sensei-dr-orchestrator',
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'orchestrator'), {
        exclude: ['test_*.py', '__pycache__'],
      }),
      timeout: Duration.seconds(90),
      memorySize: 256,
      environment: {
        TABLE: table.tableName,
        ASG_NAME: group.autoScalingGroupName,
        TOPIC_ARN: topic.topicArn,
        CF_SECRET: 'sensei-dr/cloudflare',
        DOMAIN: props.domain,
        FAILOVER_HOSTS: JSON.stringify(props.failoverHosts),
        DRILL_HOST: props.drillHost,
        HEARTBEAT_TIMEOUT: '300',
        PROBE_FAILURES: '3',
        READY_TIMEOUT: '5400',
      },
    });
    table.grantReadWriteData(fn);
    cfSecret.grantRead(fn);
    topic.grantPublish(fn);
    fn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['autoscaling:DescribeAutoScalingGroups'],
      resources: ['*'],
    }));
    fn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['autoscaling:SetDesiredCapacity'],
      resources: [group.autoScalingGroupArn],
    }));

    new events.Rule(this, 'Tick', {
      schedule: events.Schedule.rate(Duration.minutes(1)),
      targets: [new targets.LambdaFunction(fn, { retryAttempts: 0 })],
    });

    const errors = new cloudwatch.Alarm(this, 'OrchestratorErrors', {
      alarmName: 'sensei-dr-orchestrator-errors',
      metric: fn.metricErrors({ period: Duration.minutes(5), statistic: 'Sum' }),
      threshold: 3,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    errors.addAlarmAction(new cwActions.SnsAction(topic));

    // ---- home heartbeat / guard credentials -----------------------------------------------------
    const homeUser = new iam.User(this, 'HomeUser', { userName: 'sensei-dr-home' });
    homeUser.addToPolicy(new iam.PolicyStatement({
      actions: ['dynamodb:UpdateItem', 'dynamodb:GetItem'],
      resources: [table.tableArn],
      conditions: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['home'] } },
    }));
    homeUser.addToPolicy(new iam.PolicyStatement({
      actions: ['dynamodb:GetItem'],
      resources: [table.tableArn],
      conditions: { 'ForAllValues:StringEquals': { 'dynamodb:LeadingKeys': ['dr'] } },
    }));
    const homeKey = new iam.AccessKey(this, 'HomeKey', { user: homeUser });
    const homeSecret = new secretsmanager.Secret(this, 'HomeCredentials', {
      secretName: 'sensei-dr/home-credentials',
      description: 'Access key for the home dr-guard CronJob (SOPS-encrypted into the repo)',
      secretObjectValue: {
        AWS_ACCESS_KEY_ID: SecretValue.unsafePlainText(homeKey.accessKeyId),
        AWS_SECRET_ACCESS_KEY: homeKey.secretAccessKey,
      },
    });

    new CfnOutput(this, 'TableName', { value: table.tableName });
    new CfnOutput(this, 'AsgName', { value: group.autoScalingGroupName });
    new CfnOutput(this, 'OrchestratorName', { value: fn.functionName });
    new CfnOutput(this, 'AlertTopic', { value: topic.topicArn });
    new CfnOutput(this, 'HomeCredentialsSecret', { value: homeSecret.secretName });
  }
}
