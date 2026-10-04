import unittest

from logic import ACTIVE, DRILL, FAILBACK, FAILOVER, STANDBY, Config, decide

CFG = Config()
NOW = 1_800_000_000


def run(dr, home=None, instance=None, request=None, probe_up=False, now=NOW):
    return decide(now, dr, home or {}, instance or {}, CFG, request=request, probe=lambda: probe_up)


class ArmingTest(unittest.TestCase):
    def test_never_fails_over_before_first_heartbeat(self):
        dr = {}
        for i in range(10):
            dr, eff = run(dr, now=NOW + i * 60)
        self.assertEqual(dr["state"], STANDBY)
        self.assertFalse(dr["armed"])
        self.assertEqual(eff.asg, 0)

    def test_first_heartbeat_arms(self):
        dr, eff = run({}, home={"lastHeartbeat": NOW - 30})
        self.assertTrue(dr["armed"])
        self.assertEqual(len(eff.notify), 1)

    def test_disarm_prevents_rearm(self):
        dr, _ = run({"armed": True}, request="disarm")
        dr, _ = run(dr, home={"lastHeartbeat": NOW})
        self.assertFalse(dr["armed"])


class AutoFailoverTest(unittest.TestCase):
    def armed(self):
        return {"state": STANDBY, "armed": True}

    def test_needs_stale_heartbeat_and_failed_probes(self):
        stale = {"lastHeartbeat": NOW - 600}
        dr = self.armed()
        for i in range(2):
            dr, eff = run(dr, home=stale)
            self.assertEqual(dr["state"], STANDBY)
        dr, eff = run(dr, home=stale)
        self.assertEqual(dr["state"], FAILOVER)
        self.assertEqual(dr["desiredMode"], "failover")
        self.assertEqual(eff.asg, 1)
        self.assertTrue(eff.clear_instance)

    def test_site_up_resets_probe_counter(self):
        stale = {"lastHeartbeat": NOW - 600}
        dr = self.armed()
        dr, _ = run(dr, home=stale)
        dr, _ = run(dr, home=stale)
        dr, _ = run(dr, home=stale, probe_up=True)
        self.assertEqual(dr["probeFailures"], 0)
        self.assertEqual(dr["state"], STANDBY)

    def test_fresh_heartbeat_never_probes(self):
        calls = []
        dr, eff = decide(NOW, self.armed(), {"lastHeartbeat": NOW - 10}, {}, CFG, probe=lambda: calls.append(1))
        self.assertEqual(calls, [])

    def test_drill_promoted_in_place(self):
        dr = {"state": DRILL, "armed": True, "runId": "r1", "desiredMode": "drill"}
        for _ in range(3):
            dr, eff = run(dr, home={"lastHeartbeat": NOW - 900})
        self.assertEqual(dr["state"], FAILOVER)
        self.assertEqual(dr["runId"], "r1")
        self.assertFalse(eff.clear_instance)


class FailoverProgressTest(unittest.TestCase):
    base = {"state": FAILOVER, "armed": True, "runId": "r1", "runStartedAt": NOW - 600, "desiredMode": "failover"}

    def test_switches_dns_when_ready(self):
        dr, eff = run(dict(self.base), home={"lastHeartbeat": NOW - 900},
                      instance={"runId": "r1", "ready": True, "appliedMode": "failover"})
        self.assertEqual(dr["state"], ACTIVE)
        self.assertEqual(eff.dns, ["failover"])

    def test_ignores_stale_instance_report(self):
        dr, eff = run(dict(self.base), instance={"runId": "old", "ready": True, "appliedMode": "failover"})
        self.assertEqual(dr["state"], FAILOVER)
        self.assertEqual(eff.dns, [])

    def test_not_ready_in_drill_mode(self):
        dr, eff = run(dict(self.base), instance={"runId": "r1", "ready": True, "appliedMode": "drill"})
        self.assertEqual(dr["state"], FAILOVER)

    def test_aborts_when_home_returns(self):
        dr, eff = run(dict(self.base), home={"lastHeartbeat": NOW - 20})
        self.assertEqual(dr["state"], STANDBY)
        self.assertEqual(eff.asg, 0)

    def test_manual_failover_not_aborted_by_heartbeat(self):
        dr, eff = run(dict(self.base, manualFailover=True), home={"lastHeartbeat": NOW - 20})
        self.assertEqual(dr["state"], FAILOVER)

    def test_slow_alert_once(self):
        slow = dict(self.base, runStartedAt=NOW - 10_000)
        dr, eff = run(slow)
        self.assertEqual(len(eff.notify), 1)
        dr, eff = run(dr)
        self.assertEqual(len(eff.notify), 0)


class ActiveAndFailbackTest(unittest.TestCase):
    def test_active_is_sticky_when_home_returns(self):
        dr, eff = run({"state": ACTIVE, "armed": True}, home={"lastHeartbeat": NOW})
        self.assertEqual(dr["state"], ACTIVE)
        self.assertEqual(eff.asg, 1)
        self.assertEqual(len(eff.notify), 1)
        dr, eff = run(dr, home={"lastHeartbeat": NOW})
        self.assertEqual(len(eff.notify), 0)

    def test_failback_sequence(self):
        dr, eff = run({"state": ACTIVE}, request="freeze")
        self.assertEqual(dr["desiredMode"], "maintenance")
        dr, eff = run(dr, request="failback-dns")
        self.assertEqual((dr["state"], eff.dns), (FAILBACK, ["restore"]))
        self.assertEqual(eff.asg, 1)
        dr, eff = run(dr, request="complete")
        self.assertEqual(dr["state"], STANDBY)
        self.assertEqual(eff.home, {"unfenceApproved": True})
        self.assertEqual(eff.asg, 0)

    def test_invalid_request_rejected(self):
        with self.assertRaises(ValueError):
            run({"state": STANDBY}, request="failback-dns")


class DrillTest(unittest.TestCase):
    def test_drill_lifecycle(self):
        dr, eff = run({}, request="drill-start")
        self.assertEqual((dr["state"], dr["desiredMode"], eff.asg, eff.dns), (DRILL, "drill", 1, ["drill-add"]))
        dr, eff = run(dr, request="drill-stop")
        self.assertEqual((dr["state"], eff.asg, eff.dns), (STANDBY, 0, ["drill-remove"]))


if __name__ == "__main__":
    unittest.main()
