# senseichess.com: AWS cost and hardware comparison

Analysis from 2026-10-05, right after the first real failover to AWS (see [PLAN.md](PLAN.md),
[RUNBOOK.md](RUNBOOK.md)). Prices are AWS on-demand list prices for us-east-1; usage numbers are
live measurements from the home cluster (`kubectl top`) on that day.

## 1. What the DR runs actually cost


| Run               | When (UTC)             | Duration      | Instance    | Gross cost                                               |
| -------------------| ------------------------| ---------------| -------------| ----------------------------------------------------------|
| Test 1           | 2026-10-04 18:35–19:58 | 1 h 23 m      | m7i.2xlarge | **$0.68** (Cost Explorer: $0.56 EC2 + $0.12 EBS/network) |
| **Real failover** | 2026-10-05 00:13–15:27 | **15 h 13 m** | m7i.2xlarge | **≈ $8.80**                                              |
| Test 2           | 2026-10-05 16:03–16:23 | ~20 min       | m7i.2xlarge | ≈ $0.17                                                  |

Failover cost breakdown (from run time and list prices; Cost Explorer lags by up to 24 h):

| Item | Rate | 15.2 h |
|---|---|---|
| EC2 m7i.2xlarge on-demand | $0.403/h | $6.14 |
| EBS gp3 400 GB, 6000 IOPS, 500 MB/s | ~$0.085/h | $1.29 |
| Public IPv4 address | $0.005/h | $0.08 |
| Internet egress through the Cloudflare tunnel (≈13 GB of the 117 GB sent; the rest was backups/WAL to S3 in-region, which is free) | $0.09/GB | ≤ $1.20 |
| S3 storage and requests for DR backups and WAL | | ~$0.10 |
| Lambda, DynamoDB, SNS, Secrets Manager | | pennies |
| **Total** | **≈ $0.50/h** | **≈ $8.80** |

Rule of thumb: **serving the site from AWS costs ≈ $12 per day; a Test ≈ $0.20 now that restores
take ~20 min (was ≈ $0.70 with the old bzip2 backups).**

### Idle costs (no outage)

- Standby: **≈ $1.50–2 per month**: 3 Secrets Manager secrets ($1.20), the 1-minute orchestrator
  Lambda, DynamoDB on-demand, one CloudWatch alarm. No EC2 or EBS while idle.
- DR backup prefixes left in `s3://sensei-cnpg` after a failover: $0.023/GB-month (the two prefixes
  from 2026-10-04/05 were 137 GB ≈ $3.15/month). Delete them once home has its own base backup
  ([FAILBACK-CHECKLIST.md](FAILBACK-CHECKLIST.md) step 6).

## 2. Cost of a full-replica sensei stack on AWS

### What the sensei stack runs at home

| Component | Home replicas | Live CPU | Live memory |
|---|---|---|---|
| sensei-prod api / app / worker / admin | 3 / 3 / 4 / 1 | ~30m | 3.3 GiB |
| postgres16vector | 3 instances | ~1.07 cores | 3.3 GiB |
| ClickHouse (langfuse, dittofeed, rybbit) | 1 each | ~0.15 cores | 1.7 GiB |
| dragonfly | 3 | ~0.1 cores | 1.2 GiB |
| dittofeed + temporal, langfuse, litellm, rybbit | 1 each | ~0.1 cores | 3.5 GiB |
| **Total** | **26 pods** | **~1.5 cores** | **~12.7 GiB** |

Memory limits add up to about 56 GiB, mostly the three 8 GiB Postgres limits, which are never close
to reached. The stack is **memory-heavy and nearly idle on CPU**.

The DR instance today runs a reduced set on one node: 1 Postgres instance, api 2, app 1, worker 2.

### Sizing options

Matching home's replica counts *and* its resilience (three Postgres instances on separate machines)
needs three nodes.

