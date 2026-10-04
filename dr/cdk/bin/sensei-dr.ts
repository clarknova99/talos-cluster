#!/usr/bin/env node
import { App } from 'aws-cdk-lib';
import { SenseiDrStack } from '../lib/sensei-dr-stack';

const app = new App();
const ctx = (k: string) => app.node.tryGetContext(k);

new SenseiDrStack(app, 'SenseiDr', {
  env: { account: ctx('account'), region: ctx('region') },
  description: 'senseichess.com AWS disaster recovery (talos-cluster dr/PLAN.md)',
  domain: ctx('domain'),
  alertEmail: ctx('alertEmail'),
  instanceTypes: ctx('instanceTypes'),
  dataVolumeGiB: ctx('dataVolumeGiB'),
  failoverHosts: ctx('failoverHosts'),
  drillHost: ctx('drillHost'),
  gitUrl: ctx('gitUrl'),
  fluxVersion: ctx('fluxVersion'),
});
