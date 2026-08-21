"""Check the fusion variable reference sheet against the instruments it came from.

Usage:
    python3 check_coverage.py <variable_reference.csv> <text_dir>

Reports, per wave:
  missing   a "name:" line in an instrument with no row in the sheet. Always a
            defect - go back and read that part of the document.
  extra     a row the sheet claims that wave asked, with no matching "name:"
            line in it. Legitimate for randomization variables, which appear
            only inside brackets; for the consent item, which the instrument
            shows but never names; and for the "please specify" boxes the data
            carries but the document does not list. Anything else needs
            explaining.

A row is matched by `variable`, or by `instrument_name` where the document's
name differs from the canonical one - which happens when one document item is
stored as two columns (FU25 `gcccert`, `govspend_fusion_exp`).

Exit status is 1 if anything is missing, so this can gate a build.
"""

import collections
import csv
import os
import re
import sys

NAME = re.compile(r"^([a-z][a-z0-9_]*|[A-Z][A-Z0-9_]*):")


def instrument_names(path):
    names = []
    for line in open(path):
        if "\t" not in line:
            continue
        text = line.split("\t", 1)[1].strip()
        match = NAME.match(text)
        if match:
            names.append(match.group(1))
    return names


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)

    sheet_path, text_dir = sys.argv[1], sys.argv[2]

    documents = {}
    for name in sorted(os.listdir(text_dir)):
        if name.endswith(".txt"):
            wave = name[:-4].upper()
            documents[wave] = set(instrument_names(os.path.join(text_dir, name)))

    sheet = collections.defaultdict(set)
    rows = list(csv.DictReader(open(sheet_path)))
    for row in rows:
        for wave in documents:
            if row.get("column_" + wave.lower(), "").strip():
                sheet[wave].add(row["variable"])
                if row.get("instrument_name", "").strip():
                    sheet[wave].add(row["instrument_name"])

    print("sheet rows: %d" % len(rows))

    failed = False
    for wave in sorted(set(documents) | set(sheet)):
        missing = sorted(documents[wave] - sheet[wave])
        extra = sorted(sheet[wave] - documents[wave])
        print("%s  document %3d  sheet %3d  missing %d  extra %d"
              % (wave, len(documents[wave]), len(sheet[wave]),
                 len(missing), len(extra)))
        if missing:
            failed = True
            print("    missing:", ", ".join(missing))
        if extra:
            print("    extra:  ", ", ".join(extra))

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
