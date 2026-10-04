"""Pure decision logic for the sensei DR orchestrator (no AWS/network calls; unit tested).

States (item pk=dr, attribute `state`):
  STANDBY  -> nothing running
  DRILL    -> instance up, side effects off, served on the drill hostname only
  FAILOVER -> instance coming up in failover mode; DNS still points home
  ACTIVE   -> DNS points at the DR tunnel; never left automatically
  FAILBACK -> DNS back home, DR still running until `complete`

`decide()` returns the updated dr item plus a list of effects for the handler to execute.
Effects are executed before the item is saved; a failing effect leaves the state unchanged so the
next run retries.
"""
from __future__ import annotations

import copy
import time
from dataclasses import dataclass, field

STANDBY, DRILL, FAILOVER, ACTIVE, FAILBACK = "STANDBY", "DRILL", "FAILOVER", "ACTIVE", "FAILBACK"
RUNNING_STATES = {DRILL, FAILOVER, ACTIVE, FAILBACK}


@dataclass
class Config:
    heartbeat_timeout: int = 300       # seconds without a home heartbeat before probing
    probe_failures_needed: int = 3     # consecutive failed public probes before failover
    ready_timeout: int = 5400          # alert if FAILOVER has not become ready by then
    home_back_grace: int = 180         # heartbeat must be this fresh to count as "home is back"


@dataclass
class Effects:
    asg: int | None = None                      # desired capacity
    dns: list[str] = field(default_factory=list)  # "failover", "restore", "drill-add", "drill-remove"
    notify: list[tuple[str, str]] = field(default_factory=list)
    home: dict = field(default_factory=dict)    # attributes to set on the home item
    clear_instance: bool = False


def new_run_id(now: int) -> str:
    return time.strftime("%Y%m%d%H%M", time.gmtime(now))


def _transition(dr: dict, state: str, now: int, reason: str) -> None:
    hist = list(dr.get("history", []))[-19:]
    hist.append({"at": now, "from": dr.get("state", STANDBY), "to": state, "reason": reason})
    dr["history"] = hist
    dr["state"] = state
    dr["stateSince"] = now


def _start_run(dr: dict, now: int, mode: str) -> None:
    dr["runId"] = new_run_id(now)
    dr["runStartedAt"] = now
    dr["desiredMode"] = mode
    dr["notified"] = {}


