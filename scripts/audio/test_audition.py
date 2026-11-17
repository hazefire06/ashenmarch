"""Tests for audition.py: the self-contained HTML page for listening to a batch."""
from __future__ import annotations

import unittest

import audition
from audition import Take


class PageTest(unittest.TestCase):
    def test_the_audition_page_escapes_prompts_and_loads_nothing_external(self) -> None:
        page = audition.page("melee", [Take("swing_blade", 1, "<script>x</script>", "melee/swing_blade_1.wav", None)])
        self.assertNotIn("<script>x</script>", page)
        self.assertIn("&lt;script&gt;x&lt;/script&gt;", page)
        self.assertNotIn('src="http', page)
        self.assertNotIn("href=\"http", page)
        self.assertIn('<audio controls', page)
        self.assertIn('type="checkbox"', page)
        self.assertIn("picks-melee.json", page)

    def test_loop_batches_preview_on_repeat_and_the_rest_play_once(self) -> None:
        take = Take("bed_rain", 1, "p", "bed/bed_rain_1.wav", None)
        for batch in ("loops", "march", "bed"):
            with self.subTest(batch=batch):
                self.assertIn('<audio controls loop preload="none"', audition.page(batch, [take]))
        for batch in ("melee", "music"):
            with self.subTest(batch=batch):
                page = audition.page(batch, [take])
                self.assertIn('<audio controls preload="none"', page)
                self.assertNotIn(" loop ", page)

    def test_an_id_or_file_cannot_break_out_of_its_attribute(self) -> None:
        page = audition.page("melee", [Take('a"onload="x', 1, "p", 'f".wav', "v\"")])
        self.assertNotIn('"onload="x', page)
        self.assertNotIn('f".wav', page)

    def test_the_kind_follows_the_batch(self) -> None:
        take = Take("a", 1, "t", "f.wav", "v")
        self.assertIn('data-kind="cues"', audition.page("melee", [take]))
        self.assertIn('data-kind="lines"', audition.page("voices-shieldman", [take]))
        self.assertIn('data-kind="design"', audition.page("design-shieldman", [take]))

    def test_the_ab_page_has_no_save_button(self) -> None:
        page = audition.page("ab", [Take("attack_1", 1, "t", "f.wav", "eleven_v4")])
        self.assertNotIn("Save picks", page)
        self.assertNotIn('type="checkbox"', page)

    def test_the_batch_name_is_escaped_too(self) -> None:
        self.assertNotIn("<b>", audition.page("a<b>", []))


if __name__ == "__main__":
    unittest.main()
