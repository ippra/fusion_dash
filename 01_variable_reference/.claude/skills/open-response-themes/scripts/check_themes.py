"""Check a coded item against the responses it is supposed to cover.

Usage:
    python3 check_themes.py <item> <exported.txt>

Reports:
  missing     a response in the export with no row in themes.csv. Always a
              defect: 03 refuses to build a partly-coded item, because the
              theme filter would silently hide whatever was skipped.
  extra       a coded case_id that the export does not contain. Usually means
              the coding was done against a different item or an older file.
  unlabelled  a theme used in themes.csv with no row in theme_labels.csv, so
              it would have no name and no place in the filter menu.
  singletons  themes with one or two members. Not an error - some concerns
              really are rare - but worth a second look before shipping, in
              case the response belongs somewhere else.

Exit status is 1 if anything is missing, extra or unlabelled.
"""

import collections
import csv
import os
import sys

REF = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "..", "..", "..")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    item, export_path = sys.argv[1], sys.argv[2]

    exported = {}
    for line in open(export_path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 4:
            exported[parts[1]] = parts[3]

    coded, labels = {}, set()
    with open(os.path.join(REF, "themes.csv")) as handle:
        for row in csv.DictReader(handle):
            if row["item"] == item:
                coded[row["case_id"]] = row["theme"]
    with open(os.path.join(REF, "theme_labels.csv")) as handle:
        for row in csv.DictReader(handle):
            if row["item"] == item:
                labels.add(row["theme"])

    missing = sorted(set(exported) - set(coded))
    extra = sorted(set(coded) - set(exported))
    unlabelled = sorted(set(coded.values()) - labels)
    counts = collections.Counter(coded.values())

    print("%s  responses %d  coded %d  themes %d"
          % (item, len(exported), len(coded), len(counts)))
    if missing:
        print("    missing %d, first few:" % len(missing))
        for case_id in missing[:5]:
            print("      %s  %s" % (case_id, exported[case_id][:70]))
    if extra:
        print("    extra:     ", ", ".join(extra[:10]))
    if unlabelled:
        print("    unlabelled:", ", ".join(unlabelled))

    for theme, n in counts.most_common():
        mark = "  <- check" if n <= 2 else ""
        print("    %5d  %s%s" % (n, theme, mark))

    sys.exit(1 if (missing or extra or unlabelled) else 0)


if __name__ == "__main__":
    main()