def decide(now: int, dr: dict, home: dict, instance: dict, cfg: Config,
           request: str | None = None, probe=None, manual_reason: str = "") -> tuple[dict, Effects]:
    """Return (new dr item, effects). `probe` is a zero-arg callable returning True if the site is up."""
    dr = copy.deepcopy(dr)
    dr.setdefault("state", STANDBY)
    dr.setdefault("armed", False)
    dr.setdefault("autoArm", True)
    dr.setdefault("probeFailures", 0)
    dr.setdefault("notified", {})
    eff = Effects()
    state = dr["state"]

    hb = int(home.get("lastHeartbeat", 0) or 0)
    hb_age = now - hb if hb else None
    home_alive = hb_age is not None and hb_age < cfg.heartbeat_timeout
    home_back = hb_age is not None and hb_age < cfg.home_back_grace
    run_matches = instance.get("runId") == dr.get("runId")

    def notify_once(key: str, subject: str, body: str) -> None:
        if not dr["notified"].get(key):
            dr["notified"][key] = now
            eff.notify.append((subject, body))

    # ---- explicit operator requests -------------------------------------------------------
    if request:
        why = f"request:{request}" + (f" ({manual_reason})" if manual_reason else "")
        if request == "arm":
            dr["armed"], dr["autoArm"] = home_alive, True
        elif request == "disarm":
            dr["armed"], dr["autoArm"] = False, False
            dr["probeFailures"] = 0
        elif request == "drill-start" and state == STANDBY:
            _start_run(dr, now, "drill")
            _transition(dr, DRILL, now, why)
            eff.dns.append("drill-add")
            eff.clear_instance = True
        elif request == "drill-stop" and state == DRILL:
            _transition(dr, STANDBY, now, why)
            eff.dns.append("drill-remove")
            eff.clear_instance = True
        elif request == "failover" and state in (STANDBY, DRILL):
            if state == STANDBY:
                _start_run(dr, now, "failover")
                eff.clear_instance = True
            dr["desiredMode"] = "failover"
            dr["manualFailover"] = True
            _transition(dr, FAILOVER, now, why)
            eff.notify.append(("[sensei-dr] Manual failover started",
                               f"Run {dr['runId']}: AWS is starting; DNS switches when DR reports ready."))
        elif request == "abort" and state in (FAILOVER, DRILL):
            _transition(dr, STANDBY, now, why)
            eff.dns.append("drill-remove")
            eff.clear_instance = True
            dr["manualFailover"] = False
        elif request == "freeze" and state in (ACTIVE, FAILBACK):
            dr["desiredMode"] = "maintenance"
        elif request == "unfreeze" and state in (ACTIVE, FAILBACK):
            dr["desiredMode"] = "failover"
        elif request == "failback-dns" and state == ACTIVE:
            eff.dns.append("restore")
            _transition(dr, FAILBACK, now, why)
            eff.notify.append(("[sensei-dr] DNS restored to home",
                               "Cloudflare records point at the home tunnel again. Run `drctl failback complete` "
                               "to unfence home and stop the AWS instance."))
        elif request == "complete" and state == FAILBACK:
            _transition(dr, STANDBY, now, why)
            eff.home["unfenceApproved"] = True
            eff.clear_instance = True
            dr["manualFailover"] = False
            dr["dnsSnapshot"] = None
        else:
            raise ValueError(f"request {request!r} not allowed in state {state}")
        state = dr["state"]

    # ---- arming -------------------------------------------------------------------------------
    if not dr["armed"] and dr["autoArm"] and home_alive and state in (STANDBY, DRILL):
        dr["armed"] = True
        eff.notify.append(("[sensei-dr] Automatic failover armed",
                           "Home heartbeat received; the DR orchestrator will fail over if it stops."))

    # ---- automatic transitions ----------------------------------------------------------------
    if state in (STANDBY, DRILL):
        if home_alive or not dr["armed"]:
            dr["probeFailures"] = 0
        else:
            up = probe() if probe else False
            dr["probeFailures"] = 0 if up else int(dr["probeFailures"]) + 1
            if dr["probeFailures"] >= cfg.probe_failures_needed:
                if state == STANDBY:
                    _start_run(dr, now, "failover")
                    eff.clear_instance = True
                dr["desiredMode"] = "failover"
                dr["manualFailover"] = False
                _transition(dr, FAILOVER, now,
                            f"auto: no heartbeat for {hb_age if hb_age is not None else 'ever'}s, "
                            f"{dr['probeFailures']} failed probes")
                eff.notify.append(("[sensei-dr] FAILOVER started: home is unreachable",
                                   f"No home heartbeat for {hb_age}s and senseichess.com failed "
                                   f"{dr['probeFailures']} probes. Run {dr['runId']} is starting in AWS; "
                                   "DNS switches automatically when it is ready."))
                dr["probeFailures"] = 0
                state = FAILOVER

    elif state == FAILOVER:
        if home_back and not dr.get("manualFailover"):
            _transition(dr, STANDBY, now, "auto: home heartbeat returned before DNS switch")
            eff.dns.append("drill-remove")
            eff.clear_instance = True
            eff.notify.append(("[sensei-dr] Failover aborted: home is back",
                               "The home heartbeat returned before DR was ready; AWS is shutting down."))
            state = STANDBY
        elif instance.get("ready") and instance.get("appliedMode") == "failover" and run_matches:
            eff.dns.append("failover")
            dr["activatedAt"] = now
            _transition(dr, ACTIVE, now, "auto: DR ready")
            eff.notify.append(("[sensei-dr] DR ACTIVE: senseichess.com now served from AWS",
                               f"Run {dr['runId']} is serving traffic. Postgres serverName "
                               f"{instance.get('serverName', '?')}. Failback is manual (dr/RUNBOOK.md §5)."))
            state = ACTIVE
        elif now - int(dr.get("runStartedAt", now)) > cfg.ready_timeout:
            notify_once("slow", "[sensei-dr] Failover is taking longer than expected",
                        f"Instance phase: {instance.get('phase', 'unknown')} — {instance.get('message', '')}")

    elif state == ACTIVE:
        if home_back:
            notify_once("homeBack", "[sensei-dr] Home is back online (DR still active)",
                        "Home sends heartbeats again and has fenced itself. senseichess.com stays on AWS "
                        "until you fail back: dr/RUNBOOK.md §5.")

    # ---- keep the ASG consistent with the state ------------------------------------------------
    eff.asg = 1 if state in RUNNING_STATES else 0
    return dr, eff