| Option | Nodes | Total | $/hour | $/month always-on | 15 h outage |
|---|---|---|---|---|---|
| Today's DR (1 node, reduced replicas) | 1× m7i.2xlarge | 8 vCPU / 32 GiB | ~$0.49 | ~$360 | ~$7.50 |
| **Full replicas, best fit** | **3× r7i.xlarge** (memory-optimized) | 12 vCPU / 96 GiB | ~$0.87 | **~$640** | ~$13 |
| Full replicas, roomier | 3× m7i.2xlarge | 24 vCPU / 96 GiB | ~$1.28 | ~$935 | ~$19 |
| Full replicas, tight | 3× m7i.xlarge | 12 vCPU / 48 GiB | ~$0.67 | ~$490 | ~$10 |

Each option includes ~3× 200 GB gp3 storage (~$0.07/h).

How to read it:

- **Cold standby (today's model):** pay the $/hour column only during an outage. A full-replica mirror
  would cost ≈ **$13 per 15-hour outage** instead of ≈ $7.50.
- **Always-on** (hot standby, or moving off the home cluster), add:
  - internet egress through the tunnel: **$50–70/month** (≈ 20 GB/day at the failover's rate);
  - cross-AZ replication traffic if the nodes span availability zones: **$10–15/month**;
  - **$73/month** for EKS if you want managed Kubernetes instead of self-managed k3s.
- **Discounts:** a 1-year Compute Savings Plan takes ~30% off compute, 3-year ~50%.
- **Graviton (ARM)** would be ~20% cheaper, but the sensei images are built for amd64 only.

## 3. Hardware: m7i.2xlarge vs. the home cluster

| | CPU | Cores / threads | Clock (base / boost) | RAM | Storage |
|---|---|---|---|---|---|
| mercury, venus, earth (Beelink EQ13) | Intel N100 (2023, efficiency cores only, 6 W) | 4 / 4 each | 0.8 / 3.4 GHz | 32 GB each | local NVMe |
| mars (Intel NUC8i5BEH) | i5-8259U (2018, 28 W) | 4 / 8 | 2.3 / 3.8 GHz | 32 GB | local NVMe |
| jupiter (Intel NUC11PAHi7) | i7-1165G7 (2020, 28 W) | 4 / 8 | 2.8 / 4.7 GHz | 64 GB | local NVMe |
| **Home total** | | **20 / 28** | | **192 GB** | |
| **AWS m7i.2xlarge** | Xeon Platinum 8488C (Sapphire Rapids, 2023, server-class) | **4 / 8** (8 vCPUs = hyperthreads on 4 cores) | ~3.2 sustained / 3.8 GHz | **32 GiB** | network storage (EBS gp3, set to 6000 IOPS / 500 MB/s) |

In practice:

- **Per core:** a Sapphire Rapids core is roughly on par with jupiter's Tiger Lake cores, clearly
  faster than mars's 2018 core, and much faster than an N100 core (efficiency cores, about 60% of a
  performance core).
- **One m7i.2xlarge ≈ one jupiter node** in CPU, or ≈ 1.5–2 of the Beelink N100 nodes, with the RAM
  of a single Beelink.
- **The home cluster has roughly 3–4× the CPU throughput and 6× the memory** of the instance DR
  uses. The whole cluster (media, observability, Ceph included) used ≈ 7.3 cores and 55 GiB at the
  time of measurement, so it is mostly idle capacity.
- **Storage:** home's local NVMe has lower latency. EBS is network-attached, but consistent and easy
  to resize.
- **Running cost:** the five nodes draw roughly 80–120 W, ≈ $15–25/month of electricity at typical
  rates. That is a tiny fraction of an equivalent always-on AWS setup (≈ $640–935/month), which is
  why a **cold standby that only runs during outages** is the cost-effective design.

## Assumptions and caveats

- On-demand list prices, us-east-1, as of October 2026; check current pricing before deciding.
- Egress estimate is from a single overnight-into-morning failover; daytime traffic may be higher.
- CPU comparisons are approximate (generational and core-type differences), not benchmarks.
- Electricity estimate assumes typical idle-to-moderate load and $0.15–0.25/kWh.
