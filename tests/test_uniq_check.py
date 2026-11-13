"""Run: python3 tests/test_uniq_check.py (lib/uniq_check.py)."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import uniq_check as u  # noqa: E402

# A live pair: a public news item (the source) and an agent's rewrite of it that kept too much.
SRC_284 = 'Лимит на зарубежный трафик все-таки может появиться в России — Минцифры рассматривает такие ограничения. Ведомство хочет контролировать объем интернета с иностранных сайтов через специальное оборудование, а при исчерпании лимита доступ к зарубежным ресурсам могут ограничить. Это коснется Steam, онлайн-игр, магазинов приложений и других сервисов, причем не только на телефонах, но и через домашний Wi-Fi, сообщают СМИ. Эксперты предупреждают о сбоях и замедлении интернета.'
TEXT_286 = '⚡️Лимит на зарубежный трафик: теперь и для домашнего интернета\n\nВ России всё-таки может появиться лимит на зарубежный трафик. Такие ограничения рассматривает Минцифры, сообщают СМИ.\n\nРаньше речь шла только о мобильном интернете: ведомство хотело брать плату за международный трафик сверх 15 ГБ в месяц, но инициативу отложили.\n\nСейчас Минцифры хочет контролировать объём трафика с иностранных сайтов через специальное оборудование. Если лимит исчерпан, доступ к зарубежным ресурсам могут ограничить. Это может затронуть Steam, онлайн-игры, магазины приложений и другие сервисы, причём не только на телефонах, но и через домашний Wi-Fi.\n\nЭксперты предупреждают о сбоях и замедлении интернета.'
OWN = '⚡️Онлайн-школам пора готовить запасной вход на платформу\n\nЕсли обучение держится на зарубежных сервисах, при новых ограничениях часть учеников просто не откроет урок. Проверьте, где лежат ваши видео и чат курса.\n\nЛучше заранее сделать российское зеркало и предупредить учеников, куда идти, если основная площадка перестанет грузиться.'


class Uniq(unittest.TestCase):
    def test_284_to_286_over_threshold(self) -> None:
        r = u.check(SRC_284, TEXT_286)
        self.assertGreater(r["share_pct"], 25)
        self.assertTrue(r["over"])
        self.assertIn("Эксперты предупреждают о сбоях и замедлении интернета.", [b["sentence"] for b in r["borrowed"]])

    def test_own_text_under_threshold(self) -> None:
        self.assertLess(u.check(SRC_284, OWN)["share_pct"], 25)

    def test_case_and_endings_do_not_hide_a_copy(self) -> None:
        r = u.check("Эксперты предупреждают о сбоях и замедлении интернета.", "ЭКСПЕРТ предупреждает о сбое и замедлениях интернета.")
        self.assertEqual(r["share_pct"], 100.0)

    def test_quote_with_author_names_numbers_dates_ignored(self) -> None:
        src = "Глава компании сказал: «мы будем расти дальше вместе с рынком». Выручка 15 млн 12 октября 2026 года."
        own = "«Мы будем расти дальше вместе с рынком», сказал Иван Петров. Выручка 15 млн 12 октября 2026 года."
        self.assertEqual(u.check(src, own)["share_pct"], 0.0)

    def test_multi_sentence_quote_with_author_ignored(self) -> None:
        src = "Мы продолжаем развивать большую образовательную платформу. Мы готовим новые полезные материалы."
        own = "Автор сказал: «Мы продолжаем развивать большую образовательную платформу. Мы готовим новые полезные материалы»."
        self.assertEqual(u.check(src, own)["share_pct"], 0.0)

    def test_quote_with_author_across_a_line_break_ignored(self) -> None:
        src = "Мы продолжаем развивать большую образовательную платформу. Мы готовим новые полезные материалы."
        own = "Автор сказал: «Мы продолжаем развивать большую образовательную платформу.\nМы готовим новые полезные материалы»."
        self.assertEqual(u.check(src, own)["share_pct"], 0.0)

    def test_dash_before_lowercase_is_no_author(self) -> None:
        src = "Мы продолжаем развивать большую образовательную платформу."
        self.assertTrue(u.check(src, "Тема — развитие: «Мы продолжаем развивать большую образовательную платформу».")["over"])

    def test_heading_before_colon_is_no_author(self) -> None:
        src = "Мы продолжаем развивать большую образовательную платформу."
        self.assertTrue(u.check(src, "Вывод: «Мы продолжаем развивать большую образовательную платформу».")["over"])
        for head in ("Цитата", "Цитаты", "Выводы", "Тезисы", "Главное", "Фрагмент"):
            self.assertTrue(u.check(src, f"{head}: «Мы продолжаем развивать большую образовательную платформу».")["over"], head)
        self.assertEqual(u.check(src, "Иванов: «Мы продолжаем развивать большую образовательную платформу».")["share_pct"], 0.0)

    def test_threshold_compares_unrounded_share(self) -> None:
        # one borrowed sentence of B chars, own text so the total is 4B-1: share just above 25%, rounds to 25.0
        long_src = ("Эксперты предупреждают о возможных сбоях и заметном замедлении работы домашнего интернета "
                    "в крупных городах страны в ближайшие недели после запуска нового оборудования.")
        b = len(long_src)
        own_len = 4 * b - 1 - b
        word = "котик "
        own = (word * (own_len // len(word) + 1))[: own_len - 1].rstrip()
        own = own + "." * (own_len - len(own))
        r = u.check(long_src, long_src + " " + own)
        self.assertEqual((r["chars_borrowed"], r["chars_total"]), (b, 4 * b - 1))
        self.assertEqual(r["share_pct"], 25.0)
        self.assertTrue(r["over"])

    def test_quote_without_author_counts(self) -> None:
        src = "Минцифры хочет контролировать объём трафика с иностранных сайтов через специальное оборудование."
        self.assertTrue(u.check(src, "«Хочет контролировать объём трафика с иностранных сайтов через специальное оборудование».")["borrowed"])

    def test_cli_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            s, t, o = Path(d, "s.txt"), Path(d, "t.txt"), Path(d, "o.txt")
            s.write_text(SRC_284, encoding="utf-8"); t.write_text(TEXT_286, encoding="utf-8"); o.write_text(OWN, encoding="utf-8")
            run = lambda *a: subprocess.run([sys.executable, u.__file__, *a], capture_output=True, text=True).returncode  # noqa: E731
            self.assertEqual(run("--source", str(s), "--text", str(t)), 1)
            self.assertEqual(run("--source", str(s), "--text", str(o)), 0)
            self.assertEqual(run("--text", str(o)), 2)


if __name__ == "__main__":
    unittest.main()
