"""Offline checks for pinned Aliyun full-market systemd installer."""
import ast
from pathlib import Path
import unittest

PATH = Path(__file__).with_name("install_aliyun_main_prefetch.py")
TREE = ast.parse(PATH.read_text(encoding="utf-8"))
NAMES = {node.targets[0].id: ast.literal_eval(node.value)
         for node in TREE.body
         if isinstance(node, ast.Assign)
         and len(node.targets) == 1
         and isinstance(node.targets[0], ast.Name)
         and node.targets[0].id in ("PIN", "BLOBS", "SERVICE_BODY", "TIMER_BODY")}


class MainInstallerTests(unittest.TestCase):
    def test_source_pins(self):
        self.assertEqual(len(NAMES["PIN"]), 40)
        self.assertEqual(set(NAMES["BLOBS"]),
                         {"market_gateway.py", "prefetch_main_history.py"})
        self.assertTrue(all(len(digest) == 40 for digest in NAMES["BLOBS"].values()))

    def test_bounded_background_unit(self):
        service = NAMES["SERVICE_BODY"]
        timer = NAMES["TIMER_BODY"]
        self.assertIn("Type=oneshot", service)
        self.assertIn("prefetch_main_history.py --limit 24", service)
        self.assertIn("Nice=10", service)
        self.assertIn("TimeoutStartSec=8min", service)
        self.assertIn("OnUnitInactiveSec=10min", timer)
        self.assertIn("qihui-main-history-prefetch.service", timer)
        self.assertNotIn(":8765", service)

    def test_rollback_and_digest(self):
        text = PATH.read_text()
        self.assertIn("hashlib.sha1", text)
        self.assertIn("old_gateway = gateway.read_bytes()", text)
        self.assertIn("safe_install(gateway, old_gateway)", text)
        self.assertIn('run_cmd("systemctl", "restart", GATEWAY_SERVICE)', text)


if __name__ == "__main__":
    unittest.main()
