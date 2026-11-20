"""Unit tests for ldx.harness.opencode (pure; no cluster, no network)."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "lib"))

from ldx.harness import opencode  # noqa: E402


def manifest_entry(**over):
    entry = {
        "id": "qwen-test",
        "name": "Qwen Test",
        "vision": False,
        "context": 8192,
        "output": 8192,
        "parser": False,
        "budget_enabled": False,
        "budget": 4096,
    }
    entry.update(over)
    return entry


class CurrentDefault(unittest.TestCase):
    def _run(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonc", delete=False) as fh:
            fh.write(text)
            path = fh.name
        try:
            return opencode.current_default(path, "bifrost")
        finally:
            os.unlink(path)

    def test_jsonc_and_bifrost_prefix(self):
        self.assertEqual(
            self._run('{"model": "bifrost/bifrost-qwen#low"} // default\n'), "qwen")

    def test_legacy_omlx_slash_prefix(self):
        self.assertEqual(
            self._run('{"model": "bifrost/omlx/qwen#low"} // default\n'), "qwen")

    def test_legacy_agw_prefix(self):
        self.assertEqual(
            self._run('{"model": "bifrost/agw-qwen#low"} // default\n'), "qwen")

    def test_other_provider_ignored(self):
        self.assertIsNone(self._run('{"model": "omlx/qwen"}'))

    def test_missing_file(self):
        self.assertIsNone(opencode.current_default("/nonexistent/opencode.jsonc", "bifrost"))

    def test_broken_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonc", delete=False) as fh:
            fh.write("{not json")
            path = fh.name
        try:
            self.assertIsNone(opencode.current_default(path, "bifrost"))
        finally:
            os.unlink(path)


class HelperModels(unittest.TestCase):
    def test_patterns(self):
        for mid in ("MarkItDown", "nomicai-modernbert", "some-modernbert-v2",
                    "text-embedding-3", "embedder", "bge-embedding"):
            self.assertTrue(opencode.is_helper_model(mid), mid)

    def test_coding_models_pass(self):
        for mid in ("qwen-3.8-moe", "llama-4", "mlx-community--Qwen3"):
            self.assertFalse(opencode.is_helper_model(mid), mid)


class BuildManifest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.settings = os.path.join(self.dir, "settings.json")
        with open(self.settings, "w") as fh:
            json.dump({"sampling": {"max_tokens": 8192}}, fh)
        self.mset = os.path.join(self.dir, "model_settings.json")
        with open(self.mset, "w") as fh:
            json.dump({"models": {
                "folder-a": {"model_alias": "alpha", "max_context_window": 16384,
                             "thinking_budget_enabled": True,
                             "thinking_budget_tokens": 4096},
                "hidden-m": {"is_hidden": True},
            }}, fh)
        self.models_dir = os.path.join(self.dir, "models")
        cfg_dir = os.path.join(self.models_dir, "x", "folder-a")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "config.json"), "w") as fh:
            json.dump({"vision_encoder": {}}, fh)

    def _build(self, ids):
        out = opencode.build_manifest(ids, self.settings, self.mset, self.models_dir)
        return [json.loads(line) for line in out.splitlines()]

    def test_filters_and_enriches(self):
        rows = self._build(["alpha", "MarkItDown", "hidden-m", "unknown-m", "",
                            "text-embedding-x"])
        self.assertEqual([r["id"] for r in rows], ["alpha"])
        row = rows[0]
        self.assertTrue(row["vision"])
        self.assertEqual(row["context"], 16384)
        self.assertTrue(row["budget_enabled"])
        self.assertEqual(row["budget"], 4096)

    def test_display_name_humanizes_moe(self):
        with open(self.mset, "w") as fh:
            json.dump({"models": {"qwen-3.8-moe-full": {}}}, fh)
        rows = self._build(["qwen-3.8-moe-full"])
        self.assertEqual(rows[0]["name"], "Qwen 3.8 MoE Full")


class Merge(unittest.TestCase):
    def _merge(self, models, existing, keep_stale=False, client_key="k",
               mcp_url="", mcp_key=""):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonc", delete=False) as fh:
            fh.write(existing)
            path = fh.name
        try:
            return opencode.merge_config(
                models, provider_id="bifrost",
                base_url="https://bifrost.rd.localhost/openai", client_key=client_key,
                mcp_url=mcp_url, mcp_key=mcp_key, mcp_name="bifrost",
                default_id=models[0]["id"], keep_stale=keep_stale, config_path=path)
        finally:
            os.unlink(path)

    def test_provider_block_and_default(self):
        res = self._merge([manifest_entry(budget_enabled=True)], "{}")
        cfg = json.loads(res["config"])
        # Config key has 'bifrost-' prefix; wire id has 'omlx/' prefix.
        self.assertEqual(cfg["model"], "bifrost/bifrost-qwen-test#low")
        models = cfg["provider"]["bifrost"]["models"]
        self.assertIn("bifrost-qwen-test", models)
        self.assertEqual(models["bifrost-qwen-test"]["id"], "omlx/qwen-test")
        self.assertIn("variants", models["bifrost-qwen-test"])
        self.assertEqual(cfg["provider"]["bifrost"]["options"]["apiKey"], "k")
        self.assertEqual(cfg["provider"]["bifrost"]["name"], "Bifrost")
        self.assertEqual(res["meta"]["model"], "bifrost/bifrost-qwen-test#low")

    def test_configures_bifrost_mcp_when_key_present(self):
        existing = json.dumps({})
        res = self._merge(
            [manifest_entry()], existing,
            mcp_url="https://bifrost.rd.localhost/mcp", mcp_key="bifrost-key")
        cfg = json.loads(res["config"])
        self.assertIn("bifrost", cfg["mcp"])
        self.assertEqual(cfg["mcp"]["bifrost"]["url"], "https://bifrost.rd.localhost/mcp")
        self.assertEqual(cfg["mcp"]["bifrost"]["headers"]["Authorization"], "Bearer bifrost-key")

    def test_skips_mcp_when_no_key(self):
        existing = json.dumps({})
        res = self._merge([manifest_entry()], existing)
        cfg = json.loads(res["config"])
        self.assertNotIn("mcp", cfg)

    def test_prunes_stale_and_keeps_other_mcp_servers(self):
        existing = json.dumps({
            "provider": {"bifrost": {"models": {"bifrost-gone": {}, "bifrost-qwen-test": {}}}},
            "mcp": {"other": {"type": "remote", "url": "http://x"}},
        })
        res = self._merge([manifest_entry()], existing)
        cfg = json.loads(res["config"])
        self.assertEqual(res["meta"]["pruned"], ["bifrost-gone"])
        self.assertNotIn("bifrost-gone", cfg["provider"]["bifrost"]["models"])
        self.assertIn("other", cfg["mcp"])

    def test_keep_stale(self):
        existing = json.dumps({"provider": {"bifrost": {"models": {"bifrost-gone": {"name": "G"}}}}})
        res = self._merge([manifest_entry()], existing, keep_stale=True)
        cfg = json.loads(res["config"])
        self.assertIn("bifrost-gone", cfg["provider"]["bifrost"]["models"])
        self.assertEqual(res["meta"]["pruned"], [])

    def test_jsonc_comments_flagged(self):
        res = self._merge([manifest_entry()], '{\n // hi\n "x": 1,\n}\n')
        self.assertTrue(res["meta"]["had_comments"])
        self.assertEqual(json.loads(res["config"])["x"], 1)


if __name__ == "__main__":
    unittest.main()
