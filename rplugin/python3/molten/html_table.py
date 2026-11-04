"""Render the tables in an HTML output as plain text, so they can be shown inside Neovim.

Used for outputs that have a `text/html` table but no useful `text/plain` version, such as a
pandas Styler (`df.style...`) or `IPython.display.HTML("<table>...")`, whose plain text is just
`<... object at 0x...>`. Only the standard library is used.
"""

import re
import unicodedata
from html.parser import HTMLParser
from typing import Dict, List, Optional, Tuple

# Python's default repr is "<mod.Class object at 0x...>"; IPython prints "<mod.Class at 0x...>"
_OBJECT_REPR = re.compile(r"<[\w.]+( object)?( at 0x[0-9a-fA-F]+)?>")
_NUMBER = re.compile(r"[-+−]?(\d[\d,_ ]*)?\.?\d+([eE][-+]?\d+)?%?|[-+]?(nan|NaN|inf|NaT|None)")


def is_object_repr(text: str) -> bool:
    """True for the default repr of an object, which says nothing about its contents."""
    return _OBJECT_REPR.fullmatch(text.strip()) is not None


def plain_is_uninformative(plain: object, html: str) -> bool:
    """Whether the HTML table says more than the plain text of the same output: there's no plain
    text, it's just "<... object at 0x...>", or it's a one-line summary (e.g. dask's
    "dask.array<..., shape=(4000, 3000), ...>") while the HTML has a table."""
    if not isinstance(plain, str) or not plain.strip() or is_object_repr(plain):
        return True
    return "\n" not in plain.strip() and "<table" in html.lower()


class _Cell:
    def __init__(self, header: bool, colspan: int, rowspan: int):
        self.header = header
        self.colspan = colspan
        self.rowspan = rowspan
        self.parts: List[str] = []
        self.has_table = False  # a nested table was inside this cell

    @property
    def text(self) -> str:
        return " ".join("".join(self.parts).split())


class _Table:
    def __init__(self):
        self.caption: List[str] = []
        self.rows: List[List[_Cell]] = []
        self.head_rows = 0  # number of rows that came from <thead>
        self.cell: Optional[_Cell] = None  # the cell being read
        self.in_thead = False
        self.in_caption = False
        self.order = 0

    def is_layout(self) -> bool:
        """Only there to arrange other tables (and pictures) side by side: nothing to show."""
        cells = [c for row in self.rows for c in row]
        return any(c.has_table for c in cells) and not any(
            c.text for c in cells if not c.has_table
        )


class _TableParser(HTMLParser):
    """Collects every table, nested ones included (a nested table becomes a table of its own)."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables: List[_Table] = []
        self._stack: List[_Table] = []
        self._skip = 0  # inside <style>, <script> or <svg>: not text
        self._opened = 0

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag in ("style", "script", "svg"):
            self._skip += 1
            return
        if self._skip:
            return
        if tag == "table":
            if self._stack and self._stack[-1].cell is not None:
                self._stack[-1].cell.has_table = True
            table = _Table()
            table.order = self._opened  # keep tables in page order, not closing order
            self._opened += 1
            self._stack.append(table)
            return
        if not self._stack:
            return
        table = self._stack[-1]
        if tag == "thead":
            table.in_thead = True
        elif tag == "caption":
            table.in_caption = True
        elif tag == "tr":
            table.cell = None
            table.rows.append([])
            if table.in_thead:
                table.head_rows += 1
        elif tag in ("td", "th"):
            a = dict(attrs)

            def span(name: str) -> int:
                try:
                    return max(1, int(a.get(name) or 1))
                except ValueError:
                    return 1

            if not table.rows:
                table.rows.append([])
            table.cell = _Cell(tag == "th", span("colspan"), span("rowspan"))
            table.rows[-1].append(table.cell)
        elif tag == "br" and table.cell is not None:
            table.cell.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("style", "script", "svg"):
            self._skip = max(0, self._skip - 1)
            return
        if self._skip or not self._stack:
            return
        table = self._stack[-1]
        if tag in ("td", "th"):
            table.cell = None
        elif tag == "thead":
            table.in_thead = False
        elif tag == "caption":
            table.in_caption = False
        elif tag == "table":
            self._stack.pop()
            if not table.is_layout():
                self.tables.append(table)

    def handle_data(self, data: str) -> None:
        if self._skip or not self._stack:
            return
        table = self._stack[-1]
        if table.cell is not None:
            table.cell.parts.append(data)
        elif table.in_caption:
            table.caption.append(data)


def _width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def _clip(text: str, max_width: int) -> str:
    if _width(text) <= max_width:
        return text
    out = ""
    for c in text:
        if _width(out + c) > max_width - 1:
            break
        out += c
    return out + "…"


def _grid(table: _Table) -> List[List[Tuple[str, bool]]]:
    """Expand colspan/rowspan into a rectangular grid of (text, is_header) cells."""
    grid: List[List[Tuple[str, bool]]] = []
    carried: Dict[int, int] = {}  # column -> rows still covered by a rowspan from above
    for row in table.rows:
        out: List[Tuple[str, bool]] = []
        col = 0

        def fill_carried() -> None:
            nonlocal col
            while carried.get(col, 0) > 0:
                carried[col] -= 1
                out.append(("", False))  # pandas shows a repeated index level as blank, too
                col += 1

        for cell in row:
            fill_carried()
            for i in range(cell.colspan):
                out.append((cell.text if i == 0 else "", cell.header))
                if cell.rowspan > 1:
                    carried[col] = cell.rowspan - 1
                col += 1
        fill_carried()
        grid.append(out)
    ncols = max((len(r) for r in grid), default=0)
    return [r + [("", False)] * (ncols - len(r)) for r in grid]


def html_tables_to_text(html: str, max_cell_width: int = 40) -> Optional[str]:
    """The tables in `html` as aligned plain text, or None if there are no tables."""
    parser = _TableParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception:
        return None
    tables = sorted((t for t in parser.tables if any(t.rows)), key=lambda t: t.order)
    if not tables:
        return None

    blocks = []
    for table in tables:
        grid = _grid(table)
        if not grid or not grid[0]:
            continue
        cells = [[(_clip(text, max_cell_width), header) for text, header in row] for row in grid]
        # drop columns that are empty everywhere (e.g. where a nested table or a picture was)
        keep = [c for c in range(len(cells[0])) if any(row[c][0] for row in cells)]
        if not keep:
            continue
        cells = [[row[c] for c in keep] for row in cells]
        ncols = len(cells[0])
        widths = [max(_width(row[c][0]) for row in cells) for c in range(ncols)]
        numeric = [
            all(_NUMBER.fullmatch(row[c][0]) or not row[c][0] for row in cells if not row[c][1])
            and any(row[c][0] and not row[c][1] for row in cells)
            for c in range(ncols)
        ]
        # header rows: the <thead> rows, or else leading rows made only of <th> cells
        head = table.head_rows
        if head == 0:
            while head < len(cells) and all(h for _, h in cells[head]):
                head += 1

        lines = []
        caption = " ".join("".join(table.caption).split())
        if caption:
            lines.append(caption)
        for i, row in enumerate(cells):
            parts = []
            for c, (text, _) in enumerate(row):
                pad = " " * (widths[c] - _width(text))
                parts.append(pad + text if numeric[c] and i >= head else text + pad)
            lines.append("  ".join(parts).rstrip())
            if i == head - 1 and head < len(cells):
                lines.append("  ".join("─" * w for w in widths).rstrip())
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) if blocks else None
