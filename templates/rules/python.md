# Python style

- Type hints on every function signature and dataclass field.
- `pathlib.Path` over `os.path`. Always.
- f-strings for formatting; no `%` or `.format()`.
- `dataclasses` (or `pydantic` when validating external input) over loose dicts.
- `logging` module, never `print()` in non-CLI code. Module-level logger: `log = logging.getLogger(__name__)`.
- Google-style docstrings; only when the function is non-obvious.
- `with` blocks for any resource (files, sockets, locks). No bare `open()`.
- Catch specific exceptions, never bare `except:`.
- Prefer comprehensions over `map`/`filter`. Generator expressions for large data.
- snake_case names. Constants UPPER_CASE.
