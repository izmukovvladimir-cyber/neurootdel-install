#!/usr/bin/env python3
"""Text uniqueness vs. its source: how much of a text is borrowed from the source it was written from.

Usage:
    python3 /usr/local/lib/<agent user>/uniq_check.py --source SRC.txt --text TEXT.txt [--json] [--threshold 25]

A sentence of TEXT is borrowed when (a) it shares 5 or more consecutive words with SRC, or (b) it repeats one
source sentence in the same order of thought (the longest common in-order word chain covers >= 60% of the
shorter of the two sentences, at least 4 words). Words are compared lowercased, «ё» as «е», endings stripped
(light Russian stemmer, no pymorphy needed), prepositions dropped. Not counted: quotes in
«...» or "..." with an author in the same sentence, names and titles (a capitalised word that does not open the
sentence, any Latin word), numbers and dates. Share = chars of borrowed sentences / chars of all sentences.

Exit: 0 share <= threshold, 1 share > threshold (return the text with the list), 2 no source / bad input.
Deterministic, no network, no model calls.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

NGRAM = 5
ORDER_RATIO = 0.6
ORDER_MIN = 4
PREPOSITIONS = set("""в во на с со к ко по о об обо от ото до из изо у за над надо под подо при про через для без
безо между перед передо ради сквозь вокруг около после среди вместо кроме вдоль возле мимо против""".split())
ENDINGS = sorted("""иями ями ами ыми ими его ого ему ому ее ие ые ое ей ий ый ой ем им ым ом их ых ую юю ая яя ою ею
ах ях ов ев ью ия ья ье ии ям ам ешь ете ет ют ут ит ат ят ла ли ло ть ти а я о е у ю ы и й ь""".split(),
                 key=len, reverse=True)
QUOTE_RE = re.compile(r"«[^»]*»|\"[^\"]*\"|“[^”]*”|„[^“”]*[“”]")
# A capitalised word before «:» is an author («Иванов: «...»»), except a plain heading («Вывод: «...»»).
HEADINGS = (r"Вывод\w*|Итог\w*|Тем[аыи]|Пример\w*|Главн\w*|Важн\w*|Факт\w*|Суть|Коротко|Кратко|Цитат\w*|"
            r"Новост\w*|Заголов\w*|Текст\w*|Пост|Посты|Источник\w*|Итак|Ответ\w*|Вопрос\w*|Совет\w*|Иде[яи]|"
            r"Мысл[ьи]|Результат\w*|Цел[ьи]|Задач[аи]|Тезис\w*|Выдержк\w*|Фрагмент\w*")
AUTHOR_RE = re.compile(r"(?i:\b(сказал\w*|заявил\w*|отметил\w*|пишет|написал\w*|говорит|сообщил\w*|подчеркнул\w*|"
                       r"признал\w*|по\s+словам)\b)|[—–-]\s*[А-ЯЁA-Z]|"
                       r"(?!(?:" + HEADINGS + r")\s*:)[А-ЯЁA-Z][а-яёa-z]+\s*:")
WORD_RE = re.compile(r"[A-Za-zА-Яа-яЁё0-9]+(?:-[A-Za-zА-Яа-яЁё0-9]+)*")
DATE_RE = re.compile(r"(?i)^(январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|октябр|ноябр|декабр)")
SENT_RE = re.compile(r"[^.!?…\n]+[.!?…]*")


@dataclass
class Sentence:
    raw: str
    stems: list[str] = field(default_factory=list)


def stem(word: str) -> str:
    w = word.lower().replace("ё", "е")
    for refl in ("ся", "сь"):
        if w.endswith(refl) and len(w) - 2 >= 4:
            w = w[:-2]
            break
    for end in ENDINGS:
        if w.endswith(end) and len(w) - len(end) >= 3:
            return w[:-len(end)]
    return w


QUOTE_MASK = str.maketrans({".": "\u2024", "!": "\u01c3", "?": "\u0294", "…": "\u22ef", "\n": "\u2063"})
QUOTE_UNMASK = str.maketrans({"\u2024": ".", "\u01c3": "!", "\u0294": "?", "\u22ef": "…", "\u2063": "\n"})


def sentences(text: str) -> list[str]:
    """Sentences; a quote of several sentences stays inside one (its author is then seen by tokens())."""
    masked = QUOTE_RE.sub(lambda m: m.group(0).translate(QUOTE_MASK), text)
    return [s.strip().translate(QUOTE_UNMASK) for s in SENT_RE.findall(masked) if WORD_RE.search(s)]


def tokens(sentence: str) -> list[str]:
    """Stems of the words that count: no author quotes, names, Latin, numbers, dates, prepositions."""
    if AUTHOR_RE.search(QUOTE_RE.sub(" ", sentence)):
        sentence = QUOTE_RE.sub(" ", sentence)
    out = []
    for i, m in enumerate(WORD_RE.finditer(sentence)):
        w = m.group(0)
        if re.search(r"\d", w) or re.search(r"[A-Za-z]", w) or DATE_RE.match(w):
            continue
        if i > 0 and w[0].isupper():
            continue  # a name or a title inside the sentence
        if w.lower() in PREPOSITIONS:
            continue
        out.append(stem(w))
    return out


def ngrams(seq: list[str], n: int = NGRAM) -> set[tuple[str, ...]]:
    return {tuple(seq[i:i + n]) for i in range(len(seq) - n + 1)}


def lcs(a: list[str], b: list[str]) -> int:
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def check(source: str, text: str, threshold: float = 25.0) -> dict:
    src = [Sentence(s, tokens(s)) for s in sentences(source)]
    src_grams: set[tuple[str, ...]] = set()
    for s in src:
        src_grams |= ngrams(s.stems)
    borrowed = []
    total = 0
    taken = 0
    for raw in sentences(text):
        total += len(raw)
        st = tokens(raw)
        reason = ""
        if ngrams(st) & src_grams:
            reason = f"{NGRAM}+ слов подряд из исходника"
        else:
            for s in src:
                short = min(len(st), len(s.stems))
                common = lcs(st, s.stems)
                if short and common >= ORDER_MIN and common / short >= ORDER_RATIO:
                    reason = "повторяет предложение исходника тем же порядком"
                    break
        if reason:
            taken += len(raw)
            borrowed.append({"sentence": raw, "reason": reason})
    exact = 100.0 * taken / total if total else 0.0
    return {"share_pct": round(exact, 1), "threshold_pct": threshold, "over": exact > threshold,
            "borrowed": borrowed, "chars_total": total, "chars_borrowed": taken}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Доля заимствованных предложений текста относительно исходника")
    ap.add_argument("--source", help="файл исходника (новость, пост, статья, расшифровка)")
    ap.add_argument("--text", required=True, help="файл нашего текста")
    ap.add_argument("--threshold", type=float, default=25.0)
    ap.add_argument("--json", action="store_true")
    ns = ap.parse_args(argv)
    if not ns.source:
        print("НЕТ ИСХОДНИКА: попроси у автора текста ссылку на исходник, без неё текст не пропускается", file=sys.stderr)
        return 2
    try:
        source = Path(ns.source).read_text(encoding="utf-8")
        text = Path(ns.text).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as err:
        print(f"ОШИБКА ВХОДА: {type(err).__name__}: {err}", file=sys.stderr)
        return 2
    if not source.strip():
        print("НЕТ ИСХОДНИКА: файл исходника пуст", file=sys.stderr)
        return 2
    res = check(source, text, ns.threshold)
    if ns.json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        verdict = "ВОЗВРАТ автору: переписать своими словами" if res["over"] else "в норме"
        print(f"Заимствовано {res['share_pct']}% (порог {ns.threshold:g}%): {verdict}")
        for b in res["borrowed"]:
            print(f"- {b['sentence']}  [{b['reason']}]")
    return 1 if res["over"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
